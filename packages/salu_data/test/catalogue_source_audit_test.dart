import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

/// Fixtures only. They are not a dataset release, carry no approval, and use no
/// real source content. USDA records mirror the documented public API shape.
const _dataset = 'test-source';
const _licence = 'fixture-only';
const _attribution = 'Fixture only; not a dataset approval';

void main() {
  test('preview writes nothing and an activation without an audit keeps none',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final installer =
        CatalogueInstallService(db, approvedReviews: [_review('1')]);
    await installer.activate(_pack('1', [_food('$_dataset:apple', '1')]),
        confirmed: true);
    expect(await installer.readSourceAudit(_dataset), isNull);

    final before = await ArchiveService(db).exportJson();
    final proposed = _pack('2', [
      _food('$_dataset:apple', '2'),
      _food('$_dataset:pear', '2')
    ]);
    final preview = await installer.preview(proposed);
    expect(preview.installedVersion, '1');
    expect(preview.addedIds, ['$_dataset:pear']);
    expect(preview.replacedIds, ['$_dataset:apple']);
    expect(preview.retiredIds, isEmpty);
    expect(preview.conflictingIds, isEmpty);
    expect(await ArchiveService(db).exportJson(), before);
    expect(await installer.readSourceAudit(_dataset), isNull);
  });

  test('a source audit never substitutes for confirmation or the review',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    final apple = _food('$_dataset:apple', '1');
    final pack = _pack('1', [apple]);
    final audit = await _auditFoods([apple], version: '1');

    await expectLater(
        CatalogueInstallService(db)
            .activate(pack, confirmed: true, sourceAudit: audit),
        throwsStateError);
    expect(await ArchiveService(db).exportJson(), before);

    await expectLater(
        CatalogueInstallService(db, approvedReviews: [_review('1')])
            .activate(pack, confirmed: false, sourceAudit: audit),
        throwsStateError);
    expect(await ArchiveService(db).exportJson(), before);
    expect(
        await CatalogueInstallService(db).readSourceAudit(_dataset), isNull);
  });

  test('an audit that does not describe the pack is refused before writing',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final installer =
        CatalogueInstallService(db, approvedReviews: [_review('2')]);
    final apple = _food('$_dataset:apple', '2');
    final pear = _food('$_dataset:pear', '2');
    final pack = _pack('2', [apple, pear]);
    final before = await ArchiveService(db).exportJson();

    Future<void> refused(
        CataloguePack candidate, CatalogueSourceAudit audit) async {
      await expectLater(
          installer.activate(candidate, confirmed: true, sourceAudit: audit),
          throwsArgumentError);
      expect(await ArchiveService(db).exportJson(), before);
    }

    await refused(
        pack, await _auditFoods([apple, pear], version: '2', dataset: 'another'));
    await refused(pack, await _auditFoods([apple, pear], version: '1'));
    await refused(
        pack,
        await _auditFoods([apple, pear],
            version: '2', licence: 'another-licence'));
    await refused(
        pack,
        await _auditFoods([apple, pear],
            version: '2', attribution: 'another'));
    await refused(pack, await _auditFoods([apple], version: '2'));
    await refused(
        pack,
        _audit([
          await _record(apple, 0),
          _foreignRecord('$_dataset:other', 1)
        ], version: '2'));
    await refused(
        pack,
        _audit([
          await _record(apple, 0),
          await _record(pear, 1),
          _foreignRecord('$_dataset:other', 2)
        ], version: '2'));

    // Same identifiers and declared metadata, changed nutrient values: the
    // audit's snapshot binding must reject it rather than misattribute review.
    final changed = _food('$_dataset:apple', '2',
        per100g: NutrientProfile({NutrientKey.proteinG: NutrientMeasured(9.5)}));
    await refused(_pack('2', [changed, pear]),
        await _auditFoods([apple, pear], version: '2'));

    await installer.activate(pack,
        confirmed: true,
        sourceAudit: _audit([
          await _record(pear, 0),
          await _record(apple, 1)
        ], version: '2'));
    final retained = await installer.readSourceAudit(_dataset);
    expect(retained, isNotNull);
    expect(retained!.records.map((record) => record.foodId),
        ['$_dataset:pear', '$_dataset:apple']);

    // The matching audit for the changed content is accepted and replaces the
    // earlier binding; fingerprints are not just "anything different fails".
    await installer.activate(_pack('2', [changed, pear]),
        confirmed: true,
        sourceAudit: await _auditFoods([changed, pear], version: '2'));
    final replaced = await installer.readSourceAudit(_dataset);
    expect(replaced!.records.map((record) => record.foodId),
        [changed.id, pear.id]);
    expect(replaced.records.first.foodFingerprint,
        await catalogueFoodFingerprint(changed));
  });

  test('a rejected audit write rolls back foods, manifest and prior audit',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final installer = CatalogueInstallService(db,
        approvedReviews: [_review('1'), _review('2')]);
    final apple = _food('$_dataset:apple', '1');
    final gamma = _food('$_dataset:gamma', '1');
    await installer.activate(_pack('1', [apple, gamma]),
        confirmed: true,
        sourceAudit: _audit([
          await _record(apple, 0, details: {'brandName': 'Old'}),
          await _record(gamma, 1, issues: const [
            FoodImportIssue('unsupported-unit', 'Older diagnostics')
          ])
        ], version: '1'));
    final before = await ArchiveService(db).exportJson();

    // Fails the audit merge after the new rows were written, so the test only
    // passes when the whole activation transaction rolls back.
    await db.customStatement(
        "CREATE TRIGGER test_abort_audit BEFORE UPDATE OF details_json "
        "ON catalog_foods WHEN NEW.id = '$_dataset:beta' "
        "BEGIN SELECT RAISE(ABORT, 'test audit write failure'); END");

    final nextFoods = [
      _food('$_dataset:apple', '2'),
      _food('$_dataset:beta', '2'),
      _food('$_dataset:gamma', '2')
    ];
    final nextAudit = await _auditFoods(nextFoods, version: '2');
    await expectLater(
        installer.activate(_pack('2', nextFoods),
            confirmed: true, sourceAudit: nextAudit),
        throwsA(anything));
    expect(await ArchiveService(db).exportJson(), before);
    final retained = await installer.readSourceAudit(_dataset);
    expect(retained!.version, '1');
    expect(retained.records.map((record) => record.ordinal), [0, 1]);
    expect(retained.records.first.sourceDetails, {'brandName': 'Old'});
    expect(retained.records.last.issues.single.code, 'unsupported-unit');
  });

  test('retained diagnostics and source details survive archive and restore',
      () async {
    final source = AppDatabase.memory();
    final restored = AppDatabase.memory();
    addTearDown(source.close);
    addTearDown(restored.close);
    final apple = _food('$_dataset:apple', '1');
    final pear = _food('$_dataset:pear', '1');
    final audit = _audit([
      await _record(apple, 0, details: {
        'brandName': 'Example brand',
        'tags': ['en:vegan']
      }),
      await _record(pear, 1,
          issues: const [
            FoodImportIssue('unsupported-unit',
                'Unsupported nutrient unit "IU"',
                field: 'foodNutrients[0].unitName'),
            FoodImportIssue('invalid-barcode', 'Invalid barcode',
                field: 'gtinUpc')
          ],
          unmapped: ['1093 Sodium, Na'],
          details: {'nutrientCount': 2, 'nested': {'reviewed': false}})
    ], version: '1');
    final installer =
        CatalogueInstallService(source, approvedReviews: [_review('1')]);
    await installer.activate(_pack('1', [apple, pear]),
        confirmed: true, sourceAudit: audit);
    final archive = await ArchiveService(source).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);

    final retained =
        await CatalogueInstallService(restored).readSourceAudit(_dataset);
    expect(retained, isNotNull);
    expect(retained!.dataset, _dataset);
    expect(retained.version, '1');
    expect(retained.licence, _licence);
    expect(retained.attribution, _attribution);
    expect(retained.records, hasLength(2));
    expect(retained.records.map((record) => record.foodId),
        ['$_dataset:apple', '$_dataset:pear']);
    expect(retained.records.map((record) => record.ordinal), [0, 1]);
    expect(retained.records.map((record) => record.foodFingerprint),
        audit.records.map((record) => record.foodFingerprint));
    expect(retained.records.first.issues, isEmpty);
    expect(retained.records.first.unmappedNutrients, isEmpty);
    expect(retained.records.first.sourceDetails, {
      'brandName': 'Example brand',
      'tags': ['en:vegan']
    });
    final issues = retained.records.last.issues;
    expect(issues.map((issue) => issue.code),
        ['unsupported-unit', 'invalid-barcode']);
    expect(issues.first.message, 'Unsupported nutrient unit "IU"');
    expect(issues.first.field, 'foodNutrients[0].unitName');
    expect(issues.last.field, 'gtinUpc');
    expect(retained.records.last.unmappedNutrients, ['1093 Sodium, Na']);
    expect(retained.records.last.sourceDetails, {
      'nutrientCount': 2,
      'nested': {'reviewed': false}
    });
    expect(await ArchiveService(restored).exportJson(), archive);
    expect((await DriftFoodRepository(restored).findById('$_dataset:apple'))
        ?.name, '$_dataset:apple');
  });

  test('a retained audit refuses a food snapshot edited after activation',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final apple = _food('$_dataset:apple', '1',
        per100g: NutrientProfile({NutrientKey.proteinG: NutrientMeasured(2.5)}));
    final installer =
        CatalogueInstallService(db, approvedReviews: [_review('1')]);
    final audit = await _auditFoods([apple], version: '1');
    await installer.activate(_pack('1', [apple]),
        confirmed: true, sourceAudit: audit);
    final row = (await db.select(db.catalogFoods).get()).single;
    final details =
        Map<String, Object?>.from(jsonDecode(row.detailsJson) as Map);
    details['nutrients'] = <String, Object?>{};
    await db.customStatement(
        'UPDATE catalog_foods SET details_json = ? WHERE id = ?',
        [jsonEncode(details), apple.id]);
    await expectLater(installer.readSourceAudit(_dataset), throwsFormatException);
  });

  test('a normalized source import supplies the audit activation retains',
      () async {
    final imported = SourcePackImporter.importJson(
        source: 'usda-fdc',
        jsonText: jsonEncode(<String, Object?>{
          'foods': <Object?>[
            _usdaFood(fdcId: 1, name: 'One'),
            _usdaFood(fdcId: 2, name: 'Two', nutrients: <Object?>[
              _usdaNutrient(
                  id: 1093,
                  number: '307',
                  name: 'Sodium, Na',
                  unit: 'IU',
                  value: 5)
            ])
          ]
        }),
        datasetVersion: 'declared-2026-11-08',
        licence: 'declared-licence-unreviewed',
        attribution: 'Declared attribution; not a dataset approval');
    final audit = await imported.sourceAudit;
    expect(audit.records.map((record) => record.foodId),
        imported.records.map((record) => record.food.id));
    final expectedFingerprints = <String>[];
    for (final record in imported.records) {
      expectedFingerprints.add(await catalogueFoodFingerprint(record.food));
    }
    expect(audit.records.map((record) => record.foodFingerprint),
        expectedFingerprints);
    expect(audit.records.last.issues.map((issue) => issue.code),
        contains('unsupported-unit'));
    expect(audit.records.last.unmappedNutrients, isNotEmpty);

    final db = AppDatabase.memory();
    addTearDown(db.close);
    await expectLater(
        CatalogueInstallService(db)
            .activate(imported.pack, confirmed: true, sourceAudit: audit),
        throwsStateError);
    final installer = CatalogueInstallService(db, approvedReviews: [
      const DatasetReview(
          dataset: 'usda-fdc',
          version: 'declared-2026-11-08',
          licence: 'declared-licence-unreviewed',
          reviewId: 'review-usda-fixture')
    ]);
    await installer.activate(imported.pack,
        confirmed: true, sourceAudit: audit);
    final retained = await installer.readSourceAudit('usda-fdc');
    expect(retained, isNotNull);
    expect(retained!.records.map((record) => record.foodId),
        imported.records.map((record) => record.food.id));
    expect(retained.records.map((record) => record.foodFingerprint),
        audit.records.map((record) => record.foodFingerprint));
    expect(retained.records.last.issues.map((issue) => issue.code),
        audit.records.last.issues.map((issue) => issue.code));
    expect(retained.records.last.unmappedNutrients,
        audit.records.last.unmappedNutrients);
    expect(retained.records.last.sourceDetails, audit.records.last.sourceDetails);
  });
}

