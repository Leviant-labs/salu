import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart'
    show CataloguePack, DriftFoodRepository, ImportedFoodBuilder;
import 'package:salu_data/src/import/open_food_facts_import.dart';
import 'package:salu_data/src/import/usda_fdc_import.dart';
import 'package:test/test.dart';

/// Source values below are excerpts of real records fetched from the public
/// USDA FoodData Central and Open Food Facts APIs. They are enough to exercise
/// schema handling; they are not a dataset and carry no release approval.
///
/// USDA: https://fdc.nal.usda.gov/api-guide/
/// OFF: https://world.openfoodfacts.org/api/v2/product/3274080005003.json

const _version = 'fixture-source-version';
const _licence = 'fixture-licence-not-a-review';

void main() {
  group('USDA FoodData Central adapter', () {
    test('normalizes a Foundation record per 100 g', () {
      final result = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_cheddarRecord());
      final food = result.food;

      expect(food.id, 'usda-fdc:328637');
      expect(food.name, 'Cheese, cheddar');
      expect(food.source.dataset, UsdaFdcFoodAdapter.dataset);
      expect(food.source.datasetId, '328637');
      expect(food.source.datasetVersion, _version);
      expect(food.source.licence, _licence);
      expect(food.basisUnit, FoodUnit.g);
      expect(food.basisValue, '100');
      expect(food.preparation, Preparation.unspecified);
      expect(food.portions.portionGrams, 17);
      expect(food.regions, ['United States']);
      expect(food.barcodes, isEmpty);

      expect(food.per100g[NutrientKey.energyKcal].numericValue, 408);
      expect(food.per100g[NutrientKey.proteinG].numericValue, 23.3);
      expect(food.per100g[NutrientKey.fatG].numericValue, 34);
      expect(food.per100g[NutrientKey.carbohydrateG], NutrientValue.unknown);
      final carbohydrate = food.observations.firstWhere(
          (observation) =>
              observation.nutrient.id == NutrientKey.carbohydrateG.wire);
      expect(carbohydrate.nutrient.definition,
          NutrientDefinitions.usTotalCarbohydrate);
      expect(food.per100g[NutrientKey.saturatedFatG].numericValue, 19.2);
      expect(food.per100g[NutrientKey.calciumMg].numericValue, 707);
      expect(food.per100g[NutrientKey.ironMg].numericValue, 0.16);
      expect(food.per100g[NutrientKey.sodiumMg].numericValue, 654);
      expect(food.per100g[NutrientKey.energyKj], NutrientValue.unknown);
      expect(food.per100g[NutrientKey.fiberG], NutrientValue.unknown);
      expect(food.per100g[NutrientKey.sugarsG], NutrientValue.unknown);
      expect(food.observations, hasLength(8));
      expect(result.issues, isEmpty);
      expect(result.unmappedNutrients, isEmpty);
      expect(result.sourceDetails['dataType'], 'Foundation');
      expect(result.sourceDetails['foodPortions'], isA<List<Object?>>());
      DriftFoodRepository.validateFoods([food]);
    });

    test('normalizes a Branded search record and keeps its serving weight', () {
      final result = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_nutellaSearchRecord());
      final food = result.food;

      expect(food.name, 'NUTELLA FERRERO WITH BREADSTICKS');
      expect(food.barcodes, ['009800800124']);
      expect(food.regions, ['United States']);
      expect(food.portions.portionGrams, 52);
      expect(food.aliases, contains('NUTELLA FERRERO'));
      expect(food.aliases, contains('Ferrero U.S.A., Incorporated'));
      expect(food.per100g[NutrientKey.energyKcal].numericValue, 519);
      expect(food.per100g[NutrientKey.fatG].numericValue, 26.9);
      expect(food.per100g[NutrientKey.proteinG].numericValue, 7.69);
      expect(food.per100g[NutrientKey.carbohydrateG], NutrientValue.unknown);
      final carbohydrate = food.observations.firstWhere(
          (observation) =>
              observation.nutrient.id == NutrientKey.carbohydrateG.wire);
      expect(carbohydrate.nutrient.definition,
          NutrientDefinitions.usTotalCarbohydrate);
      expect(food.per100g[NutrientKey.sugarsG].numericValue, 44.2);
      expect(food.per100g[NutrientKey.fiberG].numericValue, 3.8);
      expect(food.per100g[NutrientKey.sodiumMg].numericValue, 250);
      expect(food.per100g[NutrientKey.calciumMg].numericValue, 77);
      expect(food.per100g[NutrientKey.ironMg].numericValue, 2.08);
      expect(result.issues, isEmpty);
      DriftFoodRepository.validateFoods([food]);
    });

    test('scales labelNutrients from the labelled serving to the food basis',
        () {
      final result = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_nutellaLabelOnlyRecord());
      final food = result.food;

      expect(food.observations.first.basis.value, Exact.parse('52'));
      expect(food.per100g[NutrientKey.fatG].numericValue,
          closeTo(26.9230769, 0.0000001));
      expect(food.per100g[NutrientKey.sodiumMg].numericValue, 250);
      expect(food.per100g[NutrientKey.energyKcal].numericValue,
          closeTo(519.230769, 0.000001));
      expect(food.per100g[NutrientKey.carbohydrateG], NutrientValue.unknown);
      final carbohydrate = food.observations.firstWhere(
          (observation) =>
              observation.nutrient.id == NutrientKey.carbohydrateG.wire);
      expect(carbohydrate.nutrient.definition,
          NutrientDefinitions.usTotalCarbohydrate);
      expect(result.unmappedNutrients, contains('transFat'));
      expect(result.unmappedNutrients, contains('cholesterol'));
      expect(result.unmappedNutrients, contains('postassium'));
      DriftFoodRepository.validateFoods([food]);
    });

    test('preserves reported zero, assumed/imputed zero, trace and unknown',
        () {
      final reportedZero = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord(
              value: 0,
              derivationCode: 'A',
              derivationDescription: 'Analytical'));
      expect(reportedZero.food.observations.single.qualifier,
          ObservationQualifier.reportedZero);
      expect(reportedZero.food.per100g[NutrientKey.fiberG],
          isA<NutrientReported>());
      expect(reportedZero.food.per100g[NutrientKey.fiberG].numericValue, 0);

      final assumedZero = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord(
              value: 0,
              derivationCode: 'Z',
              derivationDescription: 'Assumed zero'));
      expect(assumedZero.food.observations.single.qualifier,
          ObservationQualifier.estimated);
      expect(assumedZero.food.per100g[NutrientKey.fiberG],
          isA<NutrientEstimated>());
      expect(assumedZero.food.per100g[NutrientKey.fiberG],
          isNot(isA<NutrientReported>()));
      expect(assumedZero.food.per100g[NutrientKey.fiberG].numericValue, 0);

      final imputed = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord(
              value: 0,
              derivationCode: 'NC',
              derivationDescription: 'Imputed'));
      expect(imputed.food.observations.single.qualifier,
          ObservationQualifier.estimated);
      expect(imputed.food.per100g[NutrientKey.fiberG],
          isA<NutrientEstimated>());
      expect(imputed.food.per100g[NutrientKey.fiberG].numericValue, 0);

      final trace = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord(
              value: 0,
              derivationCode: 'A',
              derivationDescription: 'Trace'));
      expect(trace.food.observations.single.qualifier,
          ObservationQualifier.trace);
      expect(trace.food.per100g[NutrientKey.fiberG], NutrientValue.trace);
      expect(trace.food.per100g[NutrientKey.fiberG].isKnown, isFalse);

      final unknown = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord());
      expect(unknown.food.observations.single.qualifier,
          ObservationQualifier.unknown);
      expect(unknown.food.per100g[NutrientKey.fiberG], NutrientValue.unknown);
    });

    test('rejects unsupported units and invalid barcodes without discarding '
        'the record', () {
      final result = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(<String, Object?>{
        'fdcId': 1,
        'description': 'Test food',
        'dataType': 'Foundation',
        'gtinUpc': '123',
        'foodNutrients': [
          <String, Object?>{
            'nutrientId': 1093,
            'nutrientNumber': '307',
            'nutrientName': 'Sodium, Na',
            'unitName': 'IU',
            'value': 5,
          }
        ],
      });
      final codes = result.issues.map((issue) => issue.code).toList();
      expect(codes, contains('unsupported-unit'));
      expect(codes, contains('invalid-barcode'));
      expect(result.food.barcodes, isEmpty);
      expect(result.food.observations, isEmpty);
      expect(result.food.per100g[NutrientKey.sodiumMg], NutrientValue.unknown);
      expect(result.unmappedNutrients, contains('1093 Sodium, Na'));
      DriftFoodRepository.validateFoods([result.food]);
    });

    test('reads preparation state only from explicit description words', () {
      final raw = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord(
              description: 'Strawberries, raw', value: 1));
      final cooked = UsdaFdcFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_singleNutrientRecord(
              description: 'Broccoli, cooked, boiled, drained, without salt',
              value: 1));
      expect(raw.food.preparation, Preparation.raw);
      expect(cooked.food.preparation, Preparation.cooked);
    });

    test('builds a catalogue pack that survives encode/decode and validation',
        () {
      final adapter = UsdaFdcFoodAdapter(
          datasetVersion: _version, licence: _licence);
      final food = adapter.adapt(_cheddarRecord()).food;
      final pack = CataloguePack(
          dataset: UsdaFdcFoodAdapter.dataset,
          version: _version,
          licence: _licence,
          attribution: 'Test attribution; not a dataset approval',
          foods: [food]);
      final restored = CataloguePack.decode(pack.encode());
      expect(restored.foods.single.id, food.id);
      DriftFoodRepository.validateFoods(restored.foods);
    });
  });

  group('Open Food Facts adapter', () {
    test('converts per-100 g minerals exactly and retains source quantities',
        () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_waterRecord());
      final food = result.food;

      expect(food.id, 'open-food-facts:3274080005003');
      expect(food.source.dataset, OpenFoodFactsFoodAdapter.dataset);
      expect(food.source.datasetId, '3274080005003');
      expect(food.source.datasetVersion, _version);
      expect(food.source.licence, _licence);
      expect(food.name, 'isabelle');
      expect(food.basisUnit, FoodUnit.g);
      expect(food.basisValue, '100');
      expect(food.barcodes, ['3274080005003']);
      expect(food.aliases, containsAll(['Eau De Source', 'Cristaline']));
      expect(food.regions, contains('france'));
      expect(food.allergens, isNull);
      expect(result.sourceDetails['allergens_tags'], <Object?>['en:none']);
      expect(food.dietaryTags,
          containsAll(<String>{'vegan', 'vegetarian', 'palm-oil-free'}));
      expect(food.dietaryTags, isNot(contains('triman')));
      expect(food.per100g[NutrientKey.sodiumMg].exactValue, Exact.parse('6.3'));
      expect(food.per100g[NutrientKey.calciumMg].exactValue,
          Exact.parse('113'));
      expect(food.per100g[NutrientKey.proteinG], NutrientValue.unknown);
      expect(food.per100g[NutrientKey.energyKcal], NutrientValue.unknown);
      expect(result.unmappedNutrients, contains('salt'));
      expect(result.unmappedNutrients, contains('potassium'));
      expect(result.sourceDetails['hasEstimatedNutrients'], true);
      expect(result.issues, isEmpty);
      DriftFoodRepository.validateFoods([food]);
    });

    test('uses the original unit for _100g values, not normalized grams',
        () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_productRecord(<String, Object?>{
        'sodium_100g': 6.3,
        'sodium_unit': 'mg',
      }));
      expect(result.food.per100g[NutrientKey.sodiumMg].exactValue,
          Exact.parse('6.3'));
      expect(result.food.observations.single.origin, contains('sodium_100g'));
      expect(result.issues, isEmpty);
    });

    test('keeps both supplied energy units and source-defined carbohydrate',
        () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_cokeRecord());
      final food = result.food;

      expect(food.per100g[NutrientKey.energyKj].numericValue, 180);
      expect(food.per100g[NutrientKey.energyKcal].numericValue, 42.4);
      expect(food.per100g[NutrientKey.fatG].numericValue, 0);
      expect(food.per100g[NutrientKey.proteinG].numericValue, 0);
      expect(food.per100g[NutrientKey.sodiumMg].numericValue, 0);
      expect(food.per100g[NutrientKey.sugarsG].numericValue, 10.6);
      expect(food.per100g[NutrientKey.carbohydrateG], NutrientValue.unknown);
      final carbohydrate = food.observations
          .firstWhere((o) => o.nutrient.id == NutrientKey.carbohydrateG.wire);
      expect(carbohydrate.nutrient.definition,
          OpenFoodFactsFoodAdapter.sourceDefinedCarbohydrate);
      expect(food.allergens, isNull);
      expect(result.sourceDetails.containsKey('allergens_tags'), isFalse);
      expect(result.unmappedNutrients, contains('salt'));
      expect(result.unmappedNutrients, contains('added-sugars'));
      expect(result.unmappedNutrients, isNot(contains('energy')));
      expect(result.sourceDetails['nutrition_data_per'], '100g');
      expect(result.issues, isEmpty);
      DriftFoodRepository.validateFoods([food]);
    });

    test('maps carbohydrate only when the caller supplies a reviewed '
        'definition', () {
      final adapter = OpenFoodFactsFoodAdapter(
          datasetVersion: _version,
          licence: _licence,
          carbohydrateDefinition:
              NutrientDefinitions.euAvailableCarbohydrate);
      final result = adapter.adapt(_cokeRecord());
      expect(result.food.per100g[NutrientKey.carbohydrateG].numericValue,
          10.6);
      final carbohydrate = result.food.observations
          .firstWhere((o) => o.nutrient.id == NutrientKey.carbohydrateG.wire);
      expect(carbohydrate.nutrient.definition,
          NutrientDefinitions.euAvailableCarbohydrate);
      DriftFoodRepository.validateFoods([result.food]);

      expect(
          () => OpenFoodFactsFoodAdapter(
              datasetVersion: _version,
              licence: _licence,
              carbohydrateDefinition: 'general-carbs'),
          throwsArgumentError);
    });

    test('uses serving values when no per-100 g values exist', () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_servingOnlyRecord());
      final food = result.food;

      expect(food.basisUnit, FoodUnit.g);
      expect(food.basisValue, '100');
      expect(food.observations.first.basis.value, Exact.parse('30'));
      expect(food.per100g[NutrientKey.proteinG].numericValue, 20);
      expect(food.per100g[NutrientKey.energyKcal].numericValue, 400);
      expect(food.per100g[NutrientKey.sugarsG].numericValue, 0);
      expect(food.portions.portionGrams, 30);
      expect(result.issues, isEmpty);
      DriftFoodRepository.validateFoods([food]);
    });

    test('preserves approximate modifiers as estimated observations', () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(<String, Object?>{
        'code': '4006381333931',
        'product': <String, Object?>{
          'code': '4006381333931',
          'product_name': 'Approximate food',
          'nutrition_data_per': '100g',
          'nutriments': <String, Object?>{
            'energy-kcal_100g': 100,
            'energy-kcal_unit': 'kcal',
            'energy-kcal_modifier': '~',
            'sugars_100g': 5,
            'sugars_unit': 'g',
            'sugars_modifier': '<',
          },
        },
      });
      expect(result.food.per100g[NutrientKey.energyKcal],
          isA<NutrientEstimated>());
      expect(result.food.per100g[NutrientKey.energyKcal].numericValue, 100);
      expect(result.food.per100g[NutrientKey.sugarsG],
          isA<NutrientEstimated>());
      expect(result.food.per100g[NutrientKey.sugarsG].numericValue, 5);
      final energy = result.food.observations.firstWhere(
          (observation) =>
              observation.nutrient.id == NutrientKey.energyKcal.wire);
      expect(energy.origin, contains('modifier=~'));
    });

    test('reports missing units, conflicting energy units and invalid codes',
        () {
      final missingUnit = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_productRecord(<String, Object?>{
        'proteins_100g': 5,
      }));
      expect(missingUnit.issues.map((issue) => issue.code),
          contains('missing-unit'));
      expect(missingUnit.food.per100g[NutrientKey.proteinG],
          NutrientValue.unknown);

      final conflict = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_productRecord(<String, Object?>{
        'energy-kj_100g': 100,
        'energy-kj_unit': 'kcal',
        'proteins_100g': 5,
        'proteins_unit': 'g',
      }));
      expect(conflict.issues.map((issue) => issue.code),
          contains('conflicting-unit'));
      expect(conflict.food.per100g[NutrientKey.energyKj],
          NutrientValue.unknown);
      expect(conflict.food.per100g[NutrientKey.proteinG].numericValue, 5);

      final invalidCode = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(<String, Object?>{
        'code': '1234567890123',
        'product': <String, Object?>{
          'code': '1234567890123',
          'product_name': 'Invalid code food',
          'nutriments': <String, Object?>{
            'proteins_100g': 5,
            'proteins_unit': 'g',
          },
        },
      });
      expect(invalidCode.issues.map((issue) => issue.code),
          contains('invalid-barcode'));
      expect(invalidCode.food.barcodes, isEmpty);
      expect(invalidCode.food.source.datasetId, '1234567890123');
    });

    test('retains raw allergen tags, traces and allowlisted dietary tags '
        'separately', () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(<String, Object?>{
        'code': '4006381333931',
        'product': <String, Object?>{
          'code': '4006381333931',
          'product_name': 'Allergen test product',
          'nutrition_data_per': '100g',
          'nutriments': <String, Object?>{
            'proteins_100g': 5,
            'proteins_unit': 'g',
          },
          'allergens_tags': ['en:milk', 'en:soybeans'],
          'traces_tags': ['en:nuts'],
          'labels_tags': ['en:organic', 'en:gluten-free', 'fr:triman'],
          'ingredients_analysis_tags': [
            'en:vegan',
            'en:non-vegan',
            'en:palm-oil-free'
          ],
        },
      });
      final food = result.food;
      expect(food.allergens, isNull);
      expect(result.sourceDetails['allergens_tags'],
          <Object?>['en:milk', 'en:soybeans']);
      expect(result.sourceDetails['traces'], <String>['nuts']);
      expect(food.dietaryTags,
          unorderedEquals(<String>{
            'organic',
            'gluten-free',
            'vegan',
            'palm-oil-free'
          }));
      expect(food.dietaryTags, isNot(contains('non-vegan')));
    });

    test('strict planning never certifies incomplete OFF allergen metadata',
        () {
      for (final tags in <List<Object?>>[
        <Object?>['en:none'],
        <Object?>['en:milk'],
      ]) {
        final result = OpenFoodFactsFoodAdapter(
                datasetVersion: _version, licence: _licence)
            .adapt(<String, Object?>{
          'code': '4006381333931',
          'product': <String, Object?>{
            'code': '4006381333931',
            'product_name': 'Allergen completeness fixture',
            'nutrition_data_per': '100g',
            'nutriments': <String, Object?>{
              'proteins_100g': 1,
              'proteins_unit': 'g',
            },
            'allergens_tags': tags,
          },
        });
        expect(result.food.allergens, isNull);
        final recipe = RecipeVersion(
            id: 'strict-allergen-${tags.join('-')}',
            revision: 1,
            name: 'Strict planning fixture',
            ingredients: [
              RecipeIngredient(result.food, Exact.parse('1'))
            ],
            servings: Exact.parse('1'),
            minutes: 0,
            // Test-only recipe-level set so the ingredient check is reached.
            allergens: const <String>{'soybeans'});
        expect(recipe.eligible(const <String>{'milk'}, const <String>{}),
            isFalse);
        expect(recipe.eligible(const <String>{'sesame'}, const <String>{}),
            isFalse);
        expect(recipe.eligible(const <String>{}, const <String>{}), isTrue);
      }
    });

    test('keeps records with no mappable nutrition data usable', () {
      final result = OpenFoodFactsFoodAdapter(
              datasetVersion: _version, licence: _licence)
          .adapt(_productRecord(<String, Object?>{
        'salt_100g': 0.5,
        'salt_unit': 'g',
      }));
      expect(result.food.observations, isEmpty);
      expect(result.food.per100g.values, isEmpty);
      expect(result.issues.map((issue) => issue.code),
          contains('no-mapped-nutrients'));
      expect(result.unmappedNutrients, contains('salt'));
      DriftFoodRepository.validateFoods([result.food]);
    });

    test('rejects a product without a name', () {
      expect(
          () => OpenFoodFactsFoodAdapter(
                  datasetVersion: _version, licence: _licence)
              .adapt(<String, Object?>{
                'code': '4006381333931',
                'product': <String, Object?>{'code': '4006381333931'},
              }),
          throwsFormatException);
    });

    test('builds a catalogue pack that survives encode/decode and validation',
        () {
      final adapter = OpenFoodFactsFoodAdapter(
          datasetVersion: _version,
          licence: _licence,
          carbohydrateDefinition:
              NutrientDefinitions.euAvailableCarbohydrate);
      final food = adapter.adapt(_cokeRecord()).food;
      final pack = CataloguePack(
          dataset: OpenFoodFactsFoodAdapter.dataset,
          version: _version,
          licence: _licence,
          attribution: 'Test attribution; not an ODbL review',
          foods: [food]);
      final restored = CataloguePack.decode(pack.encode());
      expect(restored.foods.single.id, food.id);
      DriftFoodRepository.validateFoods(restored.foods);
    });
  });

  group('ImportedFoodBuilder source intervals', () {
    ImportedFoodBuilder builder() => ImportedFoodBuilder(
        dataset: 'fixture', datasetVersion: _version, licence: _licence);

    test('converts supplied bounds exactly with the observation unit', () {
      final subject = builder();
      final added = subject.addObservation(
          key: NutrientKey.sodiumMg,
          amount: Exact.parse('0.0001'),
          sourceUnit: 'g',
          basis: FoodAmount('100', FoodUnit.g),
          sourceId: 'food-1',
          origin: 'fixture:nutrient/sodium',
          qualifier: ObservationQualifier.reported,
          suppliedInterval: SourceInterval(
              lower: Exact.parse('0.00009'),
              upper: Exact.parse('0.0001'),
              lowerInclusive: true,
              upperInclusive: true,
              scope: 'fixture:label/sodium',
              method: 'Synthetic label range'),
          evidenceDate: '2024-02-29');
      expect(added, isTrue);

      final food = subject
          .build(
              id: 'fixture:food-1',
              name: 'Fixture food',
              sourceId: 'food-1',
              basisUnit: FoodUnit.g,
              basisValue: '100')
          .food;
      final observation = food.observations.single;
      expect(observation.amount, Exact.parse('0.1'));
      expect(observation.origin, 'fixture:nutrient/sodium;unit=g->mg');
      expect(observation.evidenceDate, '2024-02-29');
      final interval = observation.suppliedInterval!;
      expect(interval.lower, Exact.parse('0.09'));
      expect(interval.upper, Exact.parse('0.1'));
      expect(interval.lowerInclusive, isTrue);
      expect(interval.upperInclusive, isTrue);
      expect(interval.scope, 'fixture:label/sodium');
      expect(interval.method, 'Synthetic label range');
      // The interval annotates the source value; the profile remains the
      // reported amount rather than a widened or narrowed intake bound.
      expect(food.per100g[NutrientKey.sodiumMg].numericValue, 0.1);
    });

    test('converts bounds when the source supplies no exact amount', () {
      final subject = builder();
      final added = subject.addObservation(
          key: NutrientKey.iodineUg,
          amount: null,
          sourceUnit: 'mg',
          basis: FoodAmount('100', FoodUnit.g),
          sourceId: 'food-4',
          origin: 'fixture:nutrient/iodine',
          qualifier: ObservationQualifier.unknown,
          suppliedInterval: SourceInterval(
              lower: Exact.parse('0.001'),
              upper: Exact.parse('0.002'),
              lowerInclusive: true,
              upperInclusive: false,
              scope: 'fixture:label/iodine',
              method: 'Synthetic label range'));
      expect(added, isTrue);

      final food = subject
          .build(
              id: 'fixture:food-4',
              name: 'Fixture food',
              sourceId: 'food-4',
              basisUnit: FoodUnit.g,
              basisValue: '100')
          .food;
      final observation = food.observations.single;
      expect(observation.amount, isNull);
      expect(observation.qualifier, ObservationQualifier.unknown);
      expect(observation.origin, 'fixture:nutrient/iodine;unit=mg->µg');
      final interval = observation.suppliedInterval!;
      expect(interval.lower, Exact.parse('1'));
      expect(interval.upper, Exact.parse('2'));
      expect(interval.lowerInclusive, isTrue);
      expect(interval.upperInclusive, isFalse);
    });

    test('rejects interval bounds whose source unit cannot be converted', () {
      final subject = builder();
      final added = subject.addObservation(
          key: NutrientKey.sodiumMg,
          amount: null,
          sourceUnit: 'IU',
          basis: FoodAmount('100', FoodUnit.g),
          sourceId: 'food-1',
          origin: 'fixture:nutrient/sodium',
          qualifier: ObservationQualifier.unknown,
          suppliedInterval: SourceInterval(
              lower: Exact.one,
              upper: Exact.parse('2'),
              lowerInclusive: true,
              upperInclusive: false,
              scope: 'fixture:label/sodium',
              method: 'Synthetic label range'));
      expect(added, isFalse);

      final result = subject.build(
          id: 'fixture:food-1',
          name: 'Fixture food',
          sourceId: 'food-1',
          basisUnit: FoodUnit.g,
          basisValue: '100');
      expect(result.food.observations, isEmpty);
      expect(result.issues.single.code, 'unsupported-unit');
      expect(result.food.per100g[NutrientKey.sodiumMg], NutrientValue.unknown);
    });

    test('keeps a nutrient but drops an invalid evidence date with a diagnostic',
        () {
      final subject = builder();
      final added = subject.addObservation(
          key: NutrientKey.iodineUg,
          amount: null,
          sourceUnit: 'µg',
          basis: FoodAmount('100', FoodUnit.g),
          sourceId: 'food-3',
          origin: 'fixture:nutrient/iodine',
          qualifier: ObservationQualifier.unknown,
          evidenceDate: '2023-02-30');
      expect(added, isTrue);

      final result = subject.build(
          id: 'fixture:food-3',
          name: 'Fixture food',
          sourceId: 'food-3',
          basisUnit: FoodUnit.g,
          basisValue: '100');
      expect(result.food.observations.single.evidenceDate, isNull);
      expect(result.issues.single.code, 'invalid-evidence-date');
    });

    test('round trips interval and evidence date through a catalogue snapshot',
        () {
      final subject = builder();
      final added = subject.addObservation(
          key: NutrientKey.iodineUg,
          amount: Exact.parse('2.5'),
          sourceUnit: 'µg',
          basis: FoodAmount('100', FoodUnit.g),
          sourceId: 'food-2',
          origin: 'fixture:nutrient/iodine',
          qualifier: ObservationQualifier.reported,
          suppliedInterval: SourceInterval(
              lower: Exact.parse('2.4'),
              upper: Exact.parse('2.6'),
              lowerInclusive: true,
              upperInclusive: false,
              scope: 'fixture:label/iodine',
              method: 'Synthetic label range'),
          evidenceDate: '2023-06-01');
      expect(added, isTrue);

      final food = subject
          .build(
              id: 'fixture:food-2',
              name: 'Fixture food',
              sourceId: 'food-2',
              basisUnit: FoodUnit.g,
              basisValue: '100')
          .food;
      final pack = CataloguePack(
          dataset: 'fixture',
          version: _version,
          licence: _licence,
          attribution: 'Synthetic fixture attribution; not a review',
          foods: <Food>[food]);
      final restored = CataloguePack.decode(pack.encode()).foods.single;

      final observation = restored.observations.single;
      expect(observation.amount, Exact.parse('2.5'));
      expect(observation.evidenceDate, '2023-06-01');
      final interval = observation.suppliedInterval!;
      expect(interval.lower, Exact.parse('2.4'));
      expect(interval.upper, Exact.parse('2.6'));
      expect(interval.lowerInclusive, isTrue);
      expect(interval.upperInclusive, isFalse);
      expect(interval.scope, 'fixture:label/iodine');
      expect(interval.method, 'Synthetic label range');
      expect(restored.per100g[NutrientKey.iodineUg].numericValue, 2.5);
    });
  });
}

