import '../database/app_database.dart';
import '../repositories/drift_food_repository.dart';
import 'bundled_catalogue_data.dart';

/// Attribution to display alongside the starter catalogue, e.g. in About.
const bundledCatalogueAttribution =
    'U.S. Department of Agriculture, Agricultural Research Service. '
    'FoodData Central, SR Legacy (April 2018). '
    'https://fdc.nal.usda.gov/ · CC0 1.0';

/// Inserts missing starter foods atomically and returns the number added.
///
/// Safe to call at every startup, including on a non-empty database. Existing
/// foods are not overwritten. See the catalogue data module for coverage and
/// details of the nutrient transcription.
Future<int> installBundledCatalogue(AppDatabase db) =>
    DriftFoodRepository(db).insertMissingCatalogueBatch(
      bundledCatalogueEntries.values.map((entry) => entry.food),
    );