Food _food(String id, String version,
        {NutrientProfile per100g = const NutrientProfile.empty()}) =>
    Food(
        id: id,
        name: id,
        per100g: per100g,
        source: FoodSource(
            dataset: _dataset,
            datasetId: id.substring(_dataset.length + 1),
            datasetVersion: version,
            licence: _licence));

CataloguePack _pack(String version, List<Food> foods) => CataloguePack(
    dataset: _dataset,
    version: version,
    licence: _licence,
    attribution: _attribution,
    foods: foods);

DatasetReview _review(String version) => DatasetReview(
    dataset: _dataset,
    version: version,
    licence: _licence,
    reviewId: 'review-$version');

Future<CatalogueSourceRecordAudit> _record(Food food, int ordinal,
        {List<FoodImportIssue> issues = const [],
        List<String> unmapped = const [],
        Map<String, Object?> details = const {}}) async =>
    CatalogueSourceRecordAudit(
        foodId: food.id,
        foodFingerprint: await catalogueFoodFingerprint(food),
        ordinal: ordinal,
        issues: issues,
        unmappedNutrients: unmapped,
        sourceDetails: details);

/// A record naming a food that is not in the pack; its fingerprint is never
/// compared because the identifier check refuses first.
CatalogueSourceRecordAudit _foreignRecord(String foodId, int ordinal) =>
    CatalogueSourceRecordAudit(
        foodId: foodId,
        foodFingerprint: List.filled(64, '0').join(),
        ordinal: ordinal,
        issues: const [],
        unmappedNutrients: const [],
        sourceDetails: const {});