Map<String, Object?> _cheddarRecord() => <String, Object?>{
      'fdcId': 328637,
      'description': 'Cheese, cheddar',
      'dataType': 'Foundation',
      'publicationDate': '4/1/2019',
      'foodCategory': 'Dairy and Egg Products',
      'marketCountry': 'United States',
      'foodNutrients': <Object?>[
        _nestedNutrient(1008, '208', 'Energy', 'kcal', 408),
        _nestedNutrient(1003, '203', 'Protein', 'g', 23.3),
        _nestedNutrient(1004, '204', 'Total lipid (fat)', 'g', 34),
        _nestedNutrient(1005, '205', 'Carbohydrate, by difference', 'g', 2.44),
        _nestedNutrient(1087, '301', 'Calcium, Ca', 'mg', 707),
        _nestedNutrient(1089, '303', 'Iron, Fe', 'mg', 0.16),
        _nestedNutrient(1093, '307', 'Sodium, Na', 'mg', 654),
        _nestedNutrient(
            1258, '606', 'Fatty acids, total saturated', 'g', 19.2),
      ],
      'foodPortions': <Object?>[
        <String, Object?>{
          'amount': 1,
          'gramWeight': 17,
          'measureUnit': <String, Object?>{'name': 'slice'},
        },
        <String, Object?>{
          'amount': 1,
          'gramWeight': 105,
          'measureUnit': <String, Object?>{'name': 'cup'},
        },
        <String, Object?>{
          'amount': 1,
          'gramWeight': 30,
          'measureUnit': <String, Object?>{'name': 'RACC'},
        },
      ],
    };

