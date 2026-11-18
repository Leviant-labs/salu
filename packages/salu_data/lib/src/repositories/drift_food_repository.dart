import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../catalogue/bundled_catalogue_data.dart';
import '../codec.dart';
import '../database/app_database.dart';
import 'local_document_store.dart';

/// SQLite-backed catalogue reads and imports.
final class DriftFoodRepository implements FoodRepository {
  /// Wraps [db].
  DriftFoodRepository(this._db);

  final AppDatabase _db;

  // Schema v1 has no name index. Read a bounded window in primary-key order
  // and always include installed starter entries, even outside that window.
  // Larger imports will need indexed search rather than a larger window.
  static const _nameSearchWindow = 512;
  static final _indexes = Expando<Future<bool>>();

  Future<bool> _index() => _indexes[_db] ??= _db.transaction(() async {
        try {
          await _db.customStatement(
              'CREATE VIRTUAL TABLE IF NOT EXISTS food_names USING fts5(food_id UNINDEXED, search_text)');
        } catch (_) {
          return false;
        }
        // Rebuild once per open so each source's aliases match the installed edition.
        await _db.customStatement('DELETE FROM food_names');
        final table = _db.catalogFoods;
        final rows = await (_db.selectOnly(table)
              ..addColumns([table.id, table.name, table.source]))
            .get();
        for (final row in rows) {
          await _indexRow(row.read(table.id)!, row.read(table.name)!,
              row.read(table.source)!);
        }
        return true;
      });

  Future<void> _indexRow(String id, String name, String source) {
    final aliases = source == bundledCatalogueDataset
        ? bundledCatalogueEntries[id]?.aliases ?? const <String>[]
        : const <String>[];
    return _db.customStatement(
        'INSERT INTO food_names (food_id, search_text) VALUES (?, ?)', [
      id,
      _foldSearchText([name, ...aliases].join(' '))
    ]);
  }

