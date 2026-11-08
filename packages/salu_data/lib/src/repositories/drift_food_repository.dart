import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../codec.dart';
import '../database/app_database.dart';

/// SQLite-backed catalogue reads and imports.
///
/// Search is a `LIKE` scan for now. The FTS5 table and its triggers belong in
/// the same schema version as the feature that needs them, not as an untested
/// extra.
final class DriftFoodRepository implements FoodRepository {
  /// Wraps [db].
  DriftFoodRepository(this._db);

  final AppDatabase _db;

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
    final text = query.trim();
    final statement = _db.select(_db.catalogFoods);
    if (text.isNotEmpty) {
      statement.where((t) => t.name.contains(text));
    }
    statement.limit(limit);
    final rows = await statement.get();
    return rows.map(_toFood).toList(growable: false);
  }

  /// Inserts or replaces [foods] atomically.
  ///
  /// This is the shape the import pipeline uses: stage rows, then activate them
  /// in one transaction so an interrupted update cannot leave a half-installed
  /// catalogue.
  Future<void> replaceCatalogueBatch(List<Food> foods) async {
    await _db.transaction(() async {
      for (final food in foods) {
        await _db
            .into(_db.catalogFoods)
            .insertOnConflictUpdate(_toCompanion(food));
      }
    });
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

  Food _toFood(CatalogFood row) => Food(
        id: row.id,
        name: row.name,
        per100g: NutrientProfile.fromJson(decodeJsonMap(row.per100gJson)),
        source: FoodSource(
          dataset: row.source,
          datasetId: row.sourceId,
          datasetVersion: row.sourceVersion,
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
      );
}
