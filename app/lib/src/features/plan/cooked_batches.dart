import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

typedef StoredBatch = ({String id, CookedRecipeBatch batch});

class CookedBatches {
  const CookedBatches(this.documents);
  final LocalDocumentStore documents;
  static const _key = 'cooked-batches';
  static const int currentVersion = 1;

  Future<List<StoredBatch>> available() async {
    final record = await documents.read(_key);
    if (record == null) return const [];
    final rows = _decodeAll(record.data);
    final rawRows = record.data['batches'] as List? ?? const [];
    final isCurrent = isCurrentDocumentVersion(
      record.data,
      currentVersion,
      documentName: _key,
    );
    final needsItemMigration = rawRows.any(
      (raw) =>
          raw is Map &&
          (raw['recipe'] is! Map ||
              (raw['recipe'] as Map)['versionFormat'] != recipeFormatVersion),
    );
    var activeRows = rows;
    if (!isCurrent || needsItemMigration) {
      final rawMaps = [
        for (final raw in rawRows) Map<String, dynamic>.from(raw as Map),
      ];
      final migrated = <String, Object?>{
        ...record.data,
        'version': currentVersion,
        'batches': [
          for (var i = 0; i < rows.length; i++)
            _encodeRow(rows[i].id, rows[i].batch, existingRow: rawMaps[i]),
        ],
      };
      if (!await documents.put(_key, record.revision, migrated)) {
        final latest = await documents.read(_key);
        if (latest != null) activeRows = _decodeAll(latest.data);
      }
    }
    return [
      for (final row in activeRows)
        if (row.batch.remainingFraction > 0) row,
    ];
  }

  Future<void> add(String id, CookedRecipeBatch batch) async {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    final old = await documents.read(_key);
    final existing = old == null ? const <StoredBatch>[] : _decodeAll(old.data);
    final existingRaw = old == null
        ? const <Map<String, dynamic>>[]
        : [
            for (final raw in old.data['batches'] as List? ?? const [])
              Map<String, dynamic>.from(raw as Map),
          ];
    if (!await documents.put(_key, old?.revision ?? 0, {
      ...?old?.data,
      'version': currentVersion,
      'batches': [
        for (var i = 0; i < existing.length; i++)
          _encodeRow(
            existing[i].id,
            existing[i].batch,
            existingRow: existingRaw[i],
          ),
        _encodeRow(id, batch),
      ],
    })) {
      throw StateError('Batch list changed');
    }
  }

  /// The stock debit and diary snapshot succeed together. The same meal ID
  /// cannot consume stock again on a retry.
  Future<bool> log(String id, MealPortion portion, PhotoMeal meal) =>
      documents.db.transaction(() async {
        final repository = DriftPhotoMealRepository(documents.db);
        if ((await repository.listFor(meal.date))
            .any((record) => record.id == meal.id)) {
          return false;
        }
        final old = await documents.read(_key);
        if (old == null) throw StateError('Batch no longer exists');
        final decoded = _decodeAll(old.data);
        final index = decoded.indexWhere((row) => row.id == id);
        if (index < 0) throw StateError('Batch no longer exists');
        final batch = decoded[index].batch;
        final amount = batch.consumptionFraction(portion);
        if (amount == null || amount <= 0) {
          throw StateError('Not enough batch remaining');
        }
        final items = batch
            .snapshot(amount)
            .indexed
            .map((entry) => entry.$2.copyWith(id: '${meal.id}:${entry.$1}'))
            .toList();
        if (!await repository.saveNew(meal.copyWith(items: items))) {
          return false;
        }
        final remaining = batch.remainingFraction - amount;
        final nextRemaining = remaining < 1e-10 ? 0.0 : remaining;
        final rawEntries = [
          for (final raw in old.data['batches'] as List)
            Map<String, dynamic>.from(raw as Map),
        ];
        rawEntries[index] = {
          ...rawEntries[index],
          'recipe': encodeRecipe(batch.recipe),
          'remainingFraction': nextRemaining,
        };
        if (!await documents.put(_key, old.revision, {
          ...old.data,
          'version': currentVersion,
          'batches': rawEntries,
        })) {
          throw StateError('Batch amount changed');
        }
        return true;
      });

  List<StoredBatch> _decodeAll(Map<String, dynamic> data) {
    isCurrentDocumentVersion(data, currentVersion, documentName: _key);
    final rawBatches = data['batches'];
    if (rawBatches == null) return const [];
    if (rawBatches is! List) {
      throw FormatException('Invalid batches list in $_key', rawBatches);
    }
    return [
      for (final raw in rawBatches)
        if (raw is Map)
          _decode(Map<String, dynamic>.from(raw))
        else
          throw FormatException('Invalid batch entry in $_key', raw),
    ];
  }

  Map<String, Object?> _encodeRow(
    String id,
    CookedRecipeBatch batch, {
    Map<String, dynamic>? existingRow,
  }) =>
      {
        ...?existingRow,
        'id': id,
        'recipe': encodeRecipe(batch.recipe),
        'cookedServings': batch.cookedServings,
        if (batch.finishedGrams != null) 'finishedGrams': batch.finishedGrams,
        'remainingFraction': batch.remainingFraction,
      };

  StoredBatch _decode(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('Invalid batch id', id);
    }
    final rawRecipe = row['recipe'];
    if (rawRecipe is! Map) {
      throw FormatException('Invalid batch recipe', rawRecipe);
    }
    final recipe = decodeRecipe(Map<String, dynamic>.from(rawRecipe));
    final rawServings = row['cookedServings'];
    if (rawServings is! num || !rawServings.isFinite || rawServings <= 0) {
      throw FormatException('Invalid cookedServings', rawServings);
    }
    final rawFinished = row['finishedGrams'];
    if (rawFinished != null &&
        (rawFinished is! num || !rawFinished.isFinite || rawFinished <= 0)) {
      throw FormatException('Invalid finishedGrams', rawFinished);
    }
    final rawRemaining = row['remainingFraction'];
    if (rawRemaining is! num ||
        !rawRemaining.isFinite ||
        rawRemaining < 0 ||
        rawRemaining > 1) {
      throw FormatException('Invalid remainingFraction', rawRemaining);
    }
    return (
      id: id,
      batch: CookedRecipeBatch(
        recipe: recipe,
        cookedServings: rawServings.toDouble(),
        finishedGrams: (rawFinished as num?)?.toDouble(),
        remainingFraction: rawRemaining.toDouble(),
      ),
    );
  }
}
