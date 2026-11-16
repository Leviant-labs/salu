import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/catalogue/catalogue_preview_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

const _versionField = Key('catalogue-dataset-version');
const _licenceField = Key('catalogue-licence');
const _attributionField = Key('catalogue-attribution');

const _missingMetadata =
    'Dataset version, licence and attribution are required for source data.';

const _ciqualVersion = '2020-07-07';
const _ciqualLicence = 'Licence Ouverte 2.0';
const _ciqualAttribution = 'ANSES CIQUAL';

/// Minimal documented FoodData Central record shape.
///
/// The vitamin D value is expressed in IU, which this build cannot convert, so
/// the record exercises per-record diagnostics instead of an error.
String _usdaRecord() => jsonEncode({
      'fdcId': 12345,
      'description': 'Test food',
      'dataType': 'Foundation',
      'foodNutrients': [
        {
          'nutrient': {
            'id': 1008,
            'number': '208',
            'name': 'Energy',
            'unitName': 'kcal'
          },
          'amount': 100
        },
        {
          'nutrient': {
            'id': 1003,
            'number': '203',
            'name': 'Protein',
            'unitName': 'g'
          },
          'amount': 5
        },
        {
          'nutrient': {
            'id': 1114,
            'number': '328',
            'name': 'Vitamin D (D2 + D3)',
            'unitName': 'IU'
          },
          'amount': 10
        }
      ]
    });

/// Minimal documented Open Food Facts product shape with a valid GTIN-13.
String _offRecord() => jsonEncode({
      'code': '3274080005003',
      'product_name': 'Test beverage',
      'nutriments': {
        'energy-kcal_100g': 42,
        'proteins_100g': 1,
        'proteins_unit': 'g',
        'carbohydrates_100g': 8,
        'carbohydrates_unit': 'g'
      }
    });

