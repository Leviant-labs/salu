import 'dart:convert';
import 'dart:typed_data';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart'
    show DriftFoodRepository, foodSnapshot;
import 'package:salu_data/src/import/insa_bdca_workbook.dart';
import 'package:salu_data/src/import/insa_zip.dart';
import 'package:test/test.dart';

import 'insa_workbook_fixture.dart';

Matcher throwsFormatException(String messagePart) => throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains(messagePart),
      ),
    );

InsaBdcaWorkbookPreview previewFor(SyntheticInsaWorkbook workbook) =>
    InsaBdcaWorkbookParser.parse(workbookBytes: workbook.bytes);

void main() {
  group('INSA BDCA workbook normalization', () {
    test('normalizes synthetic 7.1 rows deterministically', () {
      final workbook = buildSyntheticInsaWorkbook();
      final preview = previewFor(workbook);
      final results = preview.adaptAll();
      expect(results, hasLength(2));

      final result = results.first;
      final food = result.food;
      expect(food.id, 'insa-bdca-unverified:1001');
      expect(food.name, 'Synthetic food A');
      expect(food.source.dataset, 'insa-bdca-unverified');
      expect(food.source.datasetId, '1001');
      expect(food.source.datasetVersion, '7.1-2026');
      expect(food.source.licence, InsaBdcaWorkbookAdapter.terms);
      expect(food.quality, DataQuality.imported);
      expect(food.allergens, isNull);
      expect(food.basisUnit, FoodUnit.g);
      expect(food.basisValue, '100');
      expect(food.portions.densityGramsPerMillilitre, isNull);

      expect(food.per100g[NutrientKey.energyKcal].exactValue,
          Exact.parse('100'));
      expect(
          food.per100g[NutrientKey.energyKj].exactValue, Exact.parse('418.4'));
      expect(food.per100g[NutrientKey.fatG].exactValue, Exact.parse('2'));
      expect(food.per100g[NutrientKey.saturatedFatG].exactValue,
          Exact.parse('0.5'));
      expect(food.per100g[NutrientKey.sugarsG].exactValue, Exact.parse('3'));
      expect(food.per100g[NutrientKey.fiberG].exactValue, Exact.parse('1'));
      expect(food.per100g[NutrientKey.proteinG].exactValue, Exact.parse('4'));
      expect(food.per100g[NutrientKey.vitaminDUg].exactValue, Exact.zero);
      expect(food.per100g[NutrientKey.vitaminCMg].exactValue, Exact.parse('5'));
      expect(food.per100g[NutrientKey.sodiumMg].exactValue, Exact.parse('200'));
      expect(
          food.per100g[NutrientKey.calciumMg].exactValue, Exact.parse('30'));
      expect(food.per100g[NutrientKey.ironMg].exactValue, Exact.parse('1.2'));

      // Blanks are unknown, not zero.
      expect(food.per100g[NutrientKey.iodineUg].isKnown, isFalse);
      expect(
          food.observations
              .singleWhere((o) => o.nutrient.id == 'iodine_ug')
              .qualifier,
          ObservationQualifier.unknown);

      // INSA available carbohydrate is retained but not projected as EU.
      expect(food.per100g[NutrientKey.carbohydrateG].isKnown, isFalse);
      expect(food.per100g[NutrientKey.freeSugarsG].isKnown, isFalse);
      final carbohydrate = food.observations
          .singleWhere((o) => o.nutrient.id == 'carbohydrate_g');
      expect(carbohydrate.nutrient.definition,
          'insa_available_carbohydrate_excluding_fibre');
      expect(carbohydrate.amount, Exact.parse('10'));

      expect(result.sourceDetails['attribution'],
          InsaBdcaWorkbookAdapter.attribution);
      expect(result.sourceDetails['identityVerified'], isFalse);
      expect(result.sourceDetails.containsKey('workbookSha256'), isFalse);
      expect(result.sourceDetails['basis'], 'per 100 g edible portion');
      expect(result.issues.map((issue) => issue.code),
          contains('ambiguous-definition'));
      // Every main-sheet constituent column now has a reviewed identity.
      expect(food.per100g[NutrientKey.potassiumMg].exactValue, Exact.parse('50'));
      expect(result.unmappedNutrients, isEmpty);

      final drinkResult = results[1];
      final drink = drinkResult.food;
      expect(drink.basisUnit, FoodUnit.ml);
      expect(drinkResult.sourceDetails['basis'], 'per 100 ml');
      expect(drink.portions.densityGramsPerMillilitre, isNull);
      expect(drink.allergens, isNull);
      expect(drink.per100g[NutrientKey.iodineUg].exactValue, Exact.parse('2'));

      DriftFoodRepository.validateFoods(
          [for (final normalized in results) normalized.food]);

      final again = preview.adaptAll();
      expect(
        jsonEncode([
          for (final normalized in again) foodSnapshot(normalized.food)
        ]),
        jsonEncode([
          for (final normalized in results) foodSnapshot(normalized.food)
        ]),
      );
      expect(preview.issues.map((issue) => issue.code),
          containsAll(<String>['identity-unverified', 'basis-rule']));
    });

    test('retains source details and unknown allergens without approval', () {
      final preview = previewFor(buildSyntheticInsaWorkbook());
      final result = preview.adaptAll().first;
      expect(result.sourceDetails['attribution'],
          contains('Fonte: Base de Dados da Composição de Alimentos'));
      expect(result.sourceDetails['foodEx2Level1'], 'Pratos compostos');
      expect(result.sourceDetails['allergenStatus'], contains('unknown'));
      expect(result.food.allergens, isNull);
      expect(result.food.quality, DataQuality.imported);
    });

    test('rejects empty bytes', () {
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: const <int>[]),
        throwsFormatException('INSA workbook is empty'),
      );
    });

    test('rejects oversized bytes before parsing', () {
      final bytes =
          Uint8List(InsaBdcaWorkbookAdapter.maxWorkbookBytes + 1);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: bytes),
        throwsFormatException('MiB limit'),
      );
    });

    test('production fromBytes still pins the official digest', () async {
      final workbook = buildSyntheticInsaWorkbook();
      await expectLater(
        InsaBdcaWorkbookAdapter.fromBytes(workbookBytes: workbook.bytes),
        throwsFormatException('SHA-256'),
      );
    });

    test('rejects a wrong sheet/version identity', () {
      final workbook = buildSyntheticInsaWorkbook(
          sheetName: 'INSA - BDCA_v 7.0 - 2025');
      expect(
        () => previewFor(workbook),
        throwsFormatException('sheet/version identity'),
      );
    });

    test('rejects a workbook whose information sheet lacks the version and '
        'attribution', () {
      final workbook = buildSyntheticInsaWorkbook(
          infoText: 'Atualizado em 03-03-2026; no version marker');
      expect(
        () => previewFor(workbook),
        throwsFormatException('sheet/version identity'),
      );
    });

    test('rejects a workbook without the source basis statement', () {
      final workbook = buildSyntheticInsaWorkbook(includeBasisNote: false);
      expect(
        () => previewFor(workbook),
        throwsFormatException('sheet/version identity'),
      );
    });

    test('rejects unexpected headers', () {
      final headers = List<String>.from(InsaBdcaWorkbookAdapter.headers);
      headers[5] = 'Energia [cal]';
      expect(
        () => previewFor(buildSyntheticInsaWorkbook(headers: headers)),
        throwsFormatException('unexpected headers'),
      );
    });

    test('rejects duplicate food codes', () {
      final workbook = buildSyntheticInsaWorkbook(rows: <Map<String, String?>>[
        <String, String?>{
          'Cod': '1001',
          'Nome do alimento': 'Synthetic A',
        },
        <String, String?>{
          'Cod': '1001',
          'Nome do alimento': 'Synthetic B',
        },
      ]);
      expect(
        () => previewFor(workbook),
        throwsFormatException('duplicates food code'),
      );
    });

    test('rejects a non-numeric mapped nutrient instead of guessing', () {
      final workbook = buildSyntheticInsaWorkbook(rows: <Map<String, String?>>[
        <String, String?>{
          'Cod': '1001',
          'Nome do alimento': 'Synthetic A',
          'Energia [kcal]': 'trace',
        },
      ]);
      expect(
        () => previewFor(workbook),
        throwsFormatException('unsupported value'),
      );
    });

    test('rejects a negative mapped nutrient', () {
      final workbook = buildSyntheticInsaWorkbook(rows: <Map<String, String?>>[
        <String, String?>{
          'Cod': '1001',
          'Nome do alimento': 'Synthetic A',
          'Energia [kcal]': '-1',
        },
      ]);
      expect(
        () => previewFor(workbook),
        throwsFormatException('negative amount'),
      );
    });
  });

  group('INSA BDCA archive safety', () {
    test('rejects a truncated ZIP', () {
      final workbook = buildSyntheticInsaWorkbook();
      final truncated =
          workbook.bytes.sublist(0, workbook.bytes.length - 10);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: truncated),
        throwsFormatException('not a valid ZIP archive'),
      );
    });

    test('rejects duplicate ZIP entries', () {
      final zip = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry('a', <int>[1], method: 0),
        SyntheticZipEntry('a', <int>[2], method: 0),
      ]);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: zip),
        throwsFormatException('duplicate entry'),
      );
    });

    test('rejects an unsupported compression method', () {
      final zip = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry('a', <int>[1], method: 99),
      ]);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: zip),
        throwsFormatException('unsupported compression method'),
      );
    });

    test('rejects an unsafe entry name', () {
      final zip = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry('../evil', <int>[1], method: 0),
      ]);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: zip),
        throwsFormatException('unsafe entry name'),
      );
    });

    test('rejects a nested archive entry', () {
      final zip = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry('inner.zip', <int>[1], method: 0),
      ]);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: zip),
        throwsFormatException('nested archive'),
      );
    });

    test('rejects an entry whose declared size exceeds the limit', () {
      final zip = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry(
          'xl/workbook.xml',
          <int>[1],
          declaredUncompressedSize:
              InsaZipLimits.maxEntryUncompressedBytes + 1,
        ),
      ]);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: zip),
        throwsFormatException('size limit'),
      );
    });

    test('rejects a total uncompressed size above the limit', () {
      const declared = 22 * 1024 * 1024;
      final zip = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry('a', <int>[1],
            declaredUncompressedSize: declared),
        SyntheticZipEntry('b', <int>[2],
            declaredUncompressedSize: declared),
        SyntheticZipEntry('c', <int>[3],
            declaredUncompressedSize: declared),
      ]);
      expect(
        () => InsaBdcaWorkbookParser.parse(workbookBytes: zip),
        throwsFormatException('total uncompressed size limit'),
      );
    });

    test('rejects a CRC mismatch when reading an entry', () {
      final bytes = buildSyntheticZip(const <SyntheticZipEntry>[
        SyntheticZipEntry('a', <int>[1, 2, 3], method: 0),
      ]);
      final corrupted = Uint8List.fromList(bytes);
      final dataOffset = 30 + 1; // local header + one-character name
      corrupted[dataOffset] = 0xFF;
      final archive = InsaZipArchive.parse(corrupted);
      expect(() => archive.read('a'), throwsFormatException('CRC-32'));
    });
  });

  group('INSA BDCA XML safety', () {
    test('rejects a DTD/entity declaration', () {
      final workbook = buildSyntheticInsaWorkbook(
        xmlOverrides: const <String, String>{
          'xl/worksheets/sheet1.xml':
              '<?xml version="1.0"?><!DOCTYPE worksheet><worksheet/>',
        },
      );
      expect(
        () => previewFor(workbook),
        throwsFormatException('DTD or entity declaration'),
      );
    });

    test('rejects an unknown entity reference', () {
      final workbook = buildSyntheticInsaWorkbook(
        xmlOverrides: const <String, String>{
          'xl/sharedStrings.xml':
              '<?xml version="1.0"?><sst>&bogus;</sst>',
        },
      );
      expect(
        () => previewFor(workbook),
        throwsFormatException('unknown entity'),
      );
    });

    test('rejects excessive XML nesting', () {
      final nested = '<x>' * 65;
      final closing = '</x>' * 65;
      final workbook = buildSyntheticInsaWorkbook(
        xmlOverrides: <String, String>{
          'xl/worksheets/sheet1.xml':
              '<?xml version="1.0"?><worksheet>$nested$closing</worksheet>',
        },
      );
      expect(
        () => previewFor(workbook),
        throwsFormatException('nesting depth'),
      );
    });

    test('rejects malformed XML', () {
      final workbook = buildSyntheticInsaWorkbook(
        xmlOverrides: const <String, String>{
          'xl/worksheets/sheet1.xml':
              '<?xml version="1.0"?><worksheet><sheetData></worksheet>',
        },
      );
      expect(
        () => previewFor(workbook),
        throwsFormatException('is malformed'),
      );
    });
  });
}
