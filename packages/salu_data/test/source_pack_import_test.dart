import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart'
    show
        AppDatabase,
        ArchiveService,
        CatalogueInstallService,
        DriftFoodRepository,
        catalogueFoodFingerprint;
import 'package:salu_data/src/import/source_pack_import.dart';
import 'package:test/test.dart';

/// Fixtures shaped like the documented public APIs. They are not a dataset,
/// carry no release approval, and are not used to activate anything.
///
/// USDA: https://fdc.nal.usda.gov/api-guide/
/// OFF: https://world.openfoodfacts.org/api/v2/product/3274080005003.json

const _usda = 'usda-fdc';
const _off = 'open-food-facts';
const _version = 'declared-2026-11-08';
const _licence = 'declared-licence-unreviewed';
const _attribution = 'Declared attribution; not a dataset approval';

void main() {
  group('USDA documents', () {
    test('imports a single food object with declared metadata', () {
      final result = _import(_usda, _usdaFood(fdcId: 42, name: 'Cheddar'));

      expect(result.records, hasLength(1));
      expect(result.pack.foods, hasLength(1));
      expect(result.pack.dataset, _usda);
      expect(result.pack.version, _version);
      expect(result.pack.licence, _licence);
      expect(result.pack.attribution, _attribution);

      final food = result.records.single.food;
      expect(result.pack.foods.single, same(food));
      expect(food.id, 'usda-fdc:42');
      expect(food.name, 'Cheddar');
      expect(food.source.dataset, _usda);
      expect(food.source.datasetId, '42');
      expect(food.source.datasetVersion, _version);
      expect(food.source.licence, _licence);
      expect(food.basisUnit, FoodUnit.g);
      expect(food.basisValue, '100');
      expect(food.per100g[NutrientKey.proteinG].numericValue, 2.5);
      expect(result.records.single.issues, isEmpty);
      expect(result.records.single.unmappedNutrients, isEmpty);
      DriftFoodRepository.validateFoods(result.pack.foods);
    });

    test('imports a foods search envelope without reordering records', () {
      final result = _import(_usda, <String, Object?>{
        'totalHits': 2,
        'foods': <Object?>[
          _usdaFood(fdcId: 1, name: 'One'),
          _usdaFood(fdcId: 2, name: 'Two'),
        ],
      });

      expect(result.records, hasLength(2));
      expect(result.pack.foods, hasLength(2));
      expect(result.records.map((record) => record.food.id),
          <String>['usda-fdc:1', 'usda-fdc:2']);
      expect(result.records.map((record) => record.food.name),
          <String>['One', 'Two']);
      expect(result.pack.foods.map((food) => food.id),
          <String>['usda-fdc:1', 'usda-fdc:2']);
      for (var index = 0; index < result.records.length; index++) {
        expect(result.pack.foods[index], same(result.records[index].food));
      }
    });

    test('imports the official Foundation Foods bulk envelope', () {
      final result = _import(_usda, <String, Object?>{
        'FoundationFoods': <Object?>[
          _usdaFood(fdcId: 321358, name: 'Hummus, commercial')
        ]
      });
      expect(result.pack.foods.single.id, 'usda-fdc:321358');
      expect(result.pack.foods.single.name, 'Hummus, commercial');
      expect(result.pack.foods.single.per100g[NutrientKey.proteinG].numericValue,
          2.5);
    });

    test('imports a bare array', () {
      final result = _import(_usda, <Object?>[
        _usdaFood(fdcId: 3, name: 'Three'),
        _usdaFood(fdcId: 4, name: 'Four'),
      ]);

      expect(result.records.map((record) => record.food.id),
          <String>['usda-fdc:3', 'usda-fdc:4']);
    });

    test('retains every record diagnostic instead of omitting the record', () {
      final record = _usdaFood(fdcId: 7, nutrients: <Object?>[
        _nutrient(
            id: 1093,
            number: '307',
            name: 'Sodium, Na',
            unit: 'IU',
            value: 5),
        _nutrient(
            id: 1003, number: '203', name: 'Protein', unit: 'G', value: 2.5),
      ]);
      record['gtinUpc'] = '123';
      record['brandName'] = 'Example brand';

      final result = _import(_usda, record);
      final diagnostics = result.records.single;

      expect(result.pack.foods, hasLength(1));
      expect(diagnostics.issues.map((issue) => issue.code),
          containsAll(<String>['unsupported-unit', 'invalid-barcode']));
      expect(diagnostics.unmappedNutrients, contains('1093 Sodium, Na'));
      expect(diagnostics.food.observations, hasLength(1));
      expect(diagnostics.food.barcodes, isEmpty);
      expect(diagnostics.sourceDetails['brandName'], 'Example brand');
      expect(result.pack.foods.single, same(diagnostics.food));
    });

    test('keeps diagnostics for every record in a multi-record document', () {
      final result = _import(_usda, <String, Object?>{
        'foods': <Object?>[
          _usdaFood(fdcId: 21, name: 'Has issue', nutrients: <Object?>[
            _nutrient(
                id: 1093,
                number: '307',
                name: 'Sodium, Na',
                unit: 'IU',
                value: 5),
          ]),
          _usdaFood(fdcId: 22, name: 'Clean'),
        ],
      });

      expect(result.records, hasLength(2));
      expect(result.pack.foods, hasLength(2));
      expect(result.records[0].issues.map((issue) => issue.code),
          containsAll(<String>['unsupported-unit', 'no-mapped-nutrients']));
      expect(result.records[1].issues, isEmpty);
      expect(result.pack.foods[0], same(result.records[0].food));
      expect(result.pack.foods[1], same(result.records[1].food));
      DriftFoodRepository.validateFoods(result.pack.foods);
    });

    test('keeps a record that supplies no nutrition data', () {
      final result = _import(
          _usda, _usdaFood(fdcId: 11, nutrients: const <Object?>[]));
      final diagnostics = result.records.single;

      expect(result.pack.foods, hasLength(1));
      expect(diagnostics.food.observations, isEmpty);
      expect(diagnostics.issues.map((issue) => issue.code),
          contains('no-nutrition-data'));
      DriftFoodRepository.validateFoods(result.pack.foods);
    });
  });

  group('Open Food Facts documents', () {
    test('imports a raw product object with declared metadata', () {
      final result = _import(_off, _offProduct(name: 'Water'));

      expect(result.records, hasLength(1));
      expect(result.pack.dataset, _off);
      expect(result.pack.version, _version);
      expect(result.pack.licence, _licence);
      expect(result.pack.attribution, _attribution);

      final food = result.records.single.food;
      expect(food.id, 'open-food-facts:3274080005003');
      expect(food.name, 'Water');
      expect(food.source.dataset, _off);
      expect(food.source.datasetId, '3274080005003');
      expect(food.source.datasetVersion, _version);
      expect(food.source.licence, _licence);
      expect(food.barcodes, <String>['3274080005003']);
      expect(food.per100g[NutrientKey.proteinG].numericValue, 3.2);
      expect(result.records.single.issues, isEmpty);
      DriftFoodRepository.validateFoods(result.pack.foods);
    });

    test('imports a v2/v3 product envelope', () {
      final result = _import(_off, <String, Object?>{
        'code': '3274080005003',
        'status': 1,
        'status_verbose': 'product found',
        'product': _offProduct(name: 'Envelope product'),
      });

      expect(result.records, hasLength(1));
      expect(result.records.single.food.name, 'Envelope product');
      expect(result.records.single.food.id,
          'open-food-facts:3274080005003');
    });

    test('imports a products search envelope and a bare array', () {
      final envelope = _import(_off, <String, Object?>{
        'count': 2,
        'products': <Object?>[
          _offProduct(),
          _offProduct(code: '3017620422003', name: 'Second product'),
        ],
      });
      final array = _import(_off, <Object?>[
        _offProduct(code: '3017620422003', name: 'Array product'),
      ]);

      expect(envelope.records.map((record) => record.food.id), <String>[
        'open-food-facts:3274080005003',
        'open-food-facts:3017620422003',
      ]);
      expect(envelope.records.map((record) => record.food.name),
          <String>['Test product', 'Second product']);
      expect(array.records.single.food.name, 'Array product');
    });

    test('retains every record diagnostic instead of omitting the record', () {
      final result = _import(
          _off,
          _offProduct(code: '123', nutriments: <String, Object?>{
            'proteins_100g': 3.2,
            'proteins_unit': 'g',
            'unmapped-nutrient_100g': 1,
          }));
      final diagnostics = result.records.single;

      expect(result.pack.foods, hasLength(1));
      expect(diagnostics.issues.map((issue) => issue.code),
          contains('invalid-barcode'));
      expect(diagnostics.unmappedNutrients, contains('unmapped-nutrient'));
      expect(diagnostics.food.barcodes, isEmpty);
      expect(diagnostics.food.observations, hasLength(1));
      expect(diagnostics.food.per100g[NutrientKey.proteinG].numericValue, 3.2);
      DriftFoodRepository.validateFoods(result.pack.foods);
    });
  });

  group('CIQUAL documents', () {
    test('imports every record with declared metadata and source diagnostics',
        () {
      final result = _importCiqual(
          groups: _ciqualGroupsXml(), sources: _ciqualSourcesXml());

      expect(result.pack.dataset, 'ciqual');
      expect(result.pack.version, _version);
      expect(result.pack.licence, _licence);
      expect(result.pack.attribution, _attribution);
      expect(result.records.map((record) => record.food.id),
          <String>['ciqual:1234', 'ciqual:5678', 'ciqual:9012']);
      expect(result.pack.foods.map((food) => food.id),
          <String>['ciqual:1234', 'ciqual:5678', 'ciqual:9012']);
      for (var index = 0; index < result.records.length; index++) {
        expect(result.pack.foods[index], same(result.records[index].food));
      }

      final first = result.records[0];
      expect(first.food.name, 'Pomme de terre, bouillie/cuite à l\'eau');
      expect(first.food.source.dataset, 'ciqual');
      expect(first.food.source.datasetId, '1234');
      expect(first.food.source.datasetVersion, _version);
      expect(first.food.source.licence, _licence);
      expect(first.food.basisUnit, FoodUnit.g);
      expect(first.food.basisValue, '100');
      expect(first.food.preparation, Preparation.cooked);
      expect(first.food.per100g[NutrientKey.energyKj].numericValue, 1490);
      expect(first.food.per100g[NutrientKey.proteinG].numericValue, 12.3456789);
      expect(first.food.per100g[NutrientKey.sodiumMg].numericValue, 4.62);
      expect(first.issues, isEmpty);
      expect(first.unmappedNutrients,
          <String>['10004 Salt (g/100g)']);
      expect(first.sourceDetails['alim_nom_eng'],
          'Potato, boiled/cooked in water');
      expect(first.sourceDetails['alim_grp_code'], '02');
      expect(first.sourceDetails['foodGroupNameFr'],
          'fruits, légumes, légumineuses et oléagineux');
      expect(first.sourceDetails['sourceCodes'], <String>['10']);

      final second = result.records[1];
      expect(second.food.name, 'Yaourt, nature');
      expect(second.food.per100g[NutrientKey.sodiumMg], NutrientValue.trace);
      expect(second.food.per100g[NutrientKey.fatG].numericValue, 5);
      expect(second.food.per100g[NutrientKey.energyKj], NutrientValue.unknown);
      expect(second.issues, hasLength(2));
      expect(
          second.issues.map((issue) => issue.code),
          containsAll(
              <String>['unknown-confidence', 'unsupported-source-value']));
      expect(second.sourceDetails['upperBounds'],
          <String, String>{'327': '< 10'});
      expect(
          second.unmappedNutrients,
          containsAll(<String>[
            '31000 Carbohydrate (g/100g)',
            '10004 Salt (g/100g)',
          ]));

      final third = result.records[2];
      expect(third.food.name, 'Eau');
      expect(third.food.observations, isEmpty);
      expect(third.issues.map((issue) => issue.code),
          <String>['no-nutrition-data']);
      expect(third.unmappedNutrients, isEmpty);

      DriftFoodRepository.validateFoods(result.pack.foods);
      expect(() => result.records.clear(), throwsUnsupportedError);
      expect(() => result.pack.foods.clear(), throwsUnsupportedError);
    });

    test('accepts omitted optional documents without inventing group details',
        () {
      final result = _importCiqual(
        foods: _ciqualTable(<String>[_ciqualAlim()]),
        constituents: _ciqualTable(<String>[_ciqualConst327()]),
        compositions: _ciqualTable(<String>[
          _ciqualCompo('1234', '327', '1490', source: '99'),
        ]),
      );
      final record = result.records.single;

      expect(record.food.per100g[NutrientKey.energyKj].numericValue, 1490);
      expect(record.sourceDetails.containsKey('foodGroupNameFr'), isFalse);
      expect(record.sourceDetails['sourceCodes'], <String>['99']);
      expect(record.issues, isEmpty);
      expect(record.unmappedNutrients, isEmpty);
      DriftFoodRepository.validateFoods(result.pack.foods);
    });

    test('rejects an undeclared source citation when sources are supplied', () {
      expect(
          () => _importCiqual(
                foods: _ciqualTable(<String>[_ciqualAlim()]),
                constituents: _ciqualTable(<String>[_ciqualConst327()]),
                compositions: _ciqualTable(<String>[
                  _ciqualCompo('1234', '327', '1490', source: '99'),
                ]),
                sources: _ciqualSourcesXml(),
              ),
          _formatContains('unknown source_code 99'));
    });

    test('decodes declared windows-1252 bytes without latin1 corruption', () {
      const name = 'Pomme de terre, cuite € \u2019 \u0153';
      final foods = _ciqualTable(<String>[
        _ciqualAlim(frenchName: name),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');
      final constituents = _ciqualTable(<String>[
        _ciqualConst327(),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');
      final compositions = _ciqualTable(<String>[
        _ciqualCompo('1234', '327', '1490'),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');

      final result = _importCiqualRaw(
        foodsBytes: _windows1252Bytes(foods),
        constituentsBytes: _windows1252Bytes(constituents),
        compositionsBytes: _windows1252Bytes(compositions),
      );

      expect(result.records.single.food.name, name);
      expect(result.pack.foods.single.name, name);
      expect(result.records.single.food.name, isNot(contains('â')));
    });

    test('rejects undefined windows-1252 bytes', () {
      final bytes = <int>[
        ...'<?xml version="1.0" encoding="windows-1252" ?>'.codeUnits,
        0x81,
      ];
      expect(
          () => _importCiqualRaw(
                foodsBytes: bytes,
                constituentsBytes: _windows1252Bytes(
                    _ciqualTable(<String>[_ciqualConst327()]).replaceFirst(
                        'encoding="utf-8"', 'encoding="windows-1252"')),
                compositionsBytes: _windows1252Bytes(
                    _ciqualTable(<String>[_ciqualCompo('1234', '327', '1490')])
                        .replaceFirst('encoding="utf-8"',
                            'encoding="windows-1252"')),
              ),
          _formatContains('undefined windows-1252 byte 0x81'));
    });

    test('validates declared metadata before decoding', () {
      expect(() => _importCiqual(datasetVersion: '  '), throwsArgumentError);
      expect(() => _importCiqual(licence: ''), throwsArgumentError);
      expect(() => _importCiqual(attribution: '\t'), throwsArgumentError);
      expect(
          () => _importCiqualRaw(
                datasetVersion: '',
                foodsBytes: const <int>[0xFF],
                constituentsBytes: const <int>[],
                compositionsBytes: const <int>[],
              ),
          throwsArgumentError);
    });

    test('trims declarations without turning them into a review', () {
      final result = _importCiqual(
        datasetVersion: ' fixture-ciqual-2025 ',
        licence: ' fixture-licence ',
        attribution: ' fixture attribution ',
      );

      expect(result.pack.version, 'fixture-ciqual-2025');
      expect(result.pack.licence, 'fixture-licence');
      expect(result.pack.attribution, 'fixture attribution');
      expect(result.records.first.food.source.datasetVersion,
          'fixture-ciqual-2025');
      expect(result.records.first.food.source.licence, 'fixture-licence');
    });

    test('rejects empty, malformed and inconsistent tables as a whole', () {
      expect(
          () => _importCiqualRaw(
                foodsBytes: const <int>[],
                constituentsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualConst327()])),
                compositionsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualCompo('1234', '327', '1490')])),
              ),
          _formatContains('CIQUAL foods XML is empty'));
      expect(() => _importCiqual(groups: ''),
          _formatContains('CIQUAL food groups XML is empty'));
      expect(() => _importCiqual(sources: ''),
          _formatContains('CIQUAL sources XML is empty'));
      expect(
          () => _importCiqualRaw(
                foodsBytes: const <int>[0x3C, 0xC3],
                constituentsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualConst327()])),
                compositionsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualCompo('1234', '327', '1490')])),
              ),
          _formatContains('not valid UTF-8'));
      expect(
          () => _importCiqualRaw(
                foodsBytes: const <int>[0xFF, 0xFE, 0x3C, 0x00],
                constituentsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualConst327()])),
                compositionsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualCompo('1234', '327', '1490')])),
              ),
          _formatContains('Unsupported UTF-16'));
      expect(
          () => _importCiqualRaw(
                foodsBytes: const <int>[0x100],
                constituentsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualConst327()])),
                compositionsBytes: utf8.encode(_ciqualTable(
                    <String>[_ciqualCompo('1234', '327', '1490')])),
              ),
          _formatContains('invalid byte value 256'));
      expect(() => _importCiqual(foods: _ciqualTable(<String>[])),
          _formatContains('no <ALIM> records'));
      expect(() => _importCiqual(constituents: _ciqualTable(<String>[])),
          _formatContains('no <CONST> records'));
      expect(() => _importCiqual(compositions: _ciqualTable(<String>[])),
          _formatContains('no <COMPO> records'));
      expect(() => _importCiqual(foods: '<TABLE><ALIM>'),
          throwsFormatException);
      expect(
          () => _importCiqual(
              foods: _ciqualTable(<String>[_ciqualAlim(), _ciqualAlim()])),
          _formatContains('Duplicate CIQUAL alim_code'));
      expect(
          () => _importCiqual(
              foods: _ciqualTable(<String>[_ciqualAlim(code: '12x4')])),
          _formatContains('is not numeric'));
      expect(
          () => _importCiqual(foods: _ciqualTable(<String>[
                '<ALIM><alim_code>1234</alim_code></ALIM>',
              ])),
          _formatContains('has no <alim_nom_fr>'));
      expect(
          () => _importCiqual(compositions: _ciqualTable(<String>[
                _ciqualCompo('9999', '327', '1'),
              ])),
          _formatContains('unknown alim_code 9999'));
      expect(
          () => _importCiqual(compositions: _ciqualTable(<String>[
                _ciqualCompo('1234', '9999', '1'),
              ])),
          _formatContains('unknown const_code 9999'));
      expect(
          () => _importCiqual(compositions: _ciqualTable(<String>[
                _ciqualCompo('1234', '327', '1'),
                _ciqualCompo('1234', '327', '2'),
              ])),
          _formatContains('Duplicate CIQUAL composition'));
      final unsupported = _ciqualTable(<String>[_ciqualAlim()])
          .replaceFirst('encoding="utf-8"', 'encoding="utf-16le"');
      expect(() => _importCiqual(foods: unsupported),
          _formatContains('Unsupported CIQUAL foods XML encoding'));
    });

    test('previews and audits a CIQUAL import without activating or approving',
        () async {
      final imported = _importCiqual();
      final audit = await imported.sourceAudit;

      expect(audit.dataset, 'ciqual');
      expect(audit.version, _version);
      expect(audit.licence, _licence);
      expect(audit.attribution, _attribution);
      expect(audit.records.map((record) => record.foodId),
          imported.records.map((record) => record.food.id));
      for (var index = 0; index < audit.records.length; index++) {
        expect(audit.records[index].ordinal, index);
        expect(audit.records[index].foodFingerprint,
            await catalogueFoodFingerprint(imported.records[index].food));
      }
      expect(
          audit.records[1].issues.map((issue) => issue.code),
          containsAll(
              <String>['unknown-confidence', 'unsupported-source-value']));
      expect(audit.records[1].unmappedNutrients, isNotEmpty);

      final db = AppDatabase.memory();
      addTearDown(db.close);
      final before = await ArchiveService(db).exportJson();
      final preview = await CatalogueInstallService(db).preview(imported.pack);
      expect(preview.installedVersion, isNull);
      expect(preview.addedIds,
          <String>['ciqual:1234', 'ciqual:5678', 'ciqual:9012']);
      expect(await ArchiveService(db).exportJson(), before);
      await expectLater(
          CatalogueInstallService(db).activate(imported.pack,
              confirmed: true, sourceAudit: audit),
          throwsStateError);
      expect(await ArchiveService(db).exportJson(), before);
    });
  });

  group('document rejection', () {
    test('rejects empty documents and empty record lists', () {
      expect(() => _import(_usda, <Object?>[]), _formatContains('no food records'));
      expect(() => _import(_usda, <String, Object?>{}),
          _formatContains('no food records'));
      expect(() => _import(_usda, <String, Object?>{'foods': <Object?>[]}),
          _formatContains('no food records'));
      expect(() => _import(_off, <String, Object?>{'products': <Object?>[]}),
          _formatContains('no food records'));
    });

    test('rejects invalid JSON and non-record documents', () {
      expect(
          () => SourcePackImporter.importJson(
                source: _usda,
                jsonText: '{',
                datasetVersion: _version,
                licence: _licence,
                attribution: _attribution,
              ),
          _formatContains('not valid JSON'));
      expect(() => _import(_usda, 'a string'), _formatContains('food object'));
      expect(() => _import(_usda, null), _formatContains('food object'));
      expect(() => _import(_usda, <Object?>[42]),
          _formatContains('document[0] must be a JSON object'));
      expect(() => _import(_usda, <Object?>[<String, Object?>{}]),
          _formatContains('document[0] is an empty object'));
    });

    test('rejects a non-array envelope payload', () {
      expect(() => _import(_usda, <String, Object?>{'foods': _usdaFood()}),
          _formatContains('"foods" must be a JSON array'));
      expect(() => _import(_off, <String, Object?>{'products': _offProduct()}),
          _formatContains('"products" must be a JSON array'));
    });

    test('fails the whole import when one record is malformed', () {
      final document = <Object?>[
        _usdaFood(fdcId: 1),
        <String, Object?>{'description': 'No fdcId'},
      ];
      expect(() => _import(_usda, document),
          _formatContains('document[1]: USDA record has no fdcId'));
      expect(() => _import(_usda, <String, Object?>{'fdcId': 9}),
          _formatContains('USDA record 9 has no description'));
    });

    test('rejects mixed envelopes and mixed records', () {
      expect(
          () => _import(_usda, <String, Object?>{
                'foods': <Object?>[],
                'products': <Object?>[],
              }),
          _formatContains('mixes "foods" and "products"'));
      expect(
          () => _import(_usda, <String, Object?>{
                'FoundationFoods': <Object?>[_usdaFood()],
                'foods': <Object?>[_usdaFood(fdcId: 2)],
              }),
          throwsFormatException);
      expect(
          () => _import(_off, <String, Object?>{
                'FoundationFoods': <Object?>[_usdaFood()],
              }),
          throwsFormatException);
      expect(() => _import(_off, <String, Object?>{'foods': <Object?>[
            _usdaFood()
          ]}),
          _formatContains('USDA "foods" envelope'));
      expect(() => _import(_usda, <String, Object?>{'products': <Object?>[
            _offProduct()
          ]}),
          _formatContains('Open Food Facts "products" envelope'));
      expect(() => _import(_usda, <Object?>[_usdaFood(), _offProduct()]),
          _formatContains('contains Open Food Facts fields'));
      expect(() => _import(_off, <Object?>[_offProduct(), _usdaFood()]),
          _formatContains('contains USDA fields'));
      expect(() => _import(_usda, _offProduct()),
          _formatContains('contains Open Food Facts fields'));
      expect(() => _import(_off, _usdaFood()),
          _formatContains('contains USDA fields'));
    });

    test('rejects duplicate food identifiers', () {
      expect(
          () => _import(_usda, <Object?>[
                _usdaFood(fdcId: 3),
                _usdaFood(fdcId: 3, name: 'Duplicate'),
              ]),
          _formatContains('repeats food identifier'));
      expect(
          () => _import(_off, <Object?>[
                _offProduct(),
                _offProduct(name: 'Duplicate'),
              ]),
          _formatContains('repeats food identifier'));
    });

    test('validates declared source metadata before parsing', () {
      expect(() => _import('ciqual', _usdaFood()), throwsArgumentError);
      expect(() => _import('USDA-FDC', _usdaFood()), throwsArgumentError);
      expect(() => _import(_usda, _usdaFood(), datasetVersion: '  '),
          throwsArgumentError);
      expect(() => _import(_usda, _usdaFood(), licence: ''), throwsArgumentError);
      expect(() => _import(_usda, _usdaFood(), attribution: '\t'),
          throwsArgumentError);
      expect(
          () => SourcePackImporter.importJson(
                source: _usda,
                jsonText: 'not json',
                datasetVersion: '',
                licence: _licence,
                attribution: _attribution,
              ),
          throwsArgumentError);
    });

    test('trims declarations without turning them into a review', () {
      final result = _import(
        _usda,
        _usdaFood(),
        datasetVersion: ' 2026-11-08 ',
        licence: ' licence-declaration ',
        attribution: ' attribution only ',
      );

      expect(result.pack.version, '2026-11-08');
      expect(result.pack.licence, 'licence-declaration');
      expect(result.pack.attribution, 'attribution only');
      expect(result.records.single.food.source.datasetVersion, '2026-11-08');
      expect(result.records.single.food.source.licence, 'licence-declaration');
    });

    test('keeps returned collections immutable', () {
      final result = _import(_usda, <Object?>[
        _usdaFood(fdcId: 1),
        _usdaFood(fdcId: 2),
      ]);

      expect(() => result.records.clear(), throwsUnsupportedError);
      expect(() => result.pack.foods.clear(), throwsUnsupportedError);
    });
  });
}