Map<String, Object?> _nutellaSearchRecord() => <String, Object?>{
      'fdcId': 2026852,
      'description': 'NUTELLA FERRERO WITH BREADSTICKS',
      'dataType': 'Branded',
      'publishedDate': '2021-10-28',
      'brandOwner': 'Ferrero U.S.A., Incorporated',
      'brandName': 'NUTELLA FERRERO',
      'gtinUpc': '009800800124',
      'marketCountry': 'United States',
      'servingSize': 52,
      'servingSizeUnit': 'g',
      'foodNutrients': <Object?>[
        _flatNutrient(1003, '203', 'Protein', 'G', 7.69),
        _flatNutrient(1004, '204', 'Total lipid (fat)', 'G', 26.9),
        _flatNutrient(1005, '205', 'Carbohydrate, by difference', 'G', 65.4),
        _flatNutrient(1008, '208', 'Energy', 'KCAL', 519),
        _flatNutrient(2000, '269', 'Total Sugars', 'G', 44.2),
        _flatNutrient(1079, '291', 'Fiber, total dietary', 'G', 3.8),
        _flatNutrient(1087, '301', 'Calcium, Ca', 'MG', 77),
        _flatNutrient(1089, '303', 'Iron, Fe', 'MG', 2.08),
        _flatNutrient(1093, '307', 'Sodium, Na', 'MG', 250),
        _flatNutrient(1258, '606', 'Fatty acids, total saturated', 'G', 9.62),
      ],
    };

