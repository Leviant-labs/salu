import 'dart:collection';
import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart'
    show CataloguePack, DriftFoodRepository;
import 'package:salu_data/src/import/ciqual_import.dart';
import 'package:test/test.dart';

/// Synthetic XML shaped like the official ANSES CIQUAL export. These strings
/// are not a dataset, do not copy published values, and carry no licence or
/// dataset approval.
///
/// Authoritative format documentation and downloads:
/// * CIQUAL 2025 dataset and XML documentation, DOI 10.57745/RDMHWY:
///   https://doi.org/10.57745/RDMHWY
/// * CIQUAL 2020 XML dataset and documentation:
///   https://doi.org/10.5281/zenodo.4770600
///   https://www.data.gouv.fr/datasets/table-de-composition-nutritionnelle-des-aliments-ciqual-2020
/// * ANSES portal: https://ciqual.anses.fr/

const String _version = 'fixture-ciqual-version';
const String _licence = 'fixture-licence-not-a-review';
const String _citation = 'Synthetic fixture citation; not a source approval';

void main() {
  group('CIQUAL XML adapter', () {
    test('normalizes the documented 2025 record without inventing values', () {
      final adapter = CiqualFoodAdapter.fromXml(
        datasetVersion: _version,
        licence: _licence,
        foodsXml: _table(<String>[_alim()]),
        constituentsXml: _table(<String>[
          ..._baseConstituents(),
          _const('10004', 'Sel chlorure de sodium (g/100 g)',
              'Salt (g/100g)'),
          _const('34000', 'Polyols totaux (g/100 g)', 'Polyols (g/100g)'),
        ]),
        compositionsXml: _table(<String>[
          _compo('1234', '327', '1490'),
          _compo('1234', '328', '356'),
          _compo('1234', '332', '1510'),
          _compo('1234', '333', '361'),
          _compo('1234', '25000', '12,3456789'),
          _compo('1234', '25003', '12,4'),
          _compo('1234', '31000', '72,5'),
          _compo('1234', '32000', '9,8'),
          _compo('1234', '34100', '2,1'),
          _compo('1234', '40000', '1,2'),
          _compo('1234', '40302', '0,3'),
          _compo('1234', '10110', '4,62', min: '3,8', max: '5,1'),
          _compo('1234', '10200', '12'),
          _compo('1234', '10260', 'traces'),
          _compo('1234', '10530', '&lt; 0,0001'),
          _compo('1234', '52100', '-', confidence: null, source: null),
          _compo('1234', '55100', '0,0'),
          _compo('1234', '10004', '0,5'),
          _compo('1234', '34000', '-'),
        ]),
        foodGroupsXml: _table(<String>[_group()]),
        sourcesXml: _table(<String>[_source('10', _citation)]),
      );

      final result = adapter.adapt('1234');
      final food = result.food;

      expect(food.id, 'ciqual:1234');
      expect(food.name, "Pomme de terre, bouillie/cuite à l'eau");
      expect(food.source.dataset, CiqualFoodAdapter.dataset);
      expect(food.source.datasetId, '1234');
      expect(food.source.datasetVersion, _version);
      expect(food.source.licence, _licence);
      expect(food.basisUnit, FoodUnit.g);
      expect(food.basisValue, '100');
      expect(food.preparation, Preparation.cooked);
      expect(food.aliases, contains('Potato, boiled/cooked in water'));
      expect(food.aliases, contains('Solanum tuberosum'));
      expect(food.allergens, isNull);
      expect(food.dietaryTags, isEmpty);
      expect(food.regions, isEmpty);
      expect(food.portions.portionGrams, isNull);

      expect(food.per100g[NutrientKey.energyKj].numericValue, 1490);
      expect(food.per100g[NutrientKey.energyKcal].numericValue, 356);
      expect(food.per100g[NutrientKey.proteinG].numericValue, 12.3456789);
      expect(food.per100g[NutrientKey.carbohydrateG].numericValue, 72.5);
      expect(food.per100g[NutrientKey.sugarsG].numericValue, 9.8);
      expect(food.per100g[NutrientKey.fiberG].numericValue, 2.1);
      expect(food.per100g[NutrientKey.fatG].numericValue, 1.2);
      expect(food.per100g[NutrientKey.saturatedFatG].numericValue, 0.3);
      expect(food.per100g[NutrientKey.sodiumMg].numericValue, 4.62);
      expect(food.per100g[NutrientKey.calciumMg].numericValue, 12);
      expect(food.per100g[NutrientKey.ironMg], NutrientValue.trace);
      expect(food.per100g[NutrientKey.iodineUg], NutrientValue.unknown);
      expect(food.per100g[NutrientKey.vitaminDUg], NutrientValue.unknown);
      expect(food.per100g[NutrientKey.vitaminCMg].numericValue, 0);

      expect(result.issues, isEmpty);
      expect(result.unmappedNutrients, <String>['10004 Salt (g/100g)']);
      expect(result.sourceDetails['alim_nom_eng'],
          'Potato, boiled/cooked in water');
      expect(result.sourceDetails['alim_nom_sci'], 'Solanum tuberosum');
      expect(result.sourceDetails['alim_grp_code'], '02');
      expect(result.sourceDetails['foodGroupNameFr'],
          'fruits, légumes, légumineuses et oléagineux');
      expect(result.sourceDetails['foodSubgroupNameFr'],
          'pommes de terre et autres tubercules');
      expect(result.sourceDetails['facteur_Jones'], '6.25');
      expect(result.sourceDetails['sourceCodes'], <String>['10']);

      final sodium = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.sodiumMg.wire);
      expect(sodium.amount, Exact.parse('4.62'));
      expect(sodium.origin, contains('ciqual:compo/10110'));
      expect(sodium.origin, contains('source=10'));
      expect(sodium.origin, contains('confidence=A'));
      expect(sodium.origin, contains('teneur=4,62'));
      expect(sodium.nutrient.definition, NutrientKey.sodiumMg.wire);
      // min/max are analysed-sample statistics, not a documented interval.
      expect(sodium.suppliedInterval, isNull);

      final iron = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.ironMg.wire);
      expect(iron.qualifier, ObservationQualifier.trace);
      expect(iron.amount, isNull);
      expect(iron.origin, contains('teneur=traces'));

      final iodine = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.iodineUg.wire);
      expect(iodine.qualifier, ObservationQualifier.unknown);
      expect(iodine.amount, isNull);
      expect(iodine.origin, contains('teneur=< 0,0001'));
      final iodineInterval = iodine.suppliedInterval!;
      expect(iodineInterval.lower, isNull);
      expect(iodineInterval.upper, Exact.parse('0.0001'));
      expect(iodineInterval.lowerInclusive, isFalse);
      expect(iodineInterval.upperInclusive, isFalse);
      expect(iodineInterval.scope, 'ciqual:compo/10530/teneur');
      expect(iodineInterval.method, contains('CIQUAL maximum'));
      expect(iodineInterval.method, contains('not a detection limit'));
      // The source documents no evidence date for a composition cell.
      expect(iodine.evidenceDate, isNull);
      expect(result.sourceDetails['upperBounds'],
          <String, String>{'10530': '< 0,0001'});

      final vitaminD = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.vitaminDUg.wire);
      expect(vitaminD.qualifier, ObservationQualifier.unknown);
      expect(vitaminD.amount, isNull);
      expect(vitaminD.origin, contains('teneur=-'));

      final vitaminC = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.vitaminCMg.wire);
      expect(vitaminC.qualifier, ObservationQualifier.reportedZero);
      expect(vitaminC.amount, Exact.zero);

      final crudeProtein = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.proteinG.wire &&
          observation.nutrient.definition ==
              CiqualFoodAdapter.crudeProteinDefinition);
      expect(crudeProtein.amount, Exact.parse('12.4'));

      final jonesEnergy = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.energyKcal.wire &&
          observation.nutrient.definition ==
              CiqualFoodAdapter.jonesEnergyDefinition);
      expect(jonesEnergy.amount, Exact.parse('361'));

      expect(food.observations, hasLength(17));
      expect(adapter.constituents['10110']!.nameEn, 'Sodium (mg/100g)');
      expect(adapter.foodGroupFor('1234')!.subgroupNameFr,
          'pommes de terre et autres tubercules');
      expect(adapter.compositionFor('1234', '10110')!.rawValue, '4,62');
      expect(adapter.compositionFor('1234', '10110')!.confidence, 'A');
      expect(adapter.compositionFor('1234', '10110')!.sourceCode, '10');
      expect(adapter.compositionFor('1234', '10110')!.observedMin,
          Exact.parse('3.8'));
      expect(adapter.compositionFor('1234', '10110')!.observedMax,
          Exact.parse('5.1'));
      expect(adapter.sources['10']!.citations, <String>[_citation]);

      DriftFoodRepository.validateFoods(<Food>[food]);
    });

    test('keeps declared and Jones energy/protein definitions separate', () {
      final adapter = _adapter(
        foods: _table(<String>[
          _alim(
              code: '2000',
              frenchName: 'Pomme de terre, crue',
              englishName: 'Potato, raw'),
        ]),
        constituents: _table(_baseConstituents()),
        compositions: _table(<String>[
          _compo('2000', '327', '1490'),
          _compo('2000', '328', '356'),
          _compo('2000', '332', '1510'),
          _compo('2000', '333', '361'),
          _compo('2000', '25000', '12,3456789'),
          _compo('2000', '25003', '12,4'),
        ]),
      );

      final result = adapter.adapt('2000');
      final food = result.food;

      expect(food.preparation, Preparation.raw);
      expect(food.per100g[NutrientKey.energyKj].numericValue, 1490);
      expect(food.per100g[NutrientKey.energyKcal].numericValue, 356);
      expect(food.per100g[NutrientKey.proteinG].numericValue, 12.3456789);

      final energyKj = food.observations
          .where((observation) =>
              observation.nutrient.id == NutrientKey.energyKj.wire)
          .toList();
      expect(energyKj, hasLength(2));
      expect(
          energyKj
              .firstWhere((observation) =>
                  observation.nutrient.definition ==
                  NutrientDefinitions.declaredEnergy)
              .amount,
          Exact.parse('1490'));
      expect(
          energyKj
              .firstWhere((observation) =>
                  observation.nutrient.definition ==
                  CiqualFoodAdapter.jonesEnergyDefinition)
              .amount,
          Exact.parse('1510'));

      final protein = food.observations
          .where((observation) =>
              observation.nutrient.id == NutrientKey.proteinG.wire)
          .toList();
      expect(protein, hasLength(2));
      expect(
          protein
              .firstWhere((observation) =>
                  observation.nutrient.definition == NutrientKey.proteinG.wire)
              .amount,
          Exact.parse('12.3456789'));
      expect(
          protein
              .firstWhere((observation) =>
                  observation.nutrient.definition ==
                  CiqualFoodAdapter.crudeProteinDefinition)
              .amount,
          Exact.parse('12.4'));

      DriftFoodRepository.validateFoods(<Food>[food]);
    });

    test('retains unknown, trace, bounded and reported-zero states', () {
      final adapter = _adapter(
        foods: _table(<String>[_alim(code: '3000')]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
          _const('10260', 'Fer (mg/100 g)', 'Iron (mg/100g)'),
          _const('55100', 'Vitamine C (mg/100 g)', 'Vitamin C (mg/100g)'),
          _const('52100', 'Vitamine D (µg/100 g)', 'Vitamin D (µg/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('3000', '10110', '-'),
          _compo('3000', '10260', 'traces'),
          _compo('3000', '55100', '0'),
          _compo('3000', '52100', '&lt; 0,01'),
        ]),
      );

      final result = adapter.adapt('3000');
      final food = result.food;
      expect(result.issues, isEmpty);
      expect(food.per100g[NutrientKey.sodiumMg], NutrientValue.unknown);
      expect(food.per100g[NutrientKey.ironMg], NutrientValue.trace);
      expect(food.per100g[NutrientKey.vitaminCMg].numericValue, 0);
      expect(food.per100g[NutrientKey.vitaminDUg], NutrientValue.unknown);

      final sodium = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.sodiumMg.wire);
      expect(sodium.qualifier, ObservationQualifier.unknown);
      expect(sodium.amount, isNull);

      final vitaminD = food.observations.firstWhere((observation) =>
          observation.nutrient.id == NutrientKey.vitaminDUg.wire);
      expect(vitaminD.qualifier, ObservationQualifier.unknown);
      expect(vitaminD.amount, isNull);
      expect(vitaminD.origin, contains('teneur=< 0,01'));
      final vitaminDInterval = vitaminD.suppliedInterval!;
      expect(vitaminDInterval.lower, isNull);
      expect(vitaminDInterval.upper, Exact.parse('0.01'));
      expect(vitaminDInterval.upperInclusive, isFalse);
      expect(vitaminDInterval.scope, 'ciqual:compo/52100/teneur');
      expect(result.sourceDetails['upperBounds'],
          <String, String>{'52100': '< 0,01'});

      final bounded = adapter.compositionFor('3000', '52100')!;
      expect(bounded.kind, CiqualValueKind.upperBound);
      expect(bounded.rawValue, '< 0,01');
      expect(bounded.upperBound, Exact.parse('0.01'));
      expect(bounded.amount, isNull);
    });

    test('treats an empty CIQUAL 2020 teneur as unknown, not zero', () {
      final adapter = _adapter(
        foods: _table(<String>[_alim(code: '3001')]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[_compo('3001', '10110', '')]),
      );

      final result = adapter.adapt('3001');
      expect(result.food.observations.single.qualifier,
          ObservationQualifier.unknown);
      expect(result.food.observations.single.amount, isNull);
      expect(result.food.per100g[NutrientKey.sodiumMg], NutrientValue.unknown);
      expect(result.issues.map((issue) => issue.code),
          contains('no-usable-nutrients'));
    });

    test('parses scientific notation in teneur and observed bounds', () {
      final adapter = _adapter(
        foods: _table(<String>[_alim(code: '3003')]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('3003', '10110', '1E-3', min: '1E-6', max: '2E-3'),
        ]),
      );

      final result = adapter.adapt('3003');
      final composition = adapter.compositionFor('3003', '10110')!;
      expect(composition.amount, Exact.parse('0.001'));
      expect(composition.observedMin, Exact.parse('0.000001'));
      expect(composition.observedMax, Exact.parse('0.002'));
      expect(result.food.per100g[NutrientKey.sodiumMg].numericValue, 0.001);
    });

    test('tolerates raw less-than text in official 2020 records', () {
      final adapter = _adapter(
        foods: _table(<String>[
          _alim(
            code: '9000',
            frenchName: 'Panaché préemballé (<1° alc.)',
            englishName: 'Shandy, prepacked (<1° alcohol)',
          ),
        ]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[_compo('9000', '10110', '1')]),
      );

      final result = adapter.adapt('9000');
      expect(result.food.name, 'Panaché préemballé (<1° alc.)');
      expect(result.food.aliases,
          contains('Shandy, prepacked (<1° alcohol)'));
      expect(result.issues, isEmpty);
    });

    test('tolerates raw ampersands in official 2020 records', () {
      final adapter = _adapter(
        foods: _table(<String>[
          _alim(
            code: '9001',
            frenchName: 'Tendre et léger elle & Vire',
            englishName:
                'Dairy fat, light, spreadable (lettuce & tomato)',
          ),
        ]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[_compo('9001', '10110', '1')]),
      );

      final result = adapter.adapt('9001');
      expect(result.food.name, 'Tendre et léger elle & Vire');
      expect(result.food.aliases,
          contains('Dairy fat, light, spreadable (lettuce & tomato)'));
      expect(result.issues, isEmpty);
    });

    test('preserves an upper bound for an unmapped constituent', () {
      final adapter = _adapter(
        foods: _table(<String>[_alim(code: '3002')]),
        constituents: _table(<String>[
          _const('10340', 'Sélénium (µg/100 g)', 'Selenium (µg/100g)'),
        ]),
        compositions: _table(<String>[_compo('3002', '10340', '&lt; 10')]),
      );

      final result = adapter.adapt('3002');
      expect(result.food.observations, isEmpty);
      expect(result.sourceDetails['upperBounds'],
          <String, String>{'10340': '< 10'});
      expect(result.unmappedNutrients, <String>['10340 Selenium (µg/100g)']);
      expect(result.issues.map((issue) => issue.code),
          contains('no-mapped-nutrients'));
    });

    test('reports no usable mapped value without turning it into zero', () {
      final adapter = _adapter(
        foods: _table(<String>[_alim(code: '4000')]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[_compo('4000', '10110', '-')]),
      );

      final result = adapter.adapt('4000');
      expect(result.food.observations, hasLength(1));
      expect(result.food.observations.single.qualifier,
          ObservationQualifier.unknown);
      expect(result.food.observations.single.amount, isNull);
      expect(result.food.per100g[NutrientKey.sodiumMg], NutrientValue.unknown);
      expect(result.issues.map((issue) => issue.code),
          contains('no-usable-nutrients'));
    });

    test('retains unmapped source values but never invents a nutrient', () {
      final adapter = _adapter(
        foods: _table(<String>[
          _alim(code: '5000'),
          _alim(code: '5001', frenchName: 'Aliment sans composition'),
        ]),
        constituents: _table(<String>[
          _const('10004', 'Sel chlorure de sodium (g/100 g)',
              'Salt (g/100g)'),
          _const('34000', 'Polyols totaux (g/100 g)', 'Polyols (g/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('5000', '10004', '1,2'),
          _compo('5000', '34000', '-'),
        ]),
      );

      final results = adapter.adaptAll();
      expect(results, hasLength(2));
      final first = results.first;
      expect(first.food.id, 'ciqual:5000');
      expect(first.food.observations, isEmpty);
      expect(first.food.per100g.values, isEmpty);
      expect(first.unmappedNutrients, <String>['10004 Salt (g/100g)']);
      expect(first.issues.map((issue) => issue.code),
          contains('no-mapped-nutrients'));

      final second = results.last;
      expect(second.food.id, 'ciqual:5001');
      expect(second.food.observations, isEmpty);
      expect(second.issues.map((issue) => issue.code),
          contains('no-nutrition-data'));
    });

    test('applies only unambiguous food-specific preparation tokens', () {
      final adapter = _adapter(
        foods: _table(<String>[
          _alim(code: '6001', frenchName: 'Pomme de terre, crue'),
          _alim(
              code: '6002',
              frenchName: "Pomme de terre, bouillie/cuite à l'eau"),
          _alim(code: '6003', frenchName: 'Pomme de terre, crue ou cuite'),
          _alim(
              code: '6004',
              frenchName:
                  'Pommes de terre noisette, surgelées, à cuire'),
        ]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('6001', '10110', '1'),
          _compo('6002', '10110', '1'),
          _compo('6003', '10110', '1'),
          _compo('6004', '10110', '1'),
        ]),
      );

      expect(adapter.adapt('6001').food.preparation, Preparation.raw);
      expect(adapter.adapt('6002').food.preparation, Preparation.cooked);

      final ambiguous = adapter.adapt('6003');
      expect(ambiguous.food.preparation, Preparation.unspecified);
      expect(ambiguous.issues.map((issue) => issue.code),
          contains('ambiguous-preparation'));

      final toCook = adapter.adapt('6004');
      expect(toCook.food.preparation, Preparation.unspecified);
      expect(toCook.issues.map((issue) => issue.code),
          isNot(contains('ambiguous-preparation')));
    });

    test('accepts CIQUAL 2020-shaped records and repeated source citations', () {
      final adapter = _adapter(
        foods: _table(<String>[
          _alim(
            code: '7000',
            frenchName: 'Pomme de terre, cuite (aliment moyen)',
            englishName: 'Potato, cooked',
            scientificName: null,
            jonesFactor: null,
          ),
        ]),
        constituents: _table(<String>[
          _const('327', 'Energie, Règlement UE N° 1169/2011 (kJ/100 g)',
              'Energy, Regulation EU No 1169/2011 (kJ/100g)'),
          _const('328', 'Energie, Règlement UE N° 1169/2011 (kcal/100 g)',
              'Energy, Regulation EU No 1169/2011 (kcal/100g)'),
          _const('25000', 'Protéines, N x facteur de Jones (g/100 g)',
              'Protein (g/100g)'),
          _const('31000', 'Glucides (g/100 g)', 'Carbohydrate (g/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('7000', '327', '449'),
          _compo('7000', '328', '106'),
          _compo('7000', '25000', '2,1'),
          _compo('7000', '31000', '23,5'),
        ]),
      );

      final result = adapter.adapt('7000');
      expect(result.food.preparation, Preparation.cooked);
      expect(result.sourceDetails.containsKey('alim_nom_sci'), isFalse);
      expect(result.sourceDetails.containsKey('facteur_Jones'), isFalse);
      expect(adapter.groups, isEmpty);
      expect(adapter.sources, isEmpty);
      DriftFoodRepository.validateFoods(<Food>[result.food]);

      final repeated = _adapter(
        foods: _table(<String>[_alim(code: '7001')]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('7001', '10110', '1', source: '5'),
        ]),
        sources: _table(<String>[
          _source('5', 'Synthetic citation A'),
          _source('5', 'Synthetic citation B'),
        ]),
      );
      expect(repeated.sources['5']!.citations, <String>[
        'Synthetic citation A',
        'Synthetic citation B',
      ]);

      final repeatedGroups = _adapter(
        foods: _table(<String>[_alim(code: '7002')]),
        constituents: _table(<String>[
          _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
        ]),
        compositions: _table(<String>[
          _compo('7002', '10110', '1'),
        ]),
        groups: _table(<String>[
          _group(subgroupNameFr: 'first wording'),
          _group(subgroupNameFr: 'second wording'),
        ]),
      );
      expect(repeatedGroups.groups, hasLength(2));
      expect(repeatedGroups.foodGroupFor('7002')!.subgroupNameFr,
          'first wording');
    });

    test('decodes declared windows-1252 bytes without latin1 corruption', () {
      const name = 'Pomme de terre, cuite € ’ œ';
      final foods = _table(<String>[
        _alim(code: '8000', frenchName: name, englishName: 'Potato, cooked'),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');
      final constituents = _table(<String>[
        _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');
      final compositions = _table(<String>[
        _compo('8000', '10110', '1'),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');

      final adapter = CiqualFoodAdapter.fromBytes(
        datasetVersion: _version,
        licence: _licence,
        foods: _windows1252Bytes(foods),
        constituents: _windows1252Bytes(constituents),
        compositions: _windows1252Bytes(compositions),
      );

      final result = adapter.adapt('8000');
      expect(result.food.name, name);
      expect(result.food.name, contains('€'));
      expect(result.food.name, contains('’'));
      expect(result.food.name, contains('œ'));
    });

    test('rejects undefined windows-1252 bytes and unsupported encodings', () {
      final badFoods = _table(<String>[
        _alim(code: '8001', frenchName: 'Bad \uE000 name', englishName: 'Bad'),
      ]).replaceFirst('encoding="utf-8"', 'encoding="windows-1252"');
      final goodConstituents = _table(<String>[
        _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
      ]);
      final goodCompositions = _table(<String>[
        _compo('8001', '10110', '1'),
      ]);

      expect(
          () => CiqualFoodAdapter.fromBytes(
                datasetVersion: _version,
                licence: _licence,
                foods: _windows1252Bytes(badFoods),
                constituents: _windows1252Bytes(goodConstituents),
                compositions: _windows1252Bytes(goodCompositions),
              ),
          throwsA(isA<FormatException>()));

      final unsupported = _table(<String>[
        _alim(code: '8002', frenchName: 'Potato'),
      ]).replaceFirst('encoding="utf-8"', 'encoding="utf-16"');
      expect(
          () => CiqualFoodAdapter.fromBytes(
                datasetVersion: _version,
                licence: _licence,
                foods: utf8.encode(unsupported),
                constituents: utf8.encode(goodConstituents),
                compositions: utf8.encode(goodCompositions),
              ),
          throwsA(isA<FormatException>()));
    });

    test('fromBytes decodes declared UTF-8 bytes with a BOM', () {
      final foods = _table(<String>[
        _alim(code: '8003', frenchName: 'Pomme de terre, cuite €'),
      ]);
      final constituents = _table(<String>[
        _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
      ]);
      final compositions = _table(<String>[
        _compo('8003', '10110', '1'),
      ]);
      final adapter = CiqualFoodAdapter.fromBytes(
        datasetVersion: _version,
        licence: _licence,
        foods: <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(foods)],
        constituents: utf8.encode(constituents),
        compositions: utf8.encode(compositions),
      );
      expect(adapter.adapt('8003').food.name, 'Pomme de terre, cuite €');
    });

    test('rejects DTDs, unknown entities and unbounded nesting', () {
      expect(
          () => _adapter(
                foods:
                    '<!DOCTYPE TABLE [<!ENTITY x "y">]><TABLE></TABLE>',
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                foods: _table(<String>[
                  _alim(frenchName: 'Bad &external; entity'),
                ]),
              ),
          throwsA(isA<FormatException>()));

      final open = List<String>.filled(40, '<X>').join();
      final close = List<String>.filled(40, '</X>').join();
      final nested = '<TABLE>$open$close</TABLE>';
      expect(() => _adapter(foods: nested),
          throwsA(isA<FormatException>()));
    });

    test('rejects oversized byte documents before decoding', () {
      final huge = _HugeBytes(CiqualFoodAdapter.maxDocumentBytes + 1);
      expect(
          () => CiqualFoodAdapter.fromBytes(
                datasetVersion: _version,
                licence: _licence,
                foods: huge,
                constituents: utf8.encode(_table(<String>[
                  _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
                ])),
                compositions: utf8.encode(_table(<String>[
                  _compo('8004', '10110', '1'),
                ])),
              ),
          throwsA(isA<FormatException>()));
    });

    test('fails closed on inconsistent documents and definitions', () {
      expect(
          () => _adapter(
                constituents: _table(<String>[
                  _const('10110', 'Sodium (g/100 g)', 'Sodium (g/100g)'),
                ]),
                compositions:
                    _table(<String>[_compo('1234', '10110', '1')]),
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                constituents: _table(<String>[
                  _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
                ]),
                compositions:
                    _table(<String>[_compo('1234', '99999', '1')]),
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                foods: _table(<String>[
                  _alim(code: '1234'),
                  _alim(code: '1234'),
                ]),
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                constituents: _table(<String>[
                  _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
                ]),
                compositions: _table(<String>[
                  _compo('1234', '10110', '1'),
                  _compo('1234', '10110', '2'),
                ]),
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                constituents: _table(<String>[
                  _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
                ]),
                compositions:
                    _table(<String>[_compo('9999', '10110', '1')]),
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                constituents: _table(<String>[
                  _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
                ]),
                compositions: _table(<String>[
                  _compo('1234', '10110', '1', source: '99'),
                ]),
                sources: _table(<String>[_source('10', _citation)]),
              ),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(foods: '<TABLE><ALIM>'),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(foods: '<ROOT></ROOT>'),
          throwsA(isA<FormatException>()));

      expect(
          () => _adapter(
                constituents: _table(<String>[
                  _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
                ]),
                compositions: _table(<String>[
                  '''
<COMPO>
  <alim_code> 1234 </alim_code>
  <const_code> 10110 </const_code>
  <code_confiance> A </code_confiance>
  <source_code> 10 </source_code>
</COMPO>''',
                ]),
              ),
          throwsA(isA<FormatException>()));
    });

    test('retains the bounded cell through a catalogue snapshot round trip',
        () {
      final adapter = _adapter(
        foods: _table(<String>[_alim(code: '3002')]),
        constituents: _table(<String>[
          _const('10530', 'Iode (µg/100 g)', 'Iodine (µg/100g)',
              infoFoods: 'ID'),
        ]),
        compositions: _table(<String>[
          _compo('3002', '10530', '&lt; 2,5'),
        ]),
      );
      final result = adapter.adapt('3002');
      final observation = result.food.observations.single;
      expect(observation.qualifier, ObservationQualifier.unknown);
      expect(observation.amount, isNull);
      expect(observation.suppliedInterval!.upper, Exact.parse('2.5'));
      expect(observation.suppliedInterval!.scope,
          'ciqual:compo/10530/teneur');

      final pack = CataloguePack(
          dataset: CiqualFoodAdapter.dataset,
          version: _version,
          licence: _licence,
          attribution: 'Synthetic fixture attribution; not a review',
          foods: <Food>[result.food]);
      final restored = CataloguePack.decode(pack.encode()).foods.single;
      final restoredObservation = restored.observations.single;
      final interval = restoredObservation.suppliedInterval!;
      expect(restoredObservation.qualifier, ObservationQualifier.unknown);
      expect(restoredObservation.amount, isNull);
      expect(interval.lower, isNull);
      expect(interval.upper, Exact.parse('2.5'));
      expect(interval.lowerInclusive, isFalse);
      expect(interval.upperInclusive, isFalse);
      expect(interval.scope, 'ciqual:compo/10530/teneur');
      expect(interval.method, contains('CIQUAL maximum'));
      expect(restored.per100g[NutrientKey.iodineUg], NutrientValue.unknown);
      expect(restored.source.datasetVersion, _version);
      DriftFoodRepository.validateFoods(<Food>[restored]);
    });
  });
}

CiqualFoodAdapter _adapter({
  String? foods,
  String? constituents,
  String? compositions,
  String? groups,
  String? sources,
}) =>
    CiqualFoodAdapter.fromXml(
      datasetVersion: _version,
      licence: _licence,
      foodsXml: foods ?? _table(<String>[_alim()]),
      constituentsXml: constituents ??
          _table(<String>[
            _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)'),
          ]),
      compositionsXml:
          compositions ?? _table(<String>[_compo('1234', '10110', '1')]),
      foodGroupsXml: groups,
      sourcesXml: sources,
    );

String _table(Iterable<String> records) =>
    '<?xml version="1.0" encoding="utf-8" ?>\n'
    '<TABLE>\n${records.join('\n')}\n</TABLE>';

String _alim({
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

String _const(String code, String nameFr, String nameEn, {String? infoFoods}) =>
    '''
   <CONST>
      <const_code> $code </const_code>
      <const_nom_fr> $nameFr </const_nom_fr>
      <const_nom_eng> $nameEn </const_nom_eng>
      ${infoFoods == null ? '' : '<code_INFOODS> $infoFoods </code_INFOODS>'}
   </CONST>''';

String _compo(
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

String _group({
  String groupCode = '02',
  String groupNameFr = 'fruits, légumes, légumineuses et oléagineux',
  String groupNameEn = 'fruits, vegetables, legumes and nuts',
  String subgroupCode = '0201',
  String subgroupNameFr = 'pommes de terre et autres tubercules',
  String subgroupNameEn = 'potatoes and other tubers',
  String subSubgroupCode = '020101',
  String subSubgroupNameFr = 'pommes de terre',
  String subSubgroupNameEn = 'potatoes',
}) =>
    '''
   <ALIM_GRP>
      <alim_grp_code> $groupCode </alim_grp_code>
      <alim_grp_nom_fr> $groupNameFr </alim_grp_nom_fr>
      <alim_grp_nom_eng> $groupNameEn </alim_grp_nom_eng>
      <alim_ssgrp_code> $subgroupCode </alim_ssgrp_code>
      <alim_ssgrp_nom_fr> $subgroupNameFr </alim_ssgrp_nom_fr>
      <alim_ssgrp_nom_eng> $subgroupNameEn </alim_ssgrp_nom_eng>
      <alim_ssssgrp_code> $subSubgroupCode </alim_ssssgrp_code>
      <alim_ssssgrp_nom_fr> $subSubgroupNameFr </alim_ssssgrp_nom_fr>
      <alim_ssssgrp_nom_eng> $subSubgroupNameEn </alim_ssssgrp_nom_eng>
   </ALIM_GRP>''';

String _source(String code, String citation) =>
    '''
   <SOURCES>
      <source_code> $code </source_code>
      <ref_citation> $citation </ref_citation>
   </SOURCES>''';

List<String> _baseConstituents() => <String>[
      _const('327', 'Energie, Règlement UE N° 1169/2011 (kJ/100 g)',
          'Energy, Regulation EU No 1169/2011 (kJ/100g)',
          infoFoods: 'ENERC'),
      _const('328', 'Energie, Règlement UE N° 1169/2011 (kcal/100 g)',
          'Energy, Regulation EU No 1169/2011 (kcal/100g)',
          infoFoods: 'ENERC'),
      _const(
          '332',
          'Energie, N x facteur Jones, avec fibres (kJ/100 g)',
          'Energy, N x Jones&apos; factor, with fibres (kJ/100g)',
          infoFoods: 'ENERC'),
      _const(
          '333',
          'Energie, N x facteur Jones, avec fibres (kcal/100 g)',
          'Energy, N x Jones&apos; factor, with fibres (kcal/100g)',
          infoFoods: 'ENERC'),
      _const('25000', 'Protéines, N x facteur de Jones (g/100 g)',
          'Protein (g/100g)',
          infoFoods: 'PROCNT'),
      _const('25003', 'Protéines, N x 6.25 (g/100 g)',
          'Protein, crude, N x 6.25 (g/100g)',
          infoFoods: 'PROCNT'),
      _const('31000', 'Glucides (g/100 g)', 'Carbohydrate (g/100g)',
          infoFoods: 'CHOAVL'),
      _const('32000', 'Sucres (g/100 g)', 'Sugars (g/100g)', infoFoods: 'SUGAR'),
      _const('34100', 'Fibres alimentaires (g/100 g)', 'Fibres (g/100g)',
          infoFoods: 'FIB-'),
      _const('40000', 'Lipides (g/100 g)', 'Fat (g/100g)', infoFoods: 'FAT'),
      _const('40302', 'AG saturés (g/100 g)', 'FA saturated (g/100g)',
          infoFoods: 'FASAT'),
      _const('10110', 'Sodium (mg/100 g)', 'Sodium (mg/100g)', infoFoods: 'NA'),
      _const('10200', 'Calcium (mg/100 g)', 'Calcium (mg/100g)',
          infoFoods: 'CA'),
      _const('10260', 'Fer (mg/100 g)', 'Iron (mg/100g)', infoFoods: 'FE'),
      _const('10530', 'Iode (µg/100 g)', 'Iodine (µg/100g)', infoFoods: 'ID'),
      _const('52100', 'Vitamine D (µg/100 g)', 'Vitamin D (µg/100g)',
          infoFoods: 'VITD-'),
      _const('55100', 'Vitamine C (mg/100 g)', 'Vitamin C (mg/100g)',
          infoFoods: 'VITC'),
    ];

const Map<int, int> _windows1252Encode = <int, int>{
  0x20AC: 0x80,
  0x2019: 0x92,
  0x0153: 0x9C,
};

List<int> _windows1252Bytes(String text) {
  final bytes = <int>[];
  for (final codeUnit in text.codeUnits) {
    if (codeUnit == 0xE000) {
      bytes.add(0x81);
      continue;
    }
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

final class _HugeBytes extends ListBase<int> {
  _HugeBytes(this.length);

  @override
  int length;

  @override
  int operator [](int index) => 0;

  @override
  void operator []=(int index, int value) {}
}
