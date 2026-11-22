import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('recipe codec retains portion limits and allergy evidence', () {
    final food = Food(
      id: 'rice',
      name: 'Rice',
      per100g: const NutrientProfile.empty(),
      source: const FoodSource(
        dataset: 'fixture',
        datasetId: 'rice',
        licence: 'CC0',
      ),
    );
    final recipe = RecipeVersion(
      id: 'rice-bowl',
      name: 'Rice bowl',
      prepMinutes: 10,
      minServings: .75,
      maxServings: 2,
      allergens: {},
      allergenSource: 'review-fixture',
      ingredients: [
        RecipeIngredient(
          food: food,
          edibleGrams: 100,
          purchaseName: 'Rice',
          purchaseGrams: 100,
          purchaseId: 'dry-rice',
        ),
      ],
    );
    final encoded = encodeRecipe(recipe);
    expect(encoded['versionFormat'], 1);
    final restored = decodeRecipe(encoded);
    expect(restored.minServings, .75);
    expect(restored.maxServings, 2);
    expect(restored.allergens, isEmpty);
    expect(restored.allergenSource, 'review-fixture');
    expect(restored.ingredients.single.purchaseId, 'dry-rice');
    expect(restored.ingredients.single.food.source.licence, 'CC0');
  });

  test(
      'recipe codec round-trips all nutrient states, food metadata, portions, and semantic version',
      () {
    final fullFood = Food(
      id: 'custom:stew-base',
      name: 'Prepared lentil stew base',
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(145.5),
        NutrientKey.proteinG: NutrientReported(8.2),
        NutrientKey.fatG: NutrientEstimated(3.4, basis: 'label-calc'),
        NutrientKey.saturatedFatG: const NutrientTrace(),
        NutrientKey.carbohydrateG: const NutrientUnknown(),
        NutrientKey.fiberG: NutrientMeasured(0),
        NutrientKey.sugarsG: NutrientReported(0),
        NutrientKey.sodiumMg: NutrientEstimated(220, basis: 'lab-estimate'),
      }),
      source: const FoodSource(
        dataset: 'curated-eu',
        datasetId: 'stew-1',
        datasetVersion: '2026-11',
        licence: 'CC-BY-4.0',
      ),
      portions: const PortionDefinition(
        portionGrams: 240,
        densityGramsPerMillilitre: 1.05,
      ),
      quality: DataQuality.curated,
      preparation: Preparation.cooked,
      allergens: {'celery', 'mustard'},
      dietaryTags: {'vegan', 'gluten-free'},
      isComposite: true,
    );
    final unknownAllergenFood = Food(
      id: 'custom:oil',
      name: 'Cooking oil',
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(884),
      }),
      source: const FoodSource(dataset: 'fixture', datasetId: 'oil'),
      quality: DataQuality.verified,
      preparation: Preparation.raw,
      allergens: null,
      dietaryTags: const {},
      isComposite: false,
    );
    final recipe = RecipeVersion(
      id: 'local-recipe:stew',
      name: 'Hearty lentil stew',
      version: 3,
      prepMinutes: 35,
      servings: 4,
      finishedGrams: 1120,
      method: 'Simmer slowly until tender.',
      minServings: 0.25,
      maxServings: 4.5,
      allergens: {'celery', 'mustard'},
      allergenSource: 'Manufacturer spec sheet 2026-11',
      ingredients: [
        RecipeIngredient(
          food: fullFood,
          edibleGrams: 800,
          purchaseName: 'Prepared lentil stew base',
          purchaseGrams: 800,
          purchaseId: 'pkg-stew-base',
        ),
        RecipeIngredient(
          food: unknownAllergenFood,
          edibleGrams: 20,
          purchaseName: 'Cooking oil',
        ),
      ],
    );

    final encoded = encodeRecipe(recipe);
    expect(encoded['versionFormat'], 1);
    expect(encoded['version'], 3);

    // Ensure semantic version 3 is never confused with versionFormat.
    final jsonCopy = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
    final restored = decodeRecipe(jsonCopy);

    expect(restored.id, 'local-recipe:stew');
    expect(restored.name, 'Hearty lentil stew');
    expect(restored.version, 3);
    expect(restored.prepMinutes, 35);
    expect(restored.servings, 4);
    expect(restored.finishedGrams, 1120);
    expect(restored.method, 'Simmer slowly until tender.');
    expect(restored.minServings, 0.25);
    expect(restored.maxServings, 4.5);
    expect(restored.allergens, {'celery', 'mustard'});
    expect(restored.allergenSource, 'Manufacturer spec sheet 2026-11');

    final first = restored.ingredients[0];
    expect(first.edibleGrams, 800);
    expect(first.purchaseName, 'Prepared lentil stew base');
    expect(first.purchaseGrams, 800);
    expect(first.purchaseId, 'pkg-stew-base');
    expect(first.food.id, 'custom:stew-base');
    expect(first.food.source.dataset, 'curated-eu');
    expect(first.food.source.datasetId, 'stew-1');
    expect(first.food.source.datasetVersion, '2026-11');
    expect(first.food.source.licence, 'CC-BY-4.0');
    expect(first.food.portions.portionGrams, 240);
    expect(first.food.portions.densityGramsPerMillilitre, 1.05);
    expect(first.food.quality, DataQuality.curated);
    expect(first.food.preparation, Preparation.cooked);
    expect(first.food.allergens, {'celery', 'mustard'});
    expect(first.food.dietaryTags, {'vegan', 'gluten-free'});
    expect(first.food.isComposite, isTrue);
    expect(
      first.food.per100g[NutrientKey.energyKcal],
      NutrientMeasured(145.5),
    );
    expect(
      first.food.per100g[NutrientKey.proteinG],
      NutrientReported(8.2),
    );
    expect(
      first.food.per100g[NutrientKey.fatG],
      NutrientEstimated(3.4, basis: 'label-calc'),
    );
    expect(
      first.food.per100g[NutrientKey.saturatedFatG],
      const NutrientTrace(),
    );
    expect(
      first.food.per100g[NutrientKey.carbohydrateG],
      const NutrientUnknown(),
    );
    expect(first.food.per100g[NutrientKey.fiberG], NutrientMeasured(0));
    expect(first.food.per100g[NutrientKey.sugarsG], NutrientReported(0));
    expect(
      first.food.per100g[NutrientKey.sodiumMg],
      NutrientEstimated(220, basis: 'lab-estimate'),
    );

    final second = restored.ingredients[1];
    expect(second.purchaseGrams, isNull);
    expect(second.purchaseId, isNull);
    expect(second.food.source.licence, isNull);
    expect(second.food.portions.portionGrams, isNull);
    expect(second.food.portions.densityGramsPerMillilitre, isNull);
    expect(second.food.quality, DataQuality.verified);
    expect(second.food.preparation, Preparation.raw);
    expect(second.food.allergens, isNull);
    expect(second.food.dietaryTags, isEmpty);
    expect(second.food.isComposite, isFalse);
  });

  test(
      'decodes legacy unversioned recipe with defaults and preserves unknown allergen/licence',
      () {
    final legacyNutrients = <String, Object?>{
      'energy_kcal': {'state': 'measured', 'value': 130.0},
      'protein_g': {'state': 'trace'},
      'fat_g': {'state': 'reported', 'value': 0.3},
      'fiber_g': {'state': 'estimated', 'value': 0.4, 'basis': 'legacy'},
    };
    final legacyRow = <String, dynamic>{
      'id': 'legacy-bowl',
      'name': 'Legacy rice bowl',
      'version': 2,
      'prepMinutes': 12,
      'servings': 1,
      'finishedGrams': null,
      'method': 'Cook rice.',
      'ingredients': [
        {
          'id': 'bundled-fdc-169757',
          'name': 'Cooked white rice',
          'nutrients': legacyNutrients,
          'source': 'usda-fdc-sr-legacy',
          'sourceId': '169757',
          'sourceVersion': '2018-04',
          'preparation': 'cooked',
          'edibleGrams': 165,
          'purchaseName': 'Cooked white rice',
          'purchaseGrams': 165,
        },
      ],
    };

    final decoded = decodeRecipe(legacyRow);
    expect(decoded.id, 'legacy-bowl');
    expect(decoded.version, 2);
    expect(decoded.minServings, 0.5);
    expect(decoded.maxServings, 3.0);
    expect(decoded.allergens, isNull);
    expect(decoded.allergenSource, isNull);

    final ingredient = decoded.ingredients.single;
    expect(ingredient.purchaseId, isNull);
    expect(ingredient.food.source.licence, isNull);
    expect(ingredient.food.quality, DataQuality.imported);
    expect(ingredient.food.preparation, Preparation.cooked);
    expect(ingredient.food.allergens, isNull);
    expect(ingredient.food.dietaryTags, isEmpty);
    expect(ingredient.food.isComposite, isFalse);
    expect(ingredient.food.portions.portionGrams, isNull);
    expect(ingredient.food.portions.densityGramsPerMillilitre, isNull);

    // Nutrition JSON round-trips byte-for-byte for unchanged representations.
    final reEncodedFood =
        encodeRecipe(decoded)['ingredients']! as List<Object?>;
    final foodMap =
        (reEncodedFood.single as Map<String, Object?>)['food']! as Map;
    expect(jsonEncode(foodMap['per100g']), jsonEncode(legacyNutrients));
  });

  test('rejects unknown/future versionFormat with FormatException', () {
    final base = encodeRecipe(
      RecipeVersion(
        id: 'r1',
        name: 'Rice',
        prepMinutes: 5,
        ingredients: [
          RecipeIngredient(
            food: Food(
              id: 'rice',
              name: 'Rice',
              per100g: const NutrientProfile.empty(),
              source: const FoodSource(dataset: 'test', datasetId: 'rice'),
            ),
            edibleGrams: 100,
            purchaseName: 'Rice',
          ),
        ],
      ),
    );

    for (final badVersion in [2, 0, -1, '1', true, null]) {
      final mutated = <String, dynamic>{...base, 'versionFormat': badVersion};
      expect(() => decodeRecipe(mutated), throwsFormatException);
    }
  });

  test(
      'rejects malformed enums, numeric values, and missing fields as FormatException',
      () {
    final valid = encodeRecipe(
      RecipeVersion(
        id: 'r1',
        name: 'Rice',
        prepMinutes: 5,
        ingredients: [
          RecipeIngredient(
            food: Food(
              id: 'rice',
              name: 'Rice',
              per100g: NutrientProfile({
                NutrientKey.energyKcal: NutrientMeasured(130),
              }),
              source: const FoodSource(dataset: 'test', datasetId: 'rice'),
            ),
            edibleGrams: 100,
            purchaseName: 'Rice',
            purchaseGrams: 100,
          ),
        ],
      ),
    );

    final badCases = <Map<String, dynamic>>[
      {...valid, 'id': ''},
      {...valid, 'name': '   '},
      {...valid, 'version': 0},
      {...valid, 'prepMinutes': -1},
      {...valid, 'servings': 0},
      {...valid, 'servings': double.nan},
      {...valid, 'finishedGrams': -10},
      {...valid, 'minServings': 0},
      {...valid, 'minServings': 2.5, 'maxServings': 1.0},
      {
        ...valid,
        'allergens': [123]
      },
      {...valid, 'ingredients': <Object>[]},
      {
        ...valid,
        'ingredients': [
          {
            ...(valid['ingredients']! as List).first as Map<String, Object?>,
            'edibleGrams': -5,
          },
        ],
      },
      {
        ...valid,
        'ingredients': [
          {
            ...(valid['ingredients']! as List).first as Map<String, Object?>,
            'purchaseGrams': 0,
          },
        ],
      },
      {
        ...valid,
        'ingredients': [
          {
            ...(valid['ingredients']! as List).first as Map<String, Object?>,
            'food': {
              ...(((valid['ingredients']! as List).first
                  as Map<String, Object?>)['food']! as Map<String, Object?>),
              'preparation': 'fried',
            },
          },
        ],
      },
      {
        ...valid,
        'ingredients': [
          {
            ...(valid['ingredients']! as List).first as Map<String, Object?>,
            'food': {
              ...(((valid['ingredients']! as List).first
                  as Map<String, Object?>)['food']! as Map<String, Object?>),
              'quality': 'gold',
            },
          },
        ],
      },
      {
        ...valid,
        'ingredients': [
          {
            ...(valid['ingredients']! as List).first as Map<String, Object?>,
            'food': {
              ...(((valid['ingredients']! as List).first
                  as Map<String, Object?>)['food']! as Map<String, Object?>),
              'portions': {'portionGrams': -1},
            },
          },
        ],
      },
      {
        ...valid,
        'ingredients': [
          {
            ...(valid['ingredients']! as List).first as Map<String, Object?>,
            'food': {
              ...(((valid['ingredients']! as List).first
                  as Map<String, Object?>)['food']! as Map<String, Object?>),
              'per100g': {
                'energy_kcal': {'state': 'measured', 'value': -5},
              },
            },
          },
        ],
      },
    ];

    for (final bad in badCases) {
      expect(() => decodeRecipe(bad), throwsFormatException);
    }
  });

  test(
      'shared PhotoMealItem codec preserves id, labelPaths, nutrients, and reviewIssues',
      () {
    final item = PhotoMealItem(
      id: 'item-42',
      name: 'Labelled yogurt',
      portion: MealPortion(150, MealUnit.grams),
      nutrients: NutrientProfile({
        NutrientKey.energyKcal: NutrientReported(95),
        NutrientKey.proteinG: NutrientMeasured(8.5),
        NutrientKey.fatG: NutrientEstimated(2.1, basis: 'ai-meal-estimate'),
        NutrientKey.saturatedFatG: const NutrientTrace(),
        NutrientKey.carbohydrateG: const NutrientUnknown(),
      }),
      labelPaths: ['/labels/front.jpg', '/labels/back.jpg'],
      source: 'saved-meal:1',
      reviewIssues: const [
        NutritionIssue(
          code: 'macroEnergyMismatch',
          nutrient: NutrientKey.energyKcal,
          blocksAutomaticUse: false,
        ),
      ],
    );

    final encoded = encodePhotoMealItem(item);
    final decoded = decodePhotoMealItem(encoded);

    expect(decoded.id, 'item-42');
    expect(decoded.name, 'Labelled yogurt');
    expect(decoded.portion?.amount, 150);
    expect(decoded.portion?.unit, MealUnit.grams);
    expect(decoded.labelPaths, ['/labels/front.jpg', '/labels/back.jpg']);
    expect(decoded.source, 'saved-meal:1');
    expect(decoded.reviewIssues, item.reviewIssues);
    expect(decoded.nutrients[NutrientKey.energyKcal], NutrientReported(95));
    expect(decoded.nutrients[NutrientKey.proteinG], NutrientMeasured(8.5));
    expect(
      decoded.nutrients[NutrientKey.fatG],
      NutrientEstimated(2.1, basis: 'ai-meal-estimate'),
    );
    expect(decoded.nutrients[NutrientKey.saturatedFatG], const NutrientTrace());
    expect(
      decoded.nutrients[NutrientKey.carbohydrateG],
      const NutrientUnknown(),
    );

    expect(
      () => decodePhotoMealItem({
        'name': 'Bad',
        'amount': 100,
        'unit': 'liters',
        'nutrients': <String, Object?>{},
      }),
      throwsFormatException,
    );
    expect(
      () => decodePhotoMealItem({
        'name': 'Bad',
        'amount': -1,
        'unit': 'grams',
        'nutrients': <String, Object?>{},
      }),
      throwsFormatException,
    );
  });
}
