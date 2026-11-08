/// Catalogue food records: what the app knows, where it came from, and how
/// trustworthy it is.
library;

import 'nutrients.dart';
import 'quantity.dart';

/// How a preparation state was reported by the source.
enum Preparation { raw, cooked, unspecified }

/// Where a food record came from.
///
/// Provenance travels with the record: imports, exports, and updates all need to
/// say which dataset revision produced a value.
final class FoodSource {
  /// Creates provenance for a food record.
  const FoodSource({
    required this.dataset,
    required this.datasetId,
    this.datasetVersion,
    this.licence,
  });

  /// Human-readable dataset name, e.g. `usda-fdc`, `ciqual`, `open-food-facts`.
  final String dataset;

  /// Identifier inside that dataset.
  final String datasetId;

  /// Dataset revision the record was imported from, when known.
  final String? datasetVersion;

  /// Licence identifier the imported record is subject to, when known.
  final String? licence;

  @override
  bool operator ==(Object other) =>
      other is FoodSource &&
      other.dataset == dataset &&
      other.datasetId == datasetId &&
      other.datasetVersion == datasetVersion &&
      other.licence == licence;

  @override
  int get hashCode => Object.hash(dataset, datasetId, datasetVersion, licence);

  @override
  String toString() => 'FoodSource($dataset:$datasetId'
      '${datasetVersion == null ? '' : '@$datasetVersion'})';
}

/// A quality badge. Imported catalogue rows are not "verified".
enum DataQuality {
  /// Independently checked against a primary source.
  verified,

  /// Curated by the app for a regional launch.
  curated,

  /// Imported from a public dataset without additional review.
  imported,

  /// Entered or corrected by the user.
  userEntered,
}

/// A food the user can log.
///
/// [per100g] is canonical: every nutrient is stated per 100 g of the edible
/// portion as described by [preparation]. Conversions the food does not declare
/// stay absent rather than being approximated.
final class Food {
  /// Creates a food record.
  const Food({
    required this.id,
    required this.name,
    required this.per100g,
    required this.source,
    this.portions = PortionDefinition.massOnly,
    this.quality = DataQuality.imported,
    this.preparation = Preparation.unspecified,
    this.allergens,
    this.dietaryTags = const <String>{},
    this.isComposite = false,
  });

  /// Stable local identifier (not the dataset's identifier; see [source]).
  final String id;

  /// Display name.
  final String name;

  /// Nutrients per 100 g of edible portion.
  final NutrientProfile per100g;

  /// Provenance of the record.
  final FoodSource source;

  /// Piece and volume conversions this food declares.
  final PortionDefinition portions;

  /// Quality badge shown in search results and detail views.
  final DataQuality quality;

  /// Raw or cooked, as the source described it.
  final Preparation preparation;

  /// Declared allergens, or `null` when allergen status is unknown.
  ///
  /// `null` and an empty set are different claims: unknown status can never
  /// establish suitability for an exclusion.
  final Set<String>? allergens;

  /// Dietary labels such as `vegetarian` or `gluten-free`, as declared.
  final Set<String> dietaryTags;

  /// Whether this is a multi-ingredient prepared dish rather than a commodity.
  final bool isComposite;

  /// Nutrients for [grams] of this food, scaled from [per100g].
  NutrientProfile nutrientsFor(double grams) => per100g.scaled(grams / 100);

  @override
  String toString() => 'Food($id, $name)';
}
