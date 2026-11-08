import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';
import '../codec.dart';
import '../database/app_database.dart';
import '../snapshot_codec.dart';
import '../workspace_store.dart';

/// Replaceable catalogue, exact barcode lookup and deterministic personal ranking.
final class DriftFoodRepository implements FoodRepository {
  DriftFoodRepository(this._db);
  final AppDatabase _db;
  @override
  Future<Food?> findById(String id) async {
    final row = await (_db.select(_db.catalogFoods)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row != null) return _toFood(row);
    final saved = await LocalWorkspace(_db).read('favorite-food', id);
    return saved?.data['favorite'] == true
        ? foodFromSnapshot(
            Map<String, Object?>.from(saved!.data['food']! as Map))
        : null;
  }

  @override
  Future<List<Food>> search(String query, {int limit = 20}) =>
      searchCatalogue(CatalogueQuery(query, limit: limit));
  Future<List<Food>> searchCatalogue(CatalogueQuery query) async {
    final tokens = RegExp(r'[A-Za-zÀ-ɏ0-9]+')
        .allMatches(query.text)
        .map((m) => m.group(0)!)
        .toList();
    if (tokens.isEmpty && query.text.trim().isNotEmpty) return [];
    final favorites = await LocalWorkspace(_db).list('favorite-food');
    final favoriteIds = {
      for (final d in favorites)
        if (d.data['favorite'] == true) d.id
    };
    final relevance = <String, double>{};
    List<Food> candidates;
    await _db.customSelect('SELECT 1').getSingle();
    if (_db.ftsAvailable && tokens.isNotEmpty) {
      final match = tokens.map((t) => '"$t"*').join(' AND ');
      // Ranking and preparation/region filtering happen below. Truncating here
      // would discard valid or preferred foods before those rules are applied.
      final rows = await _db.customSelect(
          'SELECT food_id,bm25(catalog_search,0,8,2) AS score FROM catalog_search WHERE catalog_search MATCH ? ORDER BY score,food_id',
          variables: [Variable<String>(match)]).get();
      for (final r in rows) {
        relevance[r.read<String>('food_id')] = r.read<double>('score');
      }
      final statement = _db.select(_db.catalogFoods)
        ..where((t) => t.id.isIn(relevance.keys));
      if (query.preparation != null) {
        statement.where((t) => t.preparation.equals(query.preparation!.name));
      }
      candidates = (await statement.get()).map(_toFood).toList();
    } else {
      final statement = _db.select(_db.catalogFoods);
      if (query.preparation != null) {
        statement.where((t) => t.preparation.equals(query.preparation!.name));
      }
      candidates = (await statement.get())
          .map(_toFood)
          .where((f) => _matches(f, tokens))
          .toList();
    }
    final existing = candidates.map((f) => f.id).toSet();
    for (final doc in favorites.where((d) => d.data['favorite'] == true)) {
      if (existing.contains(doc.id)) continue;
      final f = await findById(doc.id);
      if (f != null &&
          _matches(f, tokens) &&
          (query.preparation == null || f.preparation == query.preparation)) {
        candidates.add(f);
      }
    }
    final usage = await _db
        .customSelect(
            'SELECT i.food_id,COUNT(*) AS uses,MAX(e.recorded_at_ms) AS latest FROM log_entry_items i JOIN log_entries e ON i.entry_id=e.id WHERE i.food_id IS NOT NULL GROUP BY i.food_id')
        .get();
    final counts = {
      for (final r in usage) r.read<String>('food_id'): r.read<int>('uses')
    };
    final latest = {
      for (final r in usage) r.read<String>('food_id'): r.read<int>('latest')
    };
    int flag(bool x) => x ? 0 : 1;
    candidates.sort((a, b) {
      var order = flag(favoriteIds.contains(a.id))
          .compareTo(flag(favoriteIds.contains(b.id)));
      if (order != 0) return order;
      if (query.region != null) {
        order = flag(a.regions.contains(query.region))
            .compareTo(flag(b.regions.contains(query.region)));
        if (order != 0) return order;
      }
      order = (relevance[a.id] ?? 0).compareTo(relevance[b.id] ?? 0);
      if (order != 0) return order;
      order = (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0);
      if (order != 0) return order;
      order = (latest[b.id] ?? 0).compareTo(latest[a.id] ?? 0);
      if (order != 0) return order;
      order = a.name.compareTo(b.name);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return candidates.take(query.limit).toList();
  }

  static String folded(String s) {
    const from = 'áàâãäåéèêëíìîïóòôõöúùûüçñ', to = 'aaaaaaeeeeiiiiooooouuuucn';
    var value = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      value = value.replaceAll(from[i], to[i]);
    }
    return value;
  }

  bool _matches(Food f, List<String> tokens) {
    final text =
        folded('${f.name} ${f.aliases.join(' ')} ${f.barcodes.join(' ')}');
    return tokens.every((t) => text.contains(folded(t)));
  }

  Future<List<Food>> findByBarcode(ProductBarcode barcode) async {
    final rows = await (_db.select(_db.catalogFoods)
          ..where((t) => t.searchAliases.contains(barcode.value)))
        .get();
    final found = {
      for (final f in rows.map(_toFood))
        if (f.barcodes.contains(barcode.value)) f.id: f
    };
    for (final doc in await LocalWorkspace(_db).list('favorite-food')) {
      if (doc.data['favorite'] != true || found.containsKey(doc.id)) continue;
      final f = await findById(doc.id);
      if (f != null && f.barcodes.contains(barcode.value)) found[f.id] = f;
    }
    return found.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  static void validateFoods(List<Food> foods) {
    final ids = <String>{};
    for (final food in foods) {
      if (!ids.add(food.id)) {
        throw const FormatException('Duplicate food ID in update');
      }
      if (food.id.isEmpty ||
          food.name.trim().isEmpty ||
          food.source.dataset.isEmpty ||
          food.source.datasetId.isEmpty ||
          !Exact.parse(food.basisValue).positive) {
        throw const FormatException('Invalid food identity/basis');
      }
      for (final barcode in food.barcodes) {
        ProductBarcode(barcode);
      }
      if (food.observations.map((o) => o.nutrient.key).toSet().length !=
          food.observations.length) {
        throw const FormatException('Duplicate nutrient definition');
      }
      if (food.observations.isNotEmpty) {
        final projected = projectObservations(food.observations,
            basis: FoodAmount(food.basisValue, food.basisUnit,
                measureId: food.basisUnit == FoodUnit.item
                    ? 'piece'
                    : food.basisUnit == FoodUnit.serving
                        ? 'serving'
                        : null));
        if (jsonEncode(projected.toJson()) !=
            jsonEncode(food.per100g.toJson())) {
          throw const FormatException(
              'Nutrient projection differs from source observations');
        }
      }
      for (final conversion in [
        food.portions.portionGrams,
        food.portions.densityGramsPerMillilitre
      ]) {
        if (conversion != null && (!conversion.isFinite || conversion <= 0)) {
          throw const FormatException('Invalid food conversion');
        }
      }
    }
  }

  Future<void> replaceCatalogueBatch(List<Food> foods) async {
    validateFoods(foods);
    await _db.transaction(() async {
      for (final food in foods) {
        await _db
            .into(_db.catalogFoods)
            .insertOnConflictUpdate(_toCompanion(food));
      }
    });
  }

  CatalogFoodsCompanion _toCompanion(Food f) => CatalogFoodsCompanion.insert(
      id: f.id,
      name: f.name,
      source: f.source.dataset,
      sourceId: f.source.datasetId,
      sourceVersion: Value(f.source.datasetVersion),
      per100gJson: jsonEncode(f.per100g.toJson()),
      portionGrams: Value(f.portions.portionGrams),
      densityGPerMl: Value(f.portions.densityGramsPerMillilitre),
      quality: f.quality.name,
      allergensJson:
          Value(f.allergens == null ? null : jsonEncode(f.allergens!.toList())),
      dietaryTagsJson: Value(jsonEncode(f.dietaryTags.toList())),
      preparation: f.preparation.name,
      importedAt: DateTime.now().toUtc(),
      basisUnit: Value(f.basisUnit.name),
      basisValue: Value(f.basisValue),
      detailsJson: Value(jsonEncode(foodSnapshot(f))),
      searchAliases: Value([...f.aliases, ...f.barcodes].join(' ')));
  Food _toFood(CatalogFood row) {
    final d = decodeJsonMap(row.detailsJson);
    return Food(
        id: row.id,
        name: row.name,
        per100g: NutrientProfile.fromJson(decodeJsonMap(row.per100gJson)),
        source: FoodSource(
            dataset: row.source,
            datasetId: row.sourceId,
            datasetVersion: row.sourceVersion,
            licence: d['licence'] as String?),
        portions: PortionDefinition(
            portionGrams: row.portionGrams,
            densityGramsPerMillilitre: row.densityGPerMl),
        quality:
            enumByWire(DataQuality.values, row.quality, DataQuality.imported),
        preparation: enumByWire(
            Preparation.values, row.preparation, Preparation.unspecified),
        allergens: row.allergensJson == null
            ? null
            : decodeStringSet(row.allergensJson!),
        dietaryTags: decodeStringSet(row.dietaryTagsJson),
        basisUnit: FoodUnit.values.byName(row.basisUnit),
        basisValue: row.basisValue,
        aliases: (d['aliases'] as List? ?? []).cast<String>(),
        barcodes: (d['barcodes'] as List? ?? []).cast<String>(),
        regions: (d['regions'] as List? ?? []).cast<String>(),
        isComposite: d['isComposite'] == true,
        observations: [
          for (final o in d['observations'] as List? ?? [])
            NutrientObservation.fromJson(Map<String, Object?>.from(o as Map))
        ]);
  }
}
