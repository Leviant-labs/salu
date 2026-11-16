import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

import 'insa_workbook_fixture.dart';

/// Synthetic-only fixtures: no real INSA row, licence grant or dataset review
/// is involved. The production provisioner is exercised separately against the
/// exact bundled workbook in the app test suite.
const _dataset = 'insa-bdca-unverified';

SourcePackImport _syntheticPreview() {
  final fixture = buildSyntheticInsaWorkbook();
  final preview = InsaBdcaWorkbookParser.parse(workbookBytes: fixture.bytes);
  final records = preview.adaptAll();
  return SourcePackImport(
      pack: CataloguePack(
          dataset: InsaBdcaWorkbookParser.unverifiedDataset,
          version: InsaBdcaWorkbookAdapter.version,
          licence: InsaBdcaWorkbookAdapter.terms,
          attribution: InsaBdcaWorkbookAdapter.attribution,
          foods: [for (final result in records) result.food]),
      records: records,
      issues: preview.issues);
}

Future<String> _sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<BuiltInCatalogueApproval> _approval(List<int> bytes) async =>
    BuiltInCatalogueApproval(
        approvalId: '${BuiltInCatalogueApproval.idPrefix}test-source',
        dataset: _dataset,
        version: InsaBdcaWorkbookAdapter.version,
        licence: InsaBdcaWorkbookAdapter.terms,
        attribution: InsaBdcaWorkbookAdapter.attribution,
        sourceSha256: await _sha256Hex(bytes));

Future<BuiltInCatalogueProvision> _provision(
        AppDatabase db, BuiltInCatalogueApproval approval,
        {required Future<List<int>> Function() load}) =>
    BuiltInCatalogueProvisioner(db).ensureInstalled(
        loadWorkbookBytes: load,
        approval: approval,
        normalize: (_) async => _syntheticPreview());