SourcePackImport _import(
  String source,
  Object? document, {
  String datasetVersion = _version,
  String licence = _licence,
  String attribution = _attribution,
}) =>
    SourcePackImporter.importJson(
      source: source,
      jsonText: jsonEncode(document),
      datasetVersion: datasetVersion,
      licence: licence,
      attribution: attribution,
    );

Map<String, Object?> _usdaFood({
  int fdcId = 1,
  String name = 'Test food',
  List<Object?>? nutrients,
}) =>
    <String, Object?>{
      'fdcId': fdcId,
      'description': name,
      'dataType': 'Foundation',
      'foodNutrients': nutrients ??
          <Object?>[
            _nutrient(
                id: 1003,
                number: '203',
                name: 'Protein',
                unit: 'G',
                value: 2.5),
          ],
    };

Map<String, Object?> _nutrient({
  required int id,
  required String number,
  required String name,
  required String unit,
  required num value,
}) =>
    <String, Object?>{
      'nutrientId': id,
      'nutrientNumber': number,
      'nutrientName': name,
      'unitName': unit,
      'value': value,
    };

Map<String, Object?> _offProduct({
  String code = '3274080005003',
  String name = 'Test product',
  Map<String, Object?>? nutriments,
}) =>
    <String, Object?>{
      'code': code,
      'product_name': name,
      'nutriments': nutriments ??
          <String, Object?>{'proteins_100g': 3.2, 'proteins_unit': 'g'},
    };