Map<String, Object?> _nutellaLabelOnlyRecord() => <String, Object?>{
      'fdcId': 2026852,
      'description': 'NUTELLA FERRERO WITH BREADSTICKS',
      'dataType': 'Branded',
      'gtinUpc': '009800800124',
      'servingSize': 52,
      'servingSizeUnit': 'g',
      'foodNutrients': const <Object?>[],
      'labelNutrients': <String, Object?>{
        'fat': <String, Object?>{'value': 14},
        'saturatedFat': <String, Object?>{'value': 5},
        'transFat': <String, Object?>{'value': 0},
        'cholesterol': <String, Object?>{'value': 5.2},
        'sodium': <String, Object?>{'value': 130},
        'carbohydrates': <String, Object?>{'value': 34},
        'fiber': <String, Object?>{'value': 1.98},
        'sugars': <String, Object?>{'value': 23},
        'protein': <String, Object?>{'value': 4},
        'calcium': <String, Object?>{'value': 40},
        'iron': <String, Object?>{'value': 1.08},
        'postassium': <String, Object?>{'value': 159.88},
        'calories': <String, Object?>{'value': 270},
      },
    };

Map<String, Object?> _singleNutrientRecord({
  String description = 'Test food',
  num? value,
  String? derivationCode,
  String? derivationDescription,
}) =>
    <String, Object?>{
      'fdcId': 1,
      'description': description,
      'dataType': 'Foundation',
      'foodNutrients': <Object?>[
        <String, Object?>{
          'nutrientId': 1079,
          'nutrientNumber': '291',
          'nutrientName': 'Fiber, total dietary',
          'unitName': 'G',
          if (value != null) 'value': value,
          'derivationCode': derivationCode ?? 'A',
          'derivationDescription': derivationDescription ?? 'Analytical',
        }
      ],
    };

