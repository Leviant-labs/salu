import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'src/app.dart';
import 'src/media/managed_media_store.dart';
import 'src/providers.dart';

/// Composition root: the only place that decides which implementations the ports
/// get. Everything below it receives ports through Riverpod.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase(driftDatabase(name: 'salu'));
  final ids = RandomIdGenerator();
  final media = ManagedMediaStore(
    directory: getApplicationSupportDirectory,
    newId: ids.next,
  );

  await installBundledCatalogue(database);

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        idGeneratorProvider.overrideWithValue(ids),
        managedMediaStoreProvider.overrideWithValue(media),
      ],
      child: const SaluApp(),
    ),
  );
}
