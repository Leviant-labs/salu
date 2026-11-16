import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:salu_data/salu_data.dart';

import 'src/app.dart';
import 'src/catalogue/built_in_catalogue.dart';
import 'src/catalogue/starter_meals.dart';
import 'src/providers.dart';
import 'src/ui_support.dart';

/// Composition root: the only place that decides which implementations the ports
/// get. Everything below it receives ports through Riverpod.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase(driftDatabase(name: 'salu'));

  // Install the exact bundled INSA BDCA 7.1-2026 workbook before the first
  // frame. This is idempotent: an intact installation is left untouched on
  // later launches, and only the catalogue's own source scope is replaced.
  // A failure is reported to the UI rather than preventing the app from
  // starting, so existing user foods, plans and diary records stay reachable.
  CatalogueProvisioningOutcome catalogue;
  StarterMealProvisioningOutcome? starterMeals;
  try {
    catalogue = CatalogueProvisioningOutcome.installed(
        await provisionBundledCatalogue(database));
    // Starter meals depend on the catalogue rows. A failure here does not
    // block existing data; the outcome is surfaced for repair.
    try {
      starterMeals = StarterMealProvisioningOutcome.installed(
          await provisionStarterMeals(database));
    } catch (error, stack) {
      starterMeals = StarterMealProvisioningOutcome.failed(error);
      if (kDebugMode) {
        debugPrint('Starter meal library provisioning failed: $error');
        debugPrintStack(stackTrace: stack);
      }
    }
  } catch (error, stack) {
    if (kDebugMode) {
      debugPrint('Built-in INSA catalogue provisioning failed: $error');
      debugPrintStack(stackTrace: stack);
    }
    catalogue = CatalogueProvisioningOutcome.failed(error);
    starterMeals = StarterMealProvisioningOutcome.failed(error);
  }

  final preferences = await LocalWorkspace(database).read('preferences', 'app');

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        catalogueProvisioningProvider.overrideWithValue(catalogue),
        starterMealProvisioningProvider.overrideWith((ref) => starterMeals),
        initialSettingsProvider.overrideWithValue(preferences?.data ?? const {})
      ],
      child: const SaluApp(),
    ),
  );
}