CatalogueSourceAudit _audit(List<CatalogueSourceRecordAudit> records,
        {required String version,
        String dataset = _dataset,
        String licence = _licence,
        String attribution = _attribution}) =>
    CatalogueSourceAudit(
        dataset: dataset,
        version: version,
        licence: licence,
        attribution: attribution,
        records: records);

Future<CatalogueSourceAudit> _auditFoods(List<Food> foods,
        {required String version,
        String dataset = _dataset,
        String licence = _licence,
        String attribution = _attribution}) async {
  final records = <CatalogueSourceRecordAudit>[];
  for (var index = 0; index < foods.length; index++) {
    records.add(await _record(foods[index], index));
  }
  return _audit(records,
      version: version,
      dataset: dataset,
      licence: licence,
      attribution: attribution);
}

Map<String, Object?> _usdaFood(
        {required int fdcId,
        required String name,
        List<Object?>? nutrients}) =>
    <String, Object?>{
      'fdcId': fdcId,
      'description': name,
      'dataType': 'Foundation',
      'foodNutrients': nutrients ??
          <Object?>[
            _usdaNutrient(
                id: 1003,
                number: '203',
                name: 'Protein',
                unit: 'G',
                value: 2.5)
          ]
    };

Map<String, Object?> _usdaNutrient(
        {required int id,
        required String number,
        required String name,
        required String unit,
        required num value}) =>
    <String, Object?>{
      'nutrientId': id,
      'nutrientNumber': number,
      'nutrientName': name,
      'unitName': unit,
      'value': value
    };
