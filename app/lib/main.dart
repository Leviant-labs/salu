import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:salu_data/salu_data.dart';

import 'src/app.dart';
import 'src/providers.dart';
import 'src/ui_support.dart';

/// Composition root: the only place that decides which implementations the ports
/// get. Everything below it receives ports through Riverpod.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase(driftDatabase(name: 'salu'));

  if (kDebugMode) {
    // Fixture catalogue so search works before the import pipeline exists.
    await seedDevelopmentCatalogue(database);
  }

  final preferences = await LocalWorkspace(database).read('preferences', 'app');

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        initialSettingsProvider.overrideWithValue(preferences?.data ?? const {})
      ],
      child: const SaluApp(),
    ),
  );
}