/// Synthetic CIQUAL fixtures shaped like the official ANSES XML export. They
/// are not a dataset, copy no published values, and carry no licence or dataset
/// approval.
///
/// Format documentation and downloads:
/// * CIQUAL 2025 dataset, DOI 10.57745/RDMHWY: https://doi.org/10.57745/RDMHWY
/// * CIQUAL 2020 documents, DOI 10.5281/zenodo.4770600
/// * ANSES portal: https://ciqual.anses.fr/
String _ciqualTable(Iterable<String> records) =>
    '<?xml version="1.0" encoding="utf-8" ?>\n'
    '<TABLE>\n${records.join('\n')}\n</TABLE>';

String _ciqualAlim({
  String code = '1234',
  String frenchName = 'Pomme de terre, bouillie/cuite à l&apos;eau',
  String englishName = 'Potato, boiled/cooked in water',
  String? scientificName = 'Solanum tuberosum',
  String groupCode = '02',
  String subgroupCode = '0201',
  String subSubgroupCode = '020101',
  String? jonesFactor = '6.25',
}) =>
    '''
   <ALIM>
      <alim_code> $code </alim_code>
      <alim_nom_fr> $frenchName </alim_nom_fr>
      <alim_nom_eng> $englishName </alim_nom_eng>
      ${scientificName == null ? '<alim_nom_sci missing=" " />' : '<alim_nom_sci> $scientificName </alim_nom_sci>'}
      <alim_grp_code> $groupCode </alim_grp_code>
      <alim_ssgrp_code> $subgroupCode </alim_ssgrp_code>
      <alim_ssssgrp_code> $subSubgroupCode </alim_ssssgrp_code>
      ${jonesFactor == null ? '' : '<facteur_Jones> $jonesFactor </facteur_Jones>'}
   </ALIM>''';

