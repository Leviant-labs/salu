import 'dart:convert';
import 'package:salu_core/salu_core.dart';
import 'database/app_database.dart';
import 'repositories/drift_food_repository.dart';
import 'snapshot_codec.dart';

/// Normalized, versioned pack. Raw source adapters must retain nutrient definitions
/// in the food observations before constructing this pack. No inference is used.
final class CataloguePack {
  CataloguePack(
      {required this.dataset,
      required this.version,
      required this.licence,
      required this.attribution,
      required List<Food> foods})
      : foods = List.unmodifiable(foods) {
    if ([dataset, version, licence, attribution].any((v) => v.trim().isEmpty) ||
        foods.isEmpty) {
      throw const FormatException('Incomplete catalogue manifest');
    }
    if (dataset.startsWith('custom') || dataset == 'dev-fixture') {
      throw const FormatException(
          'User and development catalogues cannot be replaced by a dataset pack');
    }
    if (foods.map((f) => f.id).toSet().length != foods.length) {
      throw const FormatException('Duplicate source identifiers');
    }
    for (final f in foods) {
      if (f.source.dataset != dataset ||
          f.source.datasetVersion != version ||
          f.source.licence != licence ||
          !f.id.startsWith('$dataset:')) {
        throw const FormatException('Food provenance differs from manifest');
      }
    }
  }
  final String dataset, version, licence, attribution;
  final List<Food> foods;
  factory CataloguePack.decode(String text) {
    if (text.length > 50 * 1024 * 1024) {
      throw const FormatException('Catalogue pack too large');
    }
    final j = Map<String, Object?>.from(jsonDecode(text) as Map);
    if (j['format'] != 'salu-catalogue' || j['version'] != 1) {
      throw const FormatException('Unsupported catalogue pack');
    }
    final m = Map<String, Object?>.from(j['manifest']! as Map);
    return CataloguePack(
        dataset: m['dataset']! as String,
        version: m['version']! as String,
        licence: m['licence']! as String,
        attribution: m['attribution']! as String,
        foods: [
          for (final f in j['foods']! as List)
            foodFromSnapshot(Map<String, Object?>.from(f as Map))
        ]);
  }
  String encode() => jsonEncode({
        'format': 'salu-catalogue',
        'version': 1,
        'manifest': {
          'dataset': dataset,
          'version': version,
          'licence': licence,
          'attribution': attribution
        },
        'foods': foods.map(foodSnapshot).toList()
      });
}

/// A read-only description of the identifiers affected by an activation.
///
/// Replaced identifiers may have changed content; this is not a nutrient diff.
/// The preview can become stale if another operation changes the catalogue.
final class CatalogueActivationPreview {
  CatalogueActivationPreview({
    required this.installedVersion,
    required List<String> addedIds,
    required List<String> replacedIds,
    required List<String> retiredIds,
    required List<String> conflictingIds,
  })  : addedIds = List.unmodifiable(addedIds),
        replacedIds = List.unmodifiable(replacedIds),
        retiredIds = List.unmodifiable(retiredIds),
        conflictingIds = List.unmodifiable(conflictingIds);

  final String? installedVersion;
  final List<String> addedIds, replacedIds, retiredIds, conflictingIds;
}

final class CatalogueInstallService {
  CatalogueInstallService(this.db,
      {List<DatasetReview> approvedReviews = const []})
      : approvedReviews = List.unmodifiable(approvedReviews);
  final AppDatabase db;
  final List<DatasetReview> approvedReviews;

  /// Describe the proposed replacement without modifying or approving it.
  /// Licence review and staged validation still occur during activation.
  Future<CatalogueActivationPreview> preview(CataloguePack pack) async {
    final installed = await (db.select(db.catalogDatasets)
          ..where((t) => t.id.equals(pack.dataset)))
        .getSingleOrNull();
    final current = await (db.select(db.catalogFoods)
          ..where((t) => t.source.equals(pack.dataset)))
        .get();
    final existingIds = current.map((row) => row.id).toSet();
    final incomingIds = pack.foods.map((food) => food.id).toSet();
    final conflicts = <String>[];
    final ids = incomingIds.toList();
    // Chunk the lookup so large catalogues do not exceed SQLite's bind limit.
    for (var offset = 0; offset < ids.length; offset += 500) {
      final end = (offset + 500 < ids.length) ? offset + 500 : ids.length;
      final rows = await (db.select(db.catalogFoods)
            ..where((t) => t.id.isIn(ids.sublist(offset, end))))
          .get();
      conflicts.addAll(
          rows.where((row) => row.source != pack.dataset).map((row) => row.id));
    }
    List<String> sorted(Iterable<String> values) => values.toList()..sort();
    return CatalogueActivationPreview(
        installedVersion: installed?.version,
        addedIds: sorted(
            incomingIds.difference(existingIds).difference(conflicts.toSet())),
        replacedIds: sorted(incomingIds.intersection(existingIds)),
        retiredIds: sorted(existingIds.difference(incomingIds)),
        conflictingIds: sorted(conflicts));
  }

  Future<void> activate(CataloguePack pack, {required bool confirmed}) async {
    if (!confirmed) throw StateError('CATALOGUE_CONFIRMATION_REQUIRED');
    final reviews = approvedReviews.where((r) =>
        r.dataset == pack.dataset &&
        r.version == pack.version &&
        r.licence == pack.licence &&
        r.reviewId.isNotEmpty);
    if (reviews.isEmpty) throw StateError('DATASET_REVIEW_REQUIRED');
    // All validation completes in a separate database. A bad food or interrupted
    // activation cannot leave the live dataset half-installed.
    final stage = AppDatabase.memory();
    try {
      await DriftFoodRepository(stage).replaceCatalogueBatch(pack.foods);
    } finally {
      await stage.close();
    }
    await db.transaction(() async {
      for (final f in pack.foods) {
        final existing = await (db.select(db.catalogFoods)
              ..where((t) => t.id.equals(f.id)))
            .getSingleOrNull();
        if (existing != null && existing.source != pack.dataset) {
          throw StateError('CATALOGUE_ID_COLLISION');
        }
      }
      await (db.delete(db.catalogFoods)
            ..where((t) => t.source.equals(pack.dataset)))
          .go();
      await DriftFoodRepository(db).replaceCatalogueBatch(pack.foods);
      await db.into(db.catalogDatasets).insertOnConflictUpdate(
          CatalogDatasetsCompanion.insert(
              id: pack.dataset,
              version: pack.version,
              licence: pack.licence,
              attribution: pack.attribution,
              reviewId: reviews.first.reviewId,
              foodCount: pack.foods.length));
    });
  }
}
