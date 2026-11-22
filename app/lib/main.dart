import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'src/assistant/credential_store.dart';
import 'src/assistant/operation_fence.dart';
import 'src/bootstrap.dart';
import 'src/data_transfer/archive_service.dart';
import 'src/data_transfer/data_reset_service.dart';
import 'src/data_transfer/data_write_gate.dart';
import 'src/media/managed_media_store.dart';
import 'src/providers.dart';

/// Composition root: mounts [BootstrapApp] immediately after binding
/// initialization so database opening, migration, pending reset/credential
/// recovery, and starter catalogue installation are all recoverable via UI.
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final ids = RandomIdGenerator();
  final media = ManagedMediaStore(
    directory: getApplicationSupportDirectory,
    newId: ids.next,
  );

  runApp(
    BootstrapApp(
      openDatabase: () async => AppDatabase(driftDatabase(name: 'salu')),
      initialize: (database) async {
        final userData = UserDataRepository(database);
        final credentials = SecureCredentialStore();
        final fence = OperationFence();
        final gate = DataWriteGate();

        final resetService = DataResetService(
          data: userData,
          credentials: credentials,
          fence: fence,
          gate: gate,
          supportDirectory: getApplicationSupportDirectory,
          stagingDirectory: getTemporaryDirectory,
        );
        final archiveService = ArchiveService(
          data: userData,
          media: media,
          fence: fence,
          credentials: credentials,
          gate: gate,
          stagingDirectory: getTemporaryDirectory,
          markerDirectory: getApplicationSupportDirectory,
        );

        await resetService.resumeIfPending();
        await archiveService.resumePendingCredentialCleanup();
        await installBundledCatalogue(database);
      },
      overrides: [
        idGeneratorProvider.overrideWithValue(ids),
        managedMediaStoreProvider.overrideWithValue(media),
      ],
    ),
  );
}