String _ciqualConst(String code, String nameFr, String nameEn) =>
    '''
   <CONST>
      <const_code> $code </const_code>
      <const_nom_fr> $nameFr </const_nom_fr>
      <const_nom_eng> $nameEn </const_nom_eng>
   </CONST>''';

String _ciqualConst327() =>
    _ciqualConst('327', 'Energie, Règlement UE N° 1169/2011 (kJ/100 g)',
        'Energy, Regulation EU No 1169/2011 (kJ/100g)');

String _ciqualCompo(
  String foodCode,
  String constituentCode,
  String teneur, {
  String? confidence = 'A',
  String? source = '10',
  String? min,
  String? max,
}) =>
    '''
   <COMPO>
      <alim_code> $foodCode </alim_code>
      <const_code> $constituentCode </const_code>
      <teneur> $teneur </teneur>
      ${min == null ? '<min missing=" " />' : '<min> $min </min>'}
      ${max == null ? '<max missing=" " />' : '<max> $max </max>'}
      ${confidence == null ? '<code_confiance missing=" " />' : '<code_confiance> $confidence </code_confiance>'}
      ${source == null ? '<source_code missing="." />' : '<source_code> $source </source_code>'}
   </COMPO>''';

String _ciqualFoodsXml() => _ciqualTable(<String>[
      _ciqualAlim(),
      _ciqualAlim(
        code: '5678',
        frenchName: 'Yaourt, nature',
        englishName: 'Yoghurt, plain',
        scientificName: null,
        jonesFactor: null,
      ),
      _ciqualAlim(
        code: '9012',
        frenchName: 'Eau',
        englishName: 'Water',
        scientificName: null,
        jonesFactor: null,
      ),
    ]);