Map<String, Object?> _waterRecord() => <String, Object?>{
      'code': '3274080005003',
      'product': <String, Object?>{
        'code': '3274080005003',
        'product_name': 'isabelle',
        'generic_name': 'Eau De Source',
        'brands': 'Cristaline',
        'nutrition_data_per': '100g',
        'serving_quantity': 1500,
        'serving_quantity_unit': 'ml',
        'product_quantity': 1500,
        'product_quantity_unit': 'ml',
        'nutriments': <String, Object?>{
          'calcium': 0.113,
          'calcium_100g': 0.113,
          'calcium_unit': 'g',
          'sodium': 0.0063,
          'sodium_100g': 0.0063,
          'sodium_unit': 'g',
          'salt': 0.00275,
          'salt_100g': 0.00275,
          'salt_unit': 'g',
          'potassium': 0.002,
          'potassium_100g': 0.002,
          'potassium_unit': 'g',
        },
        'nutriments_estimated': <String, Object?>{
          'energy-kcal_100g': 0,
          'proteins_100g': 0,
        },
        'allergens_tags': <Object?>['en:none'],
        'traces_tags': <Object?>['en:none'],
        'labels_tags': <Object?>['fr:triman'],
        'ingredients_analysis_tags': <Object?>[
          'en:palm-oil-free',
          'en:vegan',
          'en:vegetarian'
        ],
        'countries_tags': <Object?>[
          'en:belgium',
          'en:france',
          'en:united-states'
        ],
      },
    };

