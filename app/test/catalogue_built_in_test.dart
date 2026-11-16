import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu_data/salu_data.dart';

import 'package:salu/src/catalogue/built_in_catalogue.dart';
import 'package:salu/src/features/search/search_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/ui_support.dart';

const _dataset = 'insa-bdca';

/// The visible citation the source's terms require. Repeated here so a change
/// to the bundled pack cannot silently weaken it.
const _attribution =
    'Fonte: Base de Dados da Composição de Alimentos. Instituto Nacional de '
    'Saúde Doutor Ricardo Jorge, I. P.- INSA. v 7.1 - 2026';

Future<void> _pumpSearch(WidgetTester t, AppDatabase db,
    {CatalogueProvisioningOutcome? catalogue}) async {
  await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        catalogueProvisioningProvider.overrideWithValue(catalogue),
        initialSettingsProvider.overrideWithValue(
            const {'language': 'en', 'onboarded': true})
      ],
      child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const Scaffold(body: SearchScreen()))));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled asset is the exact pinned official workbook', () async {
    final bytes = await loadBundledInsaWorkbook();
    expect(bytes, isNotEmpty);
    expect(bytes.length, lessThan(SourcePackImporter.maxInsaWorkbookBytes));

    // The adapter verifies the pinned SHA-256, sheet identity and workbook
    // metadata before interpreting a record.
    final imported = await importBundledInsaWorkbook(bytes);
    expect(imported.pack.dataset, InsaBdcaWorkbookAdapter.dataset);
    expect(imported.pack.version, InsaBdcaWorkbookAdapter.version);
    expect(imported.pack.version, '7.1-2026');
    expect(imported.pack.attribution, _attribution);
    expect(imported.pack.licence, InsaBdcaWorkbookAdapter.terms);
    expect(imported.pack.foods.length, greaterThan(1000));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('first launch installs the bundled INSA catalogue and search finds it',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final result = await provisionBundledCatalogue(db,
        normalize: importBundledInsaWorkbook);

    expect(result.status, BuiltInCatalogueProvisionStatus.installed);
    expect(result.dataset, _dataset);
    expect(result.version, '7.1-2026');
    expect(result.foodCount, greaterThan(1000));
    final installer = CatalogueInstallService(db);
    final manifest = await installer.installedManifest(_dataset);
    expect(manifest, isNotNull);
    expect(manifest!.approvalId,
        BuiltInCatalogueApproval.insaBdca.approvalId);
    expect(manifest.approvalId, startsWith(BuiltInCatalogueApproval.idPrefix));
    expect(manifest.attribution, _attribution);
    expect(manifest.foodCount, result.foodCount);

    final foods = await DriftFoodRepository(db).search('frango');
    expect(foods, isNotEmpty);
    expect(foods.every((food) => food.source.dataset == _dataset), isTrue);
    expect(foods.any((food) => food.name.toLowerCase().contains('frango')),
        isTrue);
    final audit = await installer.readSourceAudit(_dataset);
    expect(audit, isNotNull);
    expect(audit!.records.first.sourceDetails['workbookSha256'],
        InsaBdcaWorkbookAdapter.workbookSha256);
    expect(audit.records.first.sourceDetails['identityVerified'], isTrue);
    expect(await installer.installedFoodCount('dev-fixture'), 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('later launches do not reread or replace an intact installation',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await provisionBundledCatalogue(db, normalize: importBundledInsaWorkbook);
    final before = await ArchiveService(db).exportJson();
    var loads = 0;

    final second = await provisionBundledCatalogue(db,
        loadWorkbookBytes: () async {
          loads++;
          return const <int>[];
        },
        normalize: (_) async => throw StateError('must not normalize again'));

    expect(second.status, BuiltInCatalogueProvisionStatus.alreadyInstalled);
    expect(loads, 0);
    expect(await ArchiveService(db).exportJson(), before);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('search shows INSA results with the required attribution',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final outcome = CatalogueProvisioningOutcome.installed(
        await provisionBundledCatalogue(db,
            normalize: importBundledInsaWorkbook));
    await _pumpSearch(t, db, catalogue: outcome);

    await t.enterText(find.byType(TextField), 'frango');
    await t.pumpAndSettle();

    expect(find.textContaining('insa-bdca'), findsWidgets);
    expect(find.text(_attribution), findsOneWidget);
    expect(find.textContaining('private family-testing build'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a provisioning failure is visible and does not claim data',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpSearch(t, db,
        catalogue: CatalogueProvisioningOutcome.failed(
            const FormatException('Bundled workbook SHA-256 mismatch')));

    expect(find.textContaining('Built-in INSA catalogue unavailable'),
        findsOneWidget);
    expect(find.textContaining('SHA-256 mismatch'), findsOneWidget);
    expect(find.text(_attribution), findsNothing);
  });

  testWidgets('development fixture rows are labelled as placeholders',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch(developmentCatalogue());
    await _pumpSearch(t, db);

    await t.enterText(find.byType(TextField), 'apple');
    await t.pumpAndSettle();

    expect(find.textContaining('Placeholder fixture'), findsWidgets);
  });
}