String _ciqualConstituentsXml() => _ciqualTable(<String>[
      _ciqualConst327(),
      _ciqualConst('328', 'Energie, Règlement UE N° 1169/2011 (kcal/100 g)',
          'Energy, Regulation EU No 1169/2011 (kcal/100g)'),
      _ciqualConst('25000', 'Protéines, N x facteur de Jones (g/100 g)',
          'Protein (g/100g)'),
      _ciqualConst('31000', 'Glucides (g/100 g)', 'Carbohydrate (g/100g)'),
      _ciqualConst('40000', 'Lipides (g/100 g)', 'Fat (g/100g)'),
      _ciqualConst('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
      _ciqualConst(
          '10004', 'Sel chlorure de sodium (g/100 g)', 'Salt (g/100g)'),
    ]);

String _ciqualCompositionsXml() => _ciqualTable(<String>[
      _ciqualCompo('1234', '327', '1490'),
      _ciqualCompo('1234', '328', '356'),
      _ciqualCompo('1234', '25000', '12,3456789'),
      _ciqualCompo('1234', '31000', '72,5'),
      _ciqualCompo('1234', '40000', '1,2'),
      _ciqualCompo('1234', '10110', '4,62', min: '3,8', max: '5,1'),
      _ciqualCompo('1234', '10004', '0,5'),
      _ciqualCompo('5678', '10110', 'traces'),
      _ciqualCompo('5678', '40000', '5', confidence: 'Z'),
      _ciqualCompo('5678', '31000', '4,2,3'),
      _ciqualCompo('5678', '10004', '0,1'),
      _ciqualCompo('5678', '327', '&lt; 10'),
    ]);

String _ciqualGroupsXml() => _ciqualTable(<String>[
      '''
   <ALIM_GRP>
      <alim_grp_code> 02 </alim_grp_code>
      <alim_grp_nom_fr> fruits, légumes, légumineuses et oléagineux </alim_grp_nom_fr>
      <alim_grp_nom_eng> fruits, vegetables, legumes and nuts </alim_grp_nom_eng>
      <alim_ssgrp_code> 0201 </alim_ssgrp_code>
      <alim_ssgrp_nom_fr> pommes de terre et autres tubercules </alim_ssgrp_nom_fr>
      <alim_ssgrp_nom_eng> potatoes and other tubers </alim_ssgrp_nom_eng>
      <alim_ssssgrp_code> 020101 </alim_ssssgrp_code>
      <alim_ssssgrp_nom_fr> pommes de terre </alim_ssssgrp_nom_fr>
      <alim_ssssgrp_nom_eng> potatoes </alim_ssssgrp_nom_eng>
   </ALIM_GRP>''',
    ]);

String _ciqualSourcesXml() => _ciqualTable(<String>[
      '''
   <SOURCES>
      <source_code> 10 </source_code>
      <ref_citation> Synthetic fixture citation; not a source approval </ref_citation>
   </SOURCES>''',
    ]);

SourcePackImport _importCiqual({
  String? foods,
  String? constituents,
  String? compositions,
  String? groups,
  String? sources,
  String datasetVersion = _version,
  String licence = _licence,
  String attribution = _attribution,
}) =>
    _importCiqualRaw(
      foodsBytes: utf8.encode(foods ?? _ciqualFoodsXml()),
      constituentsBytes: utf8.encode(constituents ?? _ciqualConstituentsXml()),
      compositionsBytes: utf8.encode(compositions ?? _ciqualCompositionsXml()),
      foodGroupsBytes: groups == null ? null : utf8.encode(groups),
      sourcesBytes: sources == null ? null : utf8.encode(sources),
      datasetVersion: datasetVersion,
      licence: licence,
      attribution: attribution,
    );

SourcePackImport _importCiqualRaw({
  required List<int> foodsBytes,
  required List<int> constituentsBytes,
  required List<int> compositionsBytes,
  List<int>? foodGroupsBytes,
  List<int>? sourcesBytes,
  String datasetVersion = _version,
  String licence = _licence,
  String attribution = _attribution,
}) =>
    SourcePackImporter.importCiqual(
      datasetVersion: datasetVersion,
      licence: licence,
      attribution: attribution,
      foodsBytes: foodsBytes,
      constituentsBytes: constituentsBytes,
      compositionsBytes: compositionsBytes,
      foodGroupsBytes: foodGroupsBytes,
      sourcesBytes: sourcesBytes,
    );

const Map<int, int> _windows1252Encode = <int, int>{
  0x20AC: 0x80,
  0x2019: 0x92,
  0x0153: 0x9C,
};

List<int> _windows1252Bytes(String text) {
  final bytes = <int>[];
  for (final codeUnit in text.codeUnits) {
    final mapped = _windows1252Encode[codeUnit];
    if (mapped != null) {
      bytes.add(mapped);
    } else if (codeUnit <= 0x7F ||
        (codeUnit >= 0xA0 && codeUnit <= 0xFF)) {
      bytes.add(codeUnit);
    } else {
      throw ArgumentError(
          'Cannot encode U+${codeUnit.toRadixString(16)} as windows-1252');
    }
  }
  return bytes;
}

Matcher _formatContains(String text) => throwsA(
    isA<FormatException>().having((error) => error.message, 'message', contains(text)));