void main() {
  test('installs the bundled source with its honest approval and audit',
      () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final imported = _syntheticPreview();

    final result = await _provision(db, approval, load: () async => bytes);

    expect(result.status, BuiltInCatalogueProvisionStatus.installed);
    expect(result.dataset, _dataset);
    expect(result.foodCount, imported.pack.foods.length);
    final installer = CatalogueInstallService(db);
    final manifest = await installer.installedManifest(_dataset);
    expect(manifest, isNotNull);
    expect(manifest!.version, InsaBdcaWorkbookAdapter.version);
    expect(manifest.attribution, InsaBdcaWorkbookAdapter.attribution);
    expect(manifest.licence, InsaBdcaWorkbookAdapter.terms);
    expect(manifest.approvalId, approval.approvalId);
    expect(manifest.foodCount, imported.pack.foods.length);

    final foods = await DriftFoodRepository(db).search('Synthetic');
    expect(foods, isNotEmpty);
    final audit = await installer.readSourceAudit(_dataset);
    expect(audit, isNotNull);
    expect(audit!.records, hasLength(manifest.foodCount));
    for (final record in audit.records) {
      expect(record.foodFingerprint, isNotEmpty);
      expect(record.sourceDetails['attribution'],
          InsaBdcaWorkbookAdapter.attribution);
    }
    expect((await installer.installedCatalogues()).single.attribution,
        InsaBdcaWorkbookAdapter.attribution);
  });

  test('leaves an intact installation untouched on the next launch', () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _provision(db, approval, load: () async => bytes);
    final before = await ArchiveService(db).exportJson();
    var loads = 0;

    final second = await _provision(db, approval, load: () async {
      loads++;
      return bytes;
    });

    expect(second.status, BuiltInCatalogueProvisionStatus.alreadyInstalled);
    expect(loads, 0);
    expect(await ArchiveService(db).exportJson(), before);
  });

  test('rejects a substituted bundle before parsing or writing', () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();

    await expectLater(
        _provision(db, approval,
            load: () async => const <int>[1, 2, 3, 4]),
        throwsA(isA<FormatException>().having((error) => error.message,
            'message', contains('SHA-256'))));
    expect(await ArchiveService(db).exportJson(), before);
  });

  test('does not overwrite a reviewed installation of the same version',
      () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: '$_dataset:reviewed',
          name: 'Reviewed record',
          per100g: NutrientProfile({}),
          source: FoodSource(
              dataset: _dataset,
              datasetId: 'reviewed',
              datasetVersion: InsaBdcaWorkbookAdapter.version,
              licence: InsaBdcaWorkbookAdapter.terms))
    ]);
    await db.into(db.catalogDatasets).insert(CatalogDatasetsCompanion.insert(
        id: _dataset,
        version: InsaBdcaWorkbookAdapter.version,
        licence: InsaBdcaWorkbookAdapter.terms,
        attribution: InsaBdcaWorkbookAdapter.attribution,
        reviewId: 'reviewed-install',
        foodCount: 1));
    final before = await ArchiveService(db).exportJson();
    var loads = 0;

    final result = await _provision(db, approval, load: () async {
      loads++;
      return bytes;
    });

    expect(result.status, BuiltInCatalogueProvisionStatus.alreadyInstalled);
    expect(result.approvalId, 'reviewed-install');
    expect(loads, 0);
    expect(await ArchiveService(db).exportJson(), before);
  });

  test('refuses to downgrade an installed different version', () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await db.into(db.catalogDatasets).insert(CatalogDatasetsCompanion.insert(
        id: _dataset,
        version: '0.9',
        licence: InsaBdcaWorkbookAdapter.terms,
        attribution: InsaBdcaWorkbookAdapter.attribution,
        reviewId: 'reviewed-install',
        foodCount: 1));
    final before = await ArchiveService(db).exportJson();
    var loads = 0;

    await expectLater(
        _provision(db, approval, load: () async {
          loads++;
          return bytes;
        }),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            contains('BUILT_IN_CATALOGUE_VERSION_CONFLICT'))));
    expect(loads, 0);
    expect(await ArchiveService(db).exportJson(), before);
    expect((await CatalogueInstallService(db).installedManifest(_dataset))!
        .version, '0.9');
  });

  test('repairs a partial installation without touching other sources',
      () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final imported = _syntheticPreview();
    final custom = Food(
        id: 'custom:mine',
        name: 'My own food',
        per100g: NutrientProfile({}),
        source: const FoodSource(
            dataset: 'custom-user-entry', datasetId: 'mine'));
    await DriftFoodRepository(db).replaceCatalogueBatch([custom]);
    await _provision(db, approval, load: () async => bytes);

    final removed = imported.records.last.food.id;
    await (db.delete(db.catalogFoods)
          ..where((row) => row.id.equals(removed)))
        .go();

    final repaired = await _provision(db, approval, load: () async => bytes);

    expect(repaired.status, BuiltInCatalogueProvisionStatus.repaired);
    expect(repaired.foodCount, imported.pack.foods.length);
    expect(await DriftFoodRepository(db).findById(removed), isNotNull);
    expect(await DriftFoodRepository(db).findById('custom:mine'), isNotNull);
    final audit = await CatalogueInstallService(db).readSourceAudit(_dataset);
    expect(audit!.records, hasLength(imported.pack.foods.length));
  });

  test('a missing audit triggers a source-scoped repair', () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final imported = _syntheticPreview();
    await _provision(db, approval, load: () async => bytes);
    final row = imported.records.first.food.id;
    await (db.update(db.catalogFoods)
          ..where((candidate) => candidate.id.equals(row)))
        .write(const CatalogFoodsCompanion(detailsJson: Value('{}')));

    final repaired = await _provision(db, approval, load: () async => bytes);

    expect(repaired.status, BuiltInCatalogueProvisionStatus.repaired);
    final audit = await CatalogueInstallService(db).readSourceAudit(_dataset);
    expect(audit!.records, hasLength(imported.pack.foods.length));
  });

  test('removes only the exact development fixture and preserves user records',
      () async {
    final bytes = buildSyntheticInsaWorkbook().bytes;
    final approval = await _approval(bytes);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final foods = DriftFoodRepository(db);
    final fixture = developmentCatalogue();
    await foods.replaceCatalogueBatch(fixture);
    await foods.replaceCatalogueBatch([
      Food(
          id: 'custom:mine',
          name: 'My own food',
          per100g: NutrientProfile({}),
          source: const FoodSource(
              dataset: 'custom-user-entry', datasetId: 'mine'))
    ]);
    final apple = fixture.first;
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'entry-1',
        requestId: 'request-1',
        diaryDate: DiaryDate(2025, 3, 29),
        stamp: EventStamp(
            instant: DateTime.utc(2025, 3, 29, 12), offsetMinutes: 0),
        channel: EntryChannel.search,
        items: [
          LoggedItem(
              name: apple.name,
              grams: 100,
              foodId: apple.id,
              nutrients: apple.per100g)
        ],
        recordedAt: DateTime.utc(2025, 3, 29, 12)));

    await _provision(db, approval, load: () async => bytes);

    expect(await foods.findById('custom:mine'), isNotNull);
    expect(await foods.findById(apple.id), isNull);
    final entries =
        await DriftEntryRepository(db).entriesFor(DiaryDate(2025, 3, 29));
    expect(entries, hasLength(1));
    expect(entries.single.items.single.name, apple.name);
    expect(entries.single.items.single.foodId, apple.id);
    expect(entries.single.items.single.nutrients.toJson(),
        apple.per100g.toJson());
    expect(await CatalogueInstallService(db).installedFoodCount('dev-fixture'),
        0);
  });
}
