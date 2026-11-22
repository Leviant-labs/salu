import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../catalogue/bundled_catalogue_data.dart';
import '../catalogue/search_index.dart';
import '../codec.dart';
import '../database/app_database.dart';
import 'local_document_store.dart';

/// SQLite-backed catalogue reads and imports.
final class DriftFoodRepository implements FoodRepository {
  /// Wraps [db].
  DriftFoodRepository(this._db, {SearchIndex? searchIndex})
      : _searchIndex = searchIndex ?? SearchIndex(_db);

  final AppDatabase _db;
  final SearchIndex _searchIndex;

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
    final ids = await _searchIndex.searchIds(query, limit: limit);
    if (ids.isEmpty) return const [];
    final table = _db.catalogFoods;
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
        await _searchIndex.replaceRows(byId.values);
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
    if (foods.isEmpty) return;
    await _db.transaction(() async {
      await _db.batch((batch) {
        batch.insertAllOnConflictUpdate(
          _db.catalogFoods,
          foods.map(_toCompanion),
        );
      });
      await _searchIndex.replaceRows(foods);
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
    final table = _db.catalogFoods;
    await _db.transaction(() async {
      await _searchIndex.removeDataset(dataset);
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
      await _searchIndex.replaceRows(staged);
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
