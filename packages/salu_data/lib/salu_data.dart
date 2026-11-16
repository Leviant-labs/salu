/// Salu's persistence layer: drift schema, migrations, and the repository
/// implementations of the `salu_core` ports.
///
/// This package may depend on `salu_core`. `salu_core` may never depend on this.
library;

export 'src/codec.dart';
export 'src/database/app_database.dart';
export 'src/dev_seed.dart';
export 'src/repositories/drift_entry_repository.dart';
export 'src/repositories/drift_food_repository.dart';
export 'src/workspace_store.dart';
export 'src/archive.dart';
export 'src/encrypted_archive.dart';
export 'src/snapshot_codec.dart';
export 'src/batch_service.dart';
export 'src/catalogue_install.dart';
export 'src/built_in_catalogue.dart';
export 'src/food_library.dart';
export 'src/draft_store.dart';
export 'src/health_outbox_store.dart';
export 'src/import/source_import.dart';
export 'src/import/usda_fdc_import.dart';
export 'src/import/open_food_facts_import.dart';
export 'src/import/source_pack_import.dart';
export 'src/import/ciqual_import.dart';
export 'src/import/insa_bdca_workbook.dart';
export 'src/plan_service.dart';
export 'src/grocery_service.dart';
export 'src/starter_meal_library.dart';
export 'src/plan_meal_state_service.dart';
export 'src/nutrition_profile_store.dart';
export 'src/guided_plan_service.dart';
