import 'dart:typed_data';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart'
    show
        AppDatabase,
        ArchiveService,
        CatalogueInstallService,
        CataloguePack,
        FoodImportIssue,
        InsaBdcaWorkbookAdapter,
        InsaBdcaWorkbookParser,
        catalogueFoodFingerprint;
import 'package:salu_data/src/import/source_pack_import.dart';
import 'package:test/test.dart';

import 'insa_workbook_fixture.dart';

/// The visible attribution required by the source's terms. It is repeated here
/// deliberately so a change to the imported pack cannot silently weaken it.
const _attribution =
    'Fonte: Base de Dados da Composição de Alimentos. Instituto Nacional de '
    'Saúde Doutor Ricardo Jorge, I. P.- INSA. v 7.1 - 2026';

/// A synthetic preview built through the adapter's deliberately unverified
/// structural parser.
///
/// Its dataset id is `insa-bdca-unverified`, so it cannot be mistaken for a
/// trusted 7.1-2026 workbook; production `importInsaWorkbook` only accepts
/// bytes matching the pinned SHA-256. It exists to exercise the preview, audit
/// and activation-gate behaviour without copying any real INSA row.
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

void main() {
  group('INSA unverified synthetic preview', () {
    test('never presents synthetic records as trusted production data', () {
      final imported = _syntheticPreview();

      expect(imported.pack.dataset, 'insa-bdca-unverified');
      expect(imported.pack.dataset, isNot(InsaBdcaWorkbookAdapter.dataset));
      expect(imported.issues.map((issue) => issue.code),
          contains('identity-unverified'));
      expect(imported.records, isNotEmpty);
      expect(imported.records, hasLength(imported.pack.foods.length));
      for (final result in imported.records) {
        expect(result.food.id, startsWith('insa-bdca-unverified:'));
        expect(result.food.source.dataset, 'insa-bdca-unverified');
        expect(result.food.source.datasetVersion, '7.1-2026');
        expect(result.food.source.licence, InsaBdcaWorkbookAdapter.terms);
        expect(result.food.quality, DataQuality.imported);
        expect(result.sourceDetails['identityVerified'], isFalse);
        expect(result.sourceDetails.containsKey('workbookSha256'), isFalse);
        // The source declares no allergen status, so none is invented.
        expect(result.food.allergens, isNull);
        // No density or portion is invented for a mass/volume basis.
        expect(result.food.portions.portionGrams, isNull);
        expect(result.food.portions.densityGramsPerMillilitre, isNull);
      }
    });

    test('fixes terms and attribution without claiming a licence grant', () {
      final imported = _syntheticPreview();

      expect(imported.pack.attribution, _attribution);
      expect(imported.pack.licence, InsaBdcaWorkbookAdapter.terms);
      expect(imported.pack.licence, contains('Copyright'));
      expect(imported.pack.licence, contains('review'));
      expect(imported.pack.licence, contains('redistribution'));
      final terms = imported.pack.licence.toLowerCase();
      expect(terms, isNot(contains('spdx')));
      expect(terms, isNot(contains('licensed')));
      expect(terms, isNot(contains('approved')));
    });

    test('keeps returned collections immutable', () {
      final imported = _syntheticPreview();

      expect(() => imported.records.clear(), throwsUnsupportedError);
      expect(() => imported.issues.clear(), throwsUnsupportedError);
      expect(
          () => imported.issues.add(const FoodImportIssue('x', 'y')),
          throwsUnsupportedError);
      expect(imported.issues, isA<List<FoodImportIssue>>());
    });

    test('audit binds each record to the exact snapshot', () async {
      final imported = _syntheticPreview();
      final audit = await imported.sourceAudit;

      expect(audit.dataset, 'insa-bdca-unverified');
      expect(audit.version, '7.1-2026');
      expect(audit.licence, InsaBdcaWorkbookAdapter.terms);
      expect(audit.attribution, _attribution);
      expect(audit.records.map((record) => record.foodId),
          imported.records.map((record) => record.food.id));
      expect(audit.records.first.sourceDetails['identityVerified'], isFalse);
      expect(audit.records.first.sourceDetails['attribution'], _attribution);
      for (var index = 0; index < audit.records.length; index++) {
        expect(audit.records[index].ordinal, index);
        expect(audit.records[index].foodFingerprint,
            await catalogueFoodFingerprint(imported.records[index].food));
      }
    });

    test('preview leaves storage untouched and needs a dataset review',
        () async {
      final imported = _syntheticPreview();
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final before = await ArchiveService(db).exportJson();

      final preview = await CatalogueInstallService(db).preview(imported.pack);
      expect(preview.installedVersion, isNull);
      expect(preview.addedIds, hasLength(imported.pack.foods.length));
      expect(await ArchiveService(db).exportJson(), before);

      await expectLater(
          CatalogueInstallService(db).activate(imported.pack,
              confirmed: true, sourceAudit: await imported.sourceAudit),
          throwsStateError);
      expect(await ArchiveService(db).exportJson(), before);
    });
  });

  group('INSA production import rejection', () {
    test('rejects empty and oversized bytes before reading a workbook',
        () async {
      await expectLater(
          SourcePackImporter.importInsaWorkbook(workbookBytes: const <int>[]),
          _formatIs('INSA workbook is empty'));
      await expectLater(
          SourcePackImporter.importInsaWorkbook(
              workbookBytes:
                  Uint8List(SourcePackImporter.maxInsaWorkbookBytes + 1)),
          _formatIs('INSA workbook exceeds the 8 MiB limit'));
    });

    test('rejects synthetic or substituted bytes at the pinned hash', () async {
      final fixture = buildSyntheticInsaWorkbook();
      await expectLater(
          SourcePackImporter.importInsaWorkbook(workbookBytes: fixture.bytes),
          _formatContains('SHA-256'));
    });

    test('rejects arbitrary bytes as a whole', () async {
      await expectLater(
          SourcePackImporter.importInsaWorkbook(
              workbookBytes: Uint8List.fromList(<int>[1, 2, 3, 4])),
          _formatContains('SHA-256'));
    });
  });
}

Matcher _formatIs(String message) => throwsA(isA<FormatException>()
    .having((error) => error.message, 'message', message));

Matcher _formatContains(String text) => throwsA(isA<FormatException>()
    .having((error) => error.message, 'message', contains(text)));