Map<String, Object?> _cokeRecord() => <String, Object?>{
      'code': '5449000000996',
      'product': <String, Object?>{
        'code': '5449000000996',
        'product_name': 'Coca-Cola Original',
        'nutrition_data_per': '100g',
        'serving_quantity': 330,
        'serving_quantity_unit': 'ml',
        'nutriments': <String, Object?>{
          'energy': 180,
          'energy_100g': 180,
          'energy_unit': 'kJ',
          'energy-kj': 180,
          'energy-kj_100g': 180,
          'energy-kj_unit': 'kJ',
          'energy-kcal': 42.4,
          'energy-kcal_100g': 42.4,
          'energy-kcal_unit': 'kcal',
          'fat': 0,
          'fat_100g': 0,
          'fat_unit': 'g',
          'saturated-fat': 0,
          'saturated-fat_100g': 0,
          'saturated-fat_unit': 'g',
          'carbohydrates': 10.6,
          'carbohydrates_100g': 10.6,
          'carbohydrates_unit': 'g',
          'sugars': 10.6,
          'sugars_100g': 10.6,
          'sugars_unit': 'g',
          'proteins': 0,
          'proteins_100g': 0,
          'proteins_unit': 'g',
          'sodium': 0,
          'sodium_100g': 0,
          'sodium_unit': 'g',
          'salt': 0,
          'salt_100g': 0,
          'salt_unit': 'g',
          'added-sugars': 10.6,
          'added-sugars_100g': 10.6,
          'added-sugars_unit': 'g',
        },
      },
    };