  @override
  Future<Food?> findById(String id) async {
    final row = await (_db.select(
      _db.catalogFoods,
    )..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toFood(row);
  }

  @override
  Future<List<Food>> search(String query, {int limit = 20}) async {
    if (limit <= 0) return const [];
    final table = _db.catalogFoods;
    final text = query.trim();
    if (text.isEmpty) {
      final rows = await (_db.select(table)
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(limit))
          .get();
      return rows.map(_toFood).toList(growable: false);
    }

    final foldedQuery = _foldSearchText(text);
    if (foldedQuery.isEmpty) return const [];
    final queryWords = foldedQuery.split(' ');
    final columns = [table.id, table.name, table.source];
    final indexed = await _index();
    final hits = indexed
        ? await _db.customSelect(
            'SELECT food_id FROM food_names WHERE food_names MATCH ? ORDER BY rank LIMIT ?',
            variables: [
              Variable.withString(
                  queryWords.map((word) => '"$word"*').join(' AND ')),
              Variable.withInt(2000)
            ],
          ).get()
        : null;
    final candidates = hits != null
        ? (hits.isEmpty
            ? <TypedResult>[]
            : await (_db.selectOnly(table)
                  ..addColumns(columns)
                  ..where(table.id
                      .isIn(hits.map((row) => row.read<String>('food_id')))))
                .get())
        : await (_db.selectOnly(table)
              ..addColumns(columns)
              ..orderBy([OrderingTerm.asc(table.id)])
              ..limit(_nameSearchWindow))
            .get();
    if (!indexed && candidates.length == _nameSearchWindow) {
      final ids = candidates.map((row) => row.read(table.id)!).toSet();
      final remaining = bundledCatalogueEntries.keys.toSet().difference(ids);
      if (remaining.isNotEmpty) {
        candidates.addAll(await (_db.selectOnly(table)
              ..addColumns(columns)
              ..where(table.id.isIn(remaining)))
            .get());
      }
    }

    final matches = <({String id, String name, int rank})>[];
    for (final row in candidates) {
      final id = row.read(table.id)!;
      final name = _foldSearchText(row.read(table.name)!);
      var rank = _searchRank(name, foldedQuery, queryWords, alias: false);
      if (row.read(table.source) == bundledCatalogueDataset) {
        final aliases = bundledCatalogueEntries[id]?.aliases ?? const [];
        for (final alias in aliases) {
          final aliasRank = _searchRank(
            _foldSearchText(alias),
            foldedQuery,
            queryWords,
            alias: true,
          );
          if (aliasRank < rank) rank = aliasRank;
        }
      }
      if (rank != _noMatch) matches.add((id: id, name: name, rank: rank));
    }
    matches.sort((a, b) {
      final rank = a.rank.compareTo(b.rank);
      if (rank != 0) return rank;
      final name = a.name.compareTo(b.name);
      return name == 0 ? a.id.compareTo(b.id) : name;
    });

    if (matches.isEmpty) return const [];
    final ids = matches.take(limit).map((match) => match.id).toList();
    final winners =
        await (_db.select(table)..where((t) => t.id.isIn(ids))).get();
    final byId = {for (final row in winners) row.id: row};
    return [
      for (final id in ids)
        if (byId[id] case final row?) _toFood(row)
    ];
  }

  /// Adds missing IDs from a small starter batch, preserving existing records.
  Future<int> insertMissingCatalogueBatch(Iterable<Food> foods) async {
    final byId = {for (final food in foods) food.id: food};
    if (byId.isEmpty) return 0;
    final table = _db.catalogFoods;
    final indexed = await _index();
    return _db.transaction(() async {
      final existing = await (_db.selectOnly(table)
            ..addColumns([table.id])
            ..where(table.id.isIn(byId.keys)))
          .get();
      for (final row in existing) {
        byId.remove(row.read(table.id));
      }
      if (byId.isNotEmpty) {
        await _db.batch((batch) {
          batch.insertAll(table, byId.values.map(_toCompanion));
        });
        if (indexed) {
          for (final food in byId.values) {
            await _indexRow(food.id, food.name, food.source.dataset);
          }
        }
      }
      return byId.length;
    });
  }

  /// Inserts or replaces [foods] atomically.
  ///
  /// This is the shape the import pipeline uses: stage rows, then activate them
  /// in one transaction so an interrupted update cannot leave a half-installed
  /// catalogue.
  Future<void> replaceCatalogueBatch(List<Food> foods) async {
    final indexed = await _index();
    await _db.transaction(() async {
      for (final food in foods) {
        await _db
            .into(_db.catalogFoods)
            .insertOnConflictUpdate(_toCompanion(food));
        if (indexed) {
          await _db.customStatement(
              'DELETE FROM food_names WHERE food_id = ?', [food.id]);
          await _indexRow(food.id, food.name, food.source.dataset);
        }
      }
    });
  }

  /// Activates a fully validated, source-specific edition with stable source IDs.
  /// User food records are stored separately; intake uses frozen snapshots.
  Future<void> installEdition(String dataset, String edition, List<Food> staged,
      {Map<String, String> barcodes = const {},
      String? attribution,
      String? licence}) async {
    final stagedIds = staged.map((food) => food.id).toSet();
    if (dataset.trim().isEmpty ||
        edition.trim().isEmpty ||
        dataset == bundledCatalogueDataset ||
        staged.isEmpty ||
        stagedIds.length != staged.length ||
        barcodes.entries.any((entry) =>
            !RegExp(r'^\d{8,14}$').hasMatch(entry.key) ||
            !stagedIds.contains(entry.value)) ||
        staged.any((food) =>
            food.source.dataset != dataset ||
            food.source.datasetVersion != edition ||
            food.name.trim().isEmpty ||
            !food.id.startsWith('$dataset:') ||
            food.source.datasetId.isEmpty)) {
      throw ArgumentError('The dataset edition is incomplete or inconsistent');
    }
    final indexed = await _index();
    final table = _db.catalogFoods;
    await _db.transaction(() async {
      if (indexed) {
        await _db.customStatement(
            'DELETE FROM food_names WHERE food_id IN (SELECT id FROM catalog_foods WHERE source = ?)',
            [dataset]);
      }
      await (_db.delete(table)..where((row) => row.source.equals(dataset)))
          .go();
      await (_db.delete(_db.catalogBarcodes)
            ..where((row) => row.dataset.equals(dataset)))
          .go();
      await _db
          .batch((batch) => batch.insertAll(table, staged.map(_toCompanion)));
      await _db.batch((batch) => batch.insertAll(
          _db.catalogBarcodes,
          barcodes.entries.map((entry) => CatalogBarcodesCompanion.insert(
              code: entry.key, foodId: entry.value, dataset: dataset))));
      if (indexed) {
        for (final food in staged) {
          await _indexRow(food.id, food.name, food.source.dataset);
        }
      }
      final documents = LocalDocumentStore(_db);
      final key = 'catalogue-edition:$dataset';
      final old = await documents.read(key);
      if (!await documents.put(key, old?.revision ?? 0, {
        'edition': edition,
        'licence': licence,
        'attribution': attribution
      })) {
        throw StateError('Catalogue edition changed');
      }
    });
  }

  Future<List<Food>> findByBarcode(String barcode) async {
    final matches = await (_db.select(_db.catalogBarcodes)
          ..where((row) => row.code.equals(barcode))
          ..orderBy([(row) => OrderingTerm.asc(row.dataset)]))
        .get();
    return (await Future.wait(matches.map((match) => findById(match.foodId))))
        .whereType<Food>()
        .toList();
  }

  CatalogFoodsCompanion _toCompanion(Food food) => CatalogFoodsCompanion.insert(
        id: food.id,
        name: food.name,
        source: food.source.dataset,
        sourceId: food.source.datasetId,
        sourceVersion: Value(food.source.datasetVersion),
        per100gJson: jsonEncode(food.per100g.toJson()),
        portionGrams: Value(food.portions.portionGrams),
        densityGPerMl: Value(food.portions.densityGramsPerMillilitre),
        quality: food.quality.name,
        allergensJson: Value(
          food.allergens == null ? null : jsonEncode(food.allergens!.toList()),
        ),
        dietaryTagsJson: Value(jsonEncode(food.dietaryTags.toList())),
        preparation: food.preparation.name,
        importedAt: DateTime.now().toUtc(),
      );

  Food _toFood(CatalogFood row) {
    // Schema v1 persists the source identity. The matching built-in row supplies
    // licence and dish metadata, neither of which has a dedicated column.
    final original = bundledCatalogueEntries[row.id]?.food;
    final bundled = original != null &&
            original.source.dataset == row.source &&
            original.source.datasetId == row.sourceId &&
            original.source.datasetVersion == row.sourceVersion
        ? original
        : null;
    return Food(
      id: row.id,
      name: row.name,
      per100g: NutrientProfile.fromJson(decodeJsonMap(row.per100gJson)),
      source: FoodSource(
        dataset: row.source,
        datasetId: row.sourceId,
        datasetVersion: row.sourceVersion,
        licence: bundled?.source.licence,
      ),
      portions: PortionDefinition(
        portionGrams: row.portionGrams,
        densityGramsPerMillilitre: row.densityGPerMl,
      ),
      quality:
          enumByWire(DataQuality.values, row.quality, DataQuality.imported),
      preparation: enumByWire(
        Preparation.values,
        row.preparation,
        Preparation.unspecified,
      ),
      allergens: row.allergensJson == null
          ? null
          : decodeStringSet(row.allergensJson!),
      dietaryTags: decodeStringSet(row.dietaryTagsJson),
      isComposite: bundled?.isComposite ?? false,
    );
  }
}

const _noMatch = 8;

int _searchRank(
  String label,
  String query,
  List<String> queryWords, {
  required bool alias,
}) {
  final offset = alias ? 1 : 0;
  if (label == query) return offset;
  if (label.startsWith(query)) return 2 + offset;
  final words = label.split(' ');
  if (queryWords.every((part) => words.any((word) => word.startsWith(part)))) {
    return 4 + offset;
  }
  if (label.contains(query)) return 6 + offset;
  return _noMatch;
}

// SQLite's built-in lower/NOCASE only folds ASCII. Cover Portuguese and other
// common Latin accent variants here, including decomposed input from keyboards.
const _foldGroups = {
  'àáâãäåāăą': 'a',
  'çćč': 'c',
  'èéêëēėęě': 'e',
  'ìíîïīįı': 'i',
  'ł': 'l',
  'ñń': 'n',
  'òóôõöøōő': 'o',
  'śš': 's',
  'ùúûüūůű': 'u',
  'ýÿ': 'y',
  'źżž': 'z',
  'æ': 'ae',
  'œ': 'oe',
  'ß': 'ss',
};
final _foldVariants = {
  for (final entry in _foldGroups.entries)
    for (final letter in entry.key.split('')) letter: entry.value,
};
final _accentedLatin = RegExp('[${_foldGroups.keys.join()}]');
final _combiningMarks = RegExp(r'\p{M}+', unicode: true);
final _wordSeparators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

String _foldSearchText(String text) => text
    .toLowerCase()
    .replaceAll(_combiningMarks, '')
    .replaceAllMapped(_accentedLatin, (match) => _foldVariants[match[0]]!)
    .replaceAll(_wordSeparators, ' ')
    .trim();
