/// Salu's persistence layer: drift schema, migrations, and the repository
/// implementations of the `salu_core` ports.
///
/// This package may depend on `salu_core`. `salu_core` may never depend on this.
library;

export 'src/codec.dart';
export 'src/codec/photo_meal_codec.dart';
export 'src/codec/recipe_codec.dart';
export 'src/catalogue/catalogue_pack.dart';
export 'src/database/app_database.dart';
export 'src/catalogue/bundled_catalogue.dart'
    show installBundledCatalogue, bundledCatalogueAttribution;
export 'src/dev_seed.dart';
export 'src/repositories/drift_entry_repository.dart';
export 'src/repositories/drift_food_repository.dart';
export 'src/repositories/drift_photo_meal_repository.dart';
export 'src/repositories/endpoint_profiles_store.dart';
export 'src/repositories/local_document_store.dart';
export 'src/repositories/meal_estimate_status_store.dart';
export 'src/repositories/meal_mutation_repository.dart';
export 'src/repositories/onboarding_store.dart';
export 'src/repositories/user_data_repository.dart';
