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
export 'src/food_library.dart';