Map<String, Object?> _servingOnlyRecord() => <String, Object?>{
      'code': '4006381333931',
      'product': <String, Object?>{
        'code': '4006381333931',
        'product_name': 'Serving food',
        'nutrition_data_per': 'serving',
        'serving_quantity': 30,
        'serving_quantity_unit': 'g',
        'nutriments': <String, Object?>{
          'proteins_serving': 6,
          'proteins_unit': 'g',
          'energy-kcal_serving': 120,
          'energy-kcal_unit': 'kcal',
          'sugars_serving': 0,
          'sugars_unit': 'g',
        },
      },
    };

Map<String, Object?> _productRecord(Map<String, Object?> nutriments) =>
    <String, Object?>{
      'code': '4006381333931',
      'product': <String, Object?>{
        'code': '4006381333931',
        'product_name': 'Test product',
        'nutrition_data_per': '100g',
        'nutriments': nutriments,
      },
    };

Map<String, Object?> _nestedNutrient(
        int id, String number, String name, String unit, num amount) =>
    <String, Object?>{
      'type': 'FoodNutrient',
      'nutrient': <String, Object?>{
        'id': id,
        'number': number,
        'name': name,
        'unitName': unit,
      },
      'amount': amount,
      'foodNutrientDerivation': <String, Object?>{
        'code': 'A',
        'description': 'Analytical',
      },
    };

Map<String, Object?> _flatNutrient(
        int id, String number, String name, String unit, num value) =>
    <String, Object?>{
      'nutrientId': id,
      'nutrientNumber': number,
      'nutrientName': name,
      'unitName': unit,
      'value': value,
    };