/// Scrolls the horizontal source selector until [label] is visible, then taps
/// it. The selector deliberately scrolls on narrow screens, so tests must use
/// real scrolling instead of tapping an off-screen segment.
Future<void> _selectSource(WidgetTester t, String label) async {
  final target = find.text(label);
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

Future<void> _switchToRaw(WidgetTester t) =>
    _selectSource(t, 'Raw source JSON');

Future<void> _switchToCiqual(WidgetTester t) => _selectSource(t, 'CIQUAL XML');

Future<void> _switchToInsa(WidgetTester t) => _selectSource(t, 'INSA BDCA');

Future<void> _enterMetadata(WidgetTester t,
    {String version = '2024-10',
    String licence = 'CC0-1.0',
    String attribution = 'USDA FoodData Central'}) async {
  await t.enterText(find.byKey(_versionField), version);
  await t.enterText(find.byKey(_licenceField), licence);
  await t.enterText(find.byKey(_attributionField), attribution);
}

Future<void> _chooseSourceJson(WidgetTester t) async {
  await t.ensureVisible(find.text('Choose source JSON'));
  await t.pump();
  await t.tap(find.text('Choose source JSON'));
  await t.pumpAndSettle();
}

Future<void> _chooseCiqualFiles(WidgetTester t) async {
  await t.ensureVisible(find.text('Choose CIQUAL XML files'));
  await t.pump();
  await t.tap(find.text('Choose CIQUAL XML files'));
  await t.pumpAndSettle();
}

Future<void> _chooseInsaWorkbook(WidgetTester t, {bool pt = false}) async {
  final label = pt ? 'Escolher livro INSA' : 'Choose INSA workbook';
  await t.ensureVisible(find.text(label));
  await t.pump();
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

List<int> _ciqualTable(String records) => utf8.encode(
    '<?xml version="1.0" encoding="utf-8" ?>\n<TABLE>\n$records\n</TABLE>');

/// Minimal official `alim_*.xml` document with one food.
List<int> _ciqualFoods() => _ciqualTable('''
<ALIM>
  <alim_code>1234</alim_code>
  <alim_nom_fr>Pomme de terre, bouillie/cuite à l&apos;eau</alim_nom_fr>
  <alim_nom_eng>Potato, boiled/cooked in water</alim_nom_eng>
  <alim_grp_code>02</alim_grp_code>
  <alim_ssgrp_code>0201</alim_ssgrp_code>
  <alim_ssssgrp_code>020101</alim_ssssgrp_code>
  <facteur_Jones>6.25</facteur_Jones>
</ALIM>''');

/// Minimal official `const_*.xml` document with one reviewed constituent and
/// one constituent this build cannot map.
List<int> _ciqualConstituents() => _ciqualTable('''
<CONST>
  <const_code>25000</const_code>
  <const_nom_fr>Protéines, N x facteur de Jones (g/100 g)</const_nom_fr>
  <const_nom_eng>Protein (g/100g)</const_nom_eng>
  <code_INFOODS>PROCNT</code_INFOODS>
</CONST>
<CONST>
  <const_code>10004</const_code>
  <const_nom_fr>Sel (g/100 g)</const_nom_fr>
  <const_nom_eng>Salt (g/100g)</const_nom_eng>
</CONST>''');

/// Minimal official `compo_*.xml` document for food 1234.
List<int> _ciqualCompositions() => _ciqualTable('''
<COMPO>
  <alim_code>1234</alim_code>
  <const_code>25000</const_code>
  <teneur>5</teneur>
  <code_confiance>A</code_confiance>
  <source_code>10</source_code>
</COMPO>
<COMPO>
  <alim_code>1234</alim_code>
  <const_code>10004</const_code>
  <teneur>0.5</teneur>
  <code_confiance>A</code_confiance>
  <source_code>10</source_code>
</COMPO>''');

/// Minimal official `alim_grp_*.xml` document matching food 1234.
List<int> _ciqualGroups() => _ciqualTable('''
<ALIM_GRP>
  <alim_grp_code>02</alim_grp_code>
  <alim_grp_nom_fr>fruits, légumes, légumineuses et oléagineux</alim_grp_nom_fr>
  <alim_grp_nom_eng>fruits, vegetables, legumes and nuts</alim_grp_nom_eng>
  <alim_ssgrp_code>0201</alim_ssgrp_code>
  <alim_ssgrp_nom_fr>pommes de terre et autres tubercules</alim_ssgrp_nom_fr>
  <alim_ssgrp_nom_eng>potatoes and other tubers</alim_ssgrp_nom_eng>
  <alim_ssssgrp_code>020101</alim_ssssgrp_code>
  <alim_ssssgrp_nom_fr>pommes de terre</alim_ssssgrp_nom_fr>
  <alim_ssssgrp_nom_eng>potatoes</alim_ssssgrp_nom_eng>
</ALIM_GRP>''');

/// Minimal official `sources_*.xml` document citing source code 10.
List<int> _ciqualSources() => _ciqualTable('''
<SOURCES>
  <source_code>10</source_code>
  <ref_citation>Test citation</ref_citation>
</SOURCES>''');

List<CiqualSourceDocument> _ciqualDocuments() => [
      CiqualSourceDocument(
          name: 'alim_2020_07_07.xml', bytes: _ciqualFoods()),
      CiqualSourceDocument(
          name: 'const_2020_07_07.xml', bytes: _ciqualConstituents()),
      CiqualSourceDocument(
          name: 'compo_2020_07_07.xml', bytes: _ciqualCompositions()),
      CiqualSourceDocument(
          name: 'alim_grp_2020_07_07.xml', bytes: _ciqualGroups()),
      CiqualSourceDocument(
          name: 'sources_2020_07_07.xml', bytes: _ciqualSources()),
    ];

const _insaWorkbookName = 'INSA - BDCA_v 7.1 - 2026.xlsx';
const _insaDataset = InsaBdcaWorkbookAdapter.dataset;
const _insaVersion = InsaBdcaWorkbookAdapter.version;
const _insaTerms = InsaBdcaWorkbookAdapter.terms;

/// Synthetic INSA import result shaped exactly like the adapter output.
///
/// It contains no real INSA rows: the bytes never reach the adapter because
/// the test seam replaces only the execution strategy.
SourcePackImport _insaImport({List<FoodImportIssue> issues = const []}) {
  const food = Food(
      id: '$_insaDataset:1001',
      name: 'Synthetic apple',
      per100g: NutrientProfile.empty(),
      source: FoodSource(
          dataset: _insaDataset,
          datasetId: '1001',
          datasetVersion: _insaVersion,
          licence: _insaTerms));
  return SourcePackImport(
      pack: CataloguePack(
          dataset: _insaDataset,
          version: _insaVersion,
          licence: _insaTerms,
          attribution: insaBdcaAttribution,
          foods: const [food]),
      records: [
        FoodImportResult(
            food: food,
            issues: const [],
            unmappedNutrients: const ['sugars, free'],
            sourceDetails: const {'alim_code': '1001'})
      ],
      issues: issues);
}

void main() {
  testWidgets('catalogue preview shows provenance and never installs',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final candidate = CataloguePack(
        dataset: 'fixture',
        version: '1',
        licence: 'fixture-only',
        attribution: 'Test source',
        foods: [
          Food(
              id: 'fixture:apple',
              name: 'Apple',
              per100g: const NutrientProfile.empty(),
              source: const FoodSource(
                  dataset: 'fixture',
                  datasetId: 'apple',
                  datasetVersion: '1',
                  licence: 'fixture-only'))
        ]);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(t, db,
        CataloguePreviewScreen(loadPack: () async => candidate.encode()));
    await t.tap(find.text('Choose catalogue pack'));
    await t.pumpAndSettle();
    expect(find.text('fixture · 1'), findsOneWidget);
    expect(find.text('Licence: fixture-only'), findsOneWidget);
    expect(find.text('Added: 1'), findsOneWidget);
    expect(find.text('fixture:apple'), findsOneWidget);
    expect(await ArchiveService(db).exportJson(), before);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('invalid catalogue does not show a preview', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(
        t, db, CataloguePreviewScreen(loadPack: () async => 'not json'));
    await t.tap(find.text('Choose catalogue pack'));
    await t.pumpAndSettle();
    expect(find.text('Could not read this catalogue pack.'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
  });

  testWidgets('raw USDA JSON previews records and diagnostics without writing',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t, db, CataloguePreviewScreen(loadPack: () async => _usdaRecord()));
    await _switchToRaw(t);
    await _enterMetadata(t);
    await _chooseSourceJson(t);
    expect(find.textContaining('Nothing is downloaded'), findsOneWidget);
    expect(find.text('usda-fdc · 2024-10'), findsOneWidget);
    expect(find.text('Licence: CC0-1.0'), findsOneWidget);
    expect(find.text('Attribution: USDA FoodData Central'), findsOneWidget);
    expect(find.text('Imported records: 1'), findsOneWidget);
    expect(find.text('Records with diagnostics: 1'), findsOneWidget);
    expect(find.text('usda-fdc:12345'), findsWidgets);
    expect(find.textContaining('unsupported-unit'), findsWidgets);
    expect(find.textContaining('Unmapped:'), findsWidgets);
    expect(find.text('Added: 1'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('raw import demands dataset version, licence and attribution',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var reads = 0;
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(loadPack: () async {
          reads++;
          return _usdaRecord();
        }));
    await _switchToRaw(t);
    await _chooseSourceJson(t);
    expect(reads, 0);
    expect(find.text(_missingMetadata), findsOneWidget);
    expect(find.text('Could not import these source records.'), findsNothing);
    expect(find.text('Required'), findsNWidgets(3));
    expect(find.textContaining('Added:'), findsNothing);
    await t.enterText(find.byKey(_versionField), '2024-10');
    await _chooseSourceJson(t);
    expect(reads, 0);
    expect(find.text('Required'), findsNWidgets(2));
    await t.enterText(find.byKey(_licenceField), 'CC0-1.0');
    await t.enterText(find.byKey(_attributionField), 'USDA FoodData Central');
    await _chooseSourceJson(t);
    expect(reads, 1);
    expect(find.text('usda-fdc · 2024-10'), findsOneWidget);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('malformed raw records fail the whole import without writes',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var payload = '[{"description": "No identifier"}]';
    await harness.pump(
        t, db, CataloguePreviewScreen(loadPack: () async => payload));
    await _switchToRaw(t);
    await _enterMetadata(t);
    await _chooseSourceJson(t);
    expect(
        find.text('Could not import these source records.'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    expect(find.textContaining('Imported records:'), findsNothing);
    payload = 'not json';
    await _chooseSourceJson(t);
    expect(
        find.text('Could not import these source records.'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    payload = '[]';
    await _chooseSourceJson(t);
    expect(
        find.text('Could not import these source records.'), findsOneWidget);
    expect(find.textContaining('Imported records:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('cancelling the raw source picker shows no error', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t, db, CataloguePreviewScreen(loadPack: () async => null));
    await _switchToRaw(t);
    await _enterMetadata(t);
    await _chooseSourceJson(t);
    expect(find.text('Could not import these source records.'), findsNothing);
    expect(find.text(_missingMetadata), findsNothing);
    expect(find.textContaining('Added:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('raw Open Food Facts JSON uses the selected source', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t, db, CataloguePreviewScreen(loadPack: () async => _offRecord()));
    await _switchToRaw(t);
    await t.ensureVisible(find.text('Open Food Facts'));
    await t.pump();
    await t.tap(find.text('Open Food Facts'));
    await t.pumpAndSettle();
    await _enterMetadata(t,
        version: '2025-01',
        licence: 'ODbL-1.0',
        attribution: 'Open Food Facts contributors');
    await _chooseSourceJson(t);
    expect(find.text('open-food-facts · 2025-01'), findsOneWidget);
    expect(
        find.text('Attribution: Open Food Facts contributors'), findsOneWidget);
    expect(find.text('open-food-facts:3274080005003'), findsWidgets);
    expect(find.text('Added: 1'), findsOneWidget);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('CIQUAL XML previews normalized records without writing',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var imports = 0;
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadCiqualFiles: () async => _ciqualDocuments(),
            runCiqualImport: (request) async {
              imports++;
              return importCiqualDocuments(request);
            }));
    await _switchToCiqual(t);
    await _enterMetadata(t,
        version: _ciqualVersion,
        licence: _ciqualLicence,
        attribution: _ciqualAttribution);
    await _chooseCiqualFiles(t);
    expect(imports, 1);
    expect(find.textContaining('alim_grp_*'), findsOneWidget);
    expect(find.text('Selected files'), findsOneWidget);
    expect(find.textContaining('alim_2020_07_07.xml'), findsOneWidget);
    expect(find.textContaining('sources_2020_07_07.xml'), findsOneWidget);
    expect(find.text('ciqual · $_ciqualVersion'), findsOneWidget);
    expect(find.text('Licence: $_ciqualLicence'), findsOneWidget);
    expect(find.text('Attribution: $_ciqualAttribution'), findsOneWidget);
    expect(find.text('Imported records: 1'), findsOneWidget);
    expect(find.text('Records with diagnostics: 1'), findsOneWidget);
    expect(find.textContaining('Unmapped:'), findsWidgets);
    expect(find.text('ciqual:1234'), findsWidgets);
    expect(find.text('Added: 1'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('CIQUAL import demands dataset version, licence and attribution',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var reads = 0;
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(loadCiqualFiles: () async {
          reads++;
          return _ciqualDocuments();
        }));
    await _switchToCiqual(t);
    await _chooseCiqualFiles(t);
    expect(reads, 0);
    expect(find.text(_missingMetadata), findsOneWidget);
    expect(find.text('Required'), findsNWidgets(3));
    expect(find.text('Could not import these CIQUAL files.'), findsNothing);
    expect(find.textContaining('Added:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('CIQUAL preview rejects incomplete file selections',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var imports = 0;
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadCiqualFiles: () async => [
                  CiqualSourceDocument(
                      name: 'alim_2020_07_07.xml', bytes: _ciqualFoods()),
                  CiqualSourceDocument(
                      name: 'const_2020_07_07.xml',
                      bytes: _ciqualConstituents()),
                ],
            runCiqualImport: (request) async {
              imports++;
              return importCiqualDocuments(request);
            }));
    await _switchToCiqual(t);
    await _enterMetadata(t,
        version: _ciqualVersion,
        licence: _ciqualLicence,
        attribution: _ciqualAttribution);
    await _chooseCiqualFiles(t);
    expect(imports, 0);
    expect(find.text('Could not import these CIQUAL files.'), findsOneWidget);
    expect(find.textContaining('missing: compositions (compo_*)'),
        findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    expect(find.textContaining('Imported records:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('malformed CIQUAL XML fails the whole import without writes',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadCiqualFiles: () async => [
                  CiqualSourceDocument(
                      name: 'alim_2020_07_07.xml',
                      bytes: utf8.encode('not xml')),
                  CiqualSourceDocument(
                      name: 'const_2020_07_07.xml',
                      bytes: _ciqualConstituents()),
                  CiqualSourceDocument(
                      name: 'compo_2020_07_07.xml',
                      bytes: _ciqualCompositions()),
                ],
            runCiqualImport: (request) async =>
                importCiqualDocuments(request)));
    await _switchToCiqual(t);
    await _enterMetadata(t,
        version: _ciqualVersion,
        licence: _ciqualLicence,
        attribution: _ciqualAttribution);
    await _chooseCiqualFiles(t);
    expect(find.text('Could not import these CIQUAL files.'), findsOneWidget);
    expect(find.textContaining('Invalid CIQUAL XML'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    expect(find.textContaining('Imported records:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('cancelling the CIQUAL picker shows no error', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t, db, CataloguePreviewScreen(loadCiqualFiles: () async => null));
    await _switchToCiqual(t);
    await _enterMetadata(t,
        version: _ciqualVersion,
        licence: _ciqualLicence,
        attribution: _ciqualAttribution);
    await _chooseCiqualFiles(t);
    expect(find.text('Could not import these CIQUAL files.'), findsNothing);
    expect(find.text(_missingMetadata), findsNothing);
    expect(find.textContaining('Added:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('INSA workbook previews with the required citation and never installs',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var imports = 0;
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadInsaWorkbook: () async => const InsaWorkbookSelection(
                name: _insaWorkbookName, bytes: [1, 2, 3, 4]),
            runInsaImport: (bytes) async {
              imports++;
              expect(bytes, const [1, 2, 3, 4]);
              return _insaImport(issues: const [
                FoodImportIssue('unmapped-component',
                    'Component 999 has no reviewed mapping')
              ]);
            }));
    await _switchToInsa(t);
    expect(find.text('Required source citation'), findsOneWidget);
    expect(find.text(insaBdcaAttribution), findsOneWidget);
    expect(find.textContaining('does not bundle this workbook'), findsOneWidget);
    expect(find.textContaining('permission to redistribute'), findsOneWidget);
    expect(find.textContaining('content and licence review'), findsOneWidget);
    expect(find.textContaining('Blank cells remain unknown'), findsOneWidget);
    expect(find.byKey(_versionField), findsNothing);
    expect(find.byKey(_licenceField), findsNothing);
    expect(find.byKey(_attributionField), findsNothing);
    await _chooseInsaWorkbook(t);
    expect(imports, 1);
    expect(find.text('Selected workbook'), findsOneWidget);
    expect(find.text(_insaWorkbookName), findsOneWidget);
    expect(find.text('$_insaDataset · $_insaVersion'), findsOneWidget);
    expect(find.text('Licence: $_insaTerms'), findsOneWidget);
    expect(find.text('Attribution: $insaBdcaAttribution'), findsOneWidget);
    expect(find.text('Imported records: 1'), findsOneWidget);
    expect(find.text('Source document issues: 1'), findsOneWidget);
    expect(find.textContaining('unmapped-component'), findsOneWidget);
    expect(find.text('$_insaDataset:1001'), findsWidgets);
    expect(find.text('Added: 1'), findsOneWidget);
    expect(find.text('Installed version: none'), findsOneWidget);
    expect(find.textContaining('Nothing has been installed'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('invalid INSA workbook surfaces the importer failure without writes',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadInsaWorkbook: () async => const InsaWorkbookSelection(
                name: 'substituted.xlsx', bytes: [9, 9, 9]),
            runInsaImport: (bytes) async => throw const FormatException(
                'INSA workbook SHA-256 does not match the pinned release')));
    await _switchToInsa(t);
    await _chooseInsaWorkbook(t);
    expect(find.text('Could not import this INSA workbook.'), findsOneWidget);
    expect(find.textContaining('SHA-256 does not match'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    expect(find.textContaining('Imported records:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('empty INSA workbook is rejected before normalization',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var imports = 0;
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadInsaWorkbook: () async => const InsaWorkbookSelection(
                name: 'empty.xlsx', bytes: []),
            runInsaImport: (bytes) async {
              imports++;
              return _insaImport();
            }));
    await _switchToInsa(t);
    await _chooseInsaWorkbook(t);
    expect(imports, 0);
    expect(find.text('Could not import this INSA workbook.'), findsOneWidget);
    expect(find.textContaining('is empty'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('oversized INSA workbook is rejected before normalization',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    var imports = 0;
    final oversized =
        Uint8List(SourcePackImporter.maxInsaWorkbookBytes + 1);
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadInsaWorkbook: () async =>
                InsaWorkbookSelection(name: 'oversized.xlsx', bytes: oversized),
            runInsaImport: (bytes) async {
              imports++;
              return _insaImport();
            }));
    await _switchToInsa(t);
    await _chooseInsaWorkbook(t);
    expect(imports, 0);
    expect(find.text('Could not import this INSA workbook.'), findsOneWidget);
    expect(find.textContaining('exceeds the'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  testWidgets('cancelling the INSA picker shows no error', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(
        t, db, CataloguePreviewScreen(loadInsaWorkbook: () async => null));
    await _switchToInsa(t);
    await _chooseInsaWorkbook(t);
    expect(find.text('Could not import this INSA workbook.'), findsNothing);
    expect(find.textContaining('Added:'), findsNothing);
    expect(await ArchiveService(db).exportJson(), before);
  });

  test('production INSA import wrapper rejects non-official bytes', () async {
    await expectLater(
        importInsaWorkbookBytes(const [1, 2, 3]),
        throwsA(isA<FormatException>()
            .having((error) => error.message, 'message', contains('SHA-256'))));
  });

  testWidgets('INSA preview is localized and keeps the citation verbatim',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(
        t,
        db,
        CataloguePreviewScreen(
            loadInsaWorkbook: () async => const InsaWorkbookSelection(
                name: _insaWorkbookName, bytes: [1, 2, 3, 4]),
            runInsaImport: (bytes) async => _insaImport()),
        pt: true);
    await _switchToInsa(t);
    expect(find.text('Citação obrigatória da fonte'), findsOneWidget);
    expect(find.text(insaBdcaAttribution), findsOneWidget);
    expect(find.textContaining('não inclui este livro'), findsOneWidget);
    expect(find.text('Escolher livro INSA'), findsOneWidget);
    await _chooseInsaWorkbook(t, pt: true);
    expect(find.text('Registos importados: 1'), findsOneWidget);
    expect(find.text('Atribuição: $insaBdcaAttribution'), findsOneWidget);
    expect(find.text('Adicionados: 1'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });
}
