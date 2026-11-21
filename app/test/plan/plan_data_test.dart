import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/cooked_batches.dart';
import 'package:salu/src/features/plan/plan_suggestions.dart';
import 'package:salu/src/features/plan/recipe_library.dart';
import 'package:salu/src/features/plan/week_plan.dart';
import 'package:salu/src/features/search/food_library.dart';
import 'package:salu_core/salu_core.dart' hide MealSlot;
import 'package:salu_core/salu_core.dart' as core show MealSlot;
import 'package:salu_data/salu_data.dart';

import '../meals/meal_editor_fakes.dart';

void main() {
  test(
    'writes separate week files and reloads meals and shopping state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'salu_week_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = WeekPlanStore(directory: () async => directory);
      final week = startOfPlanWeek(DateTime(2026, 1, 1));
      expect(week, DateTime.utc(2025, 12, 29));
      final nextWeek = week.add(const Duration(days: 7));
      const position = (day: 6, slot: MealSlot.dinner);
      await store.save(
        WeekPlan(
          week,
          meals: const {
            position: PlannedMeal('Risotto', details: 'Rice, leeks'),
          },
          groceries: const [GroceryItem('Leeks', amount: '2', checked: true)],
        ),
      );
      await store.save(
        WeekPlan(nextWeek, groceries: const [GroceryItem('Apples')]),
      );
      final reopened = WeekPlanStore(directory: () async => directory);
      final saved = await reopened.load(week);
      expect(saved.dateFor(6), DateTime.utc(2026, 1, 4));
      expect(saved.meals[position]?.name, 'Risotto');
      expect(saved.meals[position]?.details, 'Rice, leeks');
      expect(saved.groceries.single.amount, '2');
      expect(saved.groceries.single.checked, isTrue);
      expect((await reopened.load(nextWeek)).groceries.single.name, 'Apples');
    },
  );

  test(
    'draft parser rejects malformed positions, repeated slots and absent ingredients',
    () {
      final meal = <String, Object>{
        'day': 0,
        'slot': 'dinner',
        'name': 'Stew',
        'ingredients': ['peas'],
      };
      for (final rows in [
        [meal, meal],
        [
          {...meal, 'day': 7},
        ],
        [
          {...meal, 'slot': 'late night'},
        ],
        [
          {...meal, 'ingredients': <String>[]},
        ],
      ]) {
        expect(
          () =>
              PlanDraft.fromResponse({'meals': rows, 'groceries': <Object>[]}),
          throwsFormatException,
        );
      }
      final parsed = PlanDraft.fromResponse({
        'meals': [meal],
        'groceries': <Object>[],
      });
      expect(parsed.meals[(day: 0, slot: MealSlot.dinner)]?.details, 'peas');
    },
  );

  test(
    'sends preferences only and checks direct exclusion mentions in meals and groceries',
    () {
      const preferences = FoodPreferences(
        likes: 'Stews',
        dislikes: 'Olives',
        exclusions: 'peanut\ncrème fraîche',
      );
      expect(jsonDecode(planSuggestionPrompt(preferences)), {
        'likes': 'Stews',
        'dislikes': 'Olives',
        'mustExclude': ['peanut', 'crème fraîche'],
      });
      final withMeal = PlanDraft(
        meals: const {
          (day: 0, slot: MealSlot.dinner): PlannedMeal(
            'Risotto',
            details: 'rice, CRÈME-FRAÎCHE',
          ),
        },
        groceries: const [],
      );
      final withGrocery = PlanDraft(
        meals: const {},
        groceries: const [GroceryItem('Roasted PEANUTS')],
      );
      final unrelated = PlanDraft(
        meals: const {},
        groceries: const [GroceryItem('Stew vegetables')],
      );
      expect(withMeal.mentionsExclusion(preferences), isTrue);
      expect(withGrocery.mentionsExclusion(preferences), isTrue);
      expect(unrelated.mentionsExclusion(preferences), isFalse);
    },
  );

  test('selected grocery updates preserve already checked state', () {
    final original = WeekPlan(
      DateTime.utc(2026, 1, 5),
      groceries: const [
        GroceryItem('Red onion', amount: 'one', checked: true),
        GroceryItem('Eggs', amount: 'six'),
      ],
    );
    final merged = PlanDraft(
      meals: const {},
      groceries: const [
        GroceryItem('red  onion', amount: 'two'),
        GroceryItem('Beans'),
      ],
    ).applyTo(original);
    expect(merged.groceries.map((item) => item.nameKey), [
      'red onion',
      'eggs',
      'beans',
    ]);
    expect(merged.groceries.first.amount, 'two');
    expect(merged.groceries.first.checked, isTrue);
  });

  test(
    'RecipeLibrary forwards lossless codec, tags version 1, and lazily migrates legacy without mutating diary',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final docs = LocalDocumentStore(db);
      final mealsRepo = DriftPhotoMealRepository(db);
      final library = RecipeLibrary(const EmptyCatalogue(), docs);

      final food = Food(
        id: 'custom:chickpeas',
        name: 'Chickpeas',
        per100g: NutrientProfile({
          NutrientKey.energyKcal: NutrientMeasured(164),
          NutrientKey.proteinG: NutrientReported(8.9),
          NutrientKey.fatG: NutrientEstimated(2.6, basis: 'label'),
          NutrientKey.saturatedFatG: const NutrientTrace(),
          NutrientKey.sodiumMg: const NutrientUnknown(),
        }),
        source: const FoodSource(
          dataset: 'curated',
          datasetId: 'cp-1',
          datasetVersion: '2026-11',
          licence: 'CC-BY-4.0',
        ),
        portions: const PortionDefinition(
          portionGrams: 150,
          densityGramsPerMillilitre: 0.85,
        ),
        quality: DataQuality.curated,
        preparation: Preparation.cooked,
        allergens: const {},
        dietaryTags: const {'vegan'},
        isComposite: true,
      );
      final recipe = RecipeVersion(
        id: 'local-recipe:salad',
        name: 'Chickpea bowl',
        version: 2,
        prepMinutes: 10,
        servings: 2,
        finishedGrams: 300,
        method: 'Toss.',
        minServings: 0.75,
        maxServings: 2.5,
        allergens: const {},
        allergenSource: 'manual review',
        ingredients: [
          RecipeIngredient(
            food: food,
            edibleGrams: 200,
            purchaseName: 'Canned chickpeas',
            purchaseGrams: 240,
            purchaseId: 'can-chickpeas',
          ),
        ],
      );

      // Forwarding methods remain lossless.
      final forwarded =
          RecipeLibrary.decodeRecipe(RecipeLibrary.encodeRecipe(recipe));
      expect(forwarded.minServings, 0.75);
      expect(forwarded.maxServings, 2.5);
      expect(forwarded.allergens, isEmpty);
      expect(forwarded.allergenSource, 'manual review');
      expect(forwarded.ingredients.single.purchaseId, 'can-chickpeas');
      expect(forwarded.ingredients.single.food.source.licence, 'CC-BY-4.0');
      expect(forwarded.ingredients.single.food.isComposite, isTrue);

      // Historical diary snapshot stays frozen even when recipe library adds/updates.
      final diaryDate = DiaryDate.parse('2026-11-18');
      await mealsRepo.saveNew(
        PhotoMeal(
          id: 'hist-1',
          date: diaryDate,
          slot: core.MealSlot.lunch,
          caption: 'Historical bowl',
          createdAt: DateTime.utc(2026, 11, 18, 12),
          items: recipe.snapshot(1),
        ),
      );

      await library.add(recipe);
      final storedDoc = await docs.read('recipe-library');
      expect(storedDoc!.data['version'], 1);

      final loaded = await library.load();
      expect(loaded.single.minServings, 0.75);
      expect(loaded.single.ingredients.single.food.allergens, isEmpty);

      // Adding a new recipe version does not mutate historical diary snapshot.
      await library.add(
        RecipeVersion(
          id: 'local-recipe:salad',
          name: 'Chickpea bowl updated',
          version: 3,
          prepMinutes: 15,
          ingredients: [
            RecipeIngredient(
              food: Food(
                id: 'custom:chickpeas',
                name: 'Chickpeas',
                per100g: NutrientProfile({
                  NutrientKey.energyKcal: NutrientMeasured(999),
                }),
                source: const FoodSource(
                  dataset: 'curated',
                  datasetId: 'cp-1',
                ),
              ),
              edibleGrams: 200,
              purchaseName: 'Canned chickpeas',
            ),
          ],
        ),
      );
      final historical = (await mealsRepo.listFor(diaryDate)).single;
      expect(
        historical.items.single.nutrients[NutrientKey.energyKcal],
        NutrientMeasured(164),
      );

      // Legacy unversioned document migrates lazily preserving unrelated fields.
      final legacyNutrients = <String, Object?>{
        'energy_kcal': {'state': 'measured', 'value': 130.0},
        'protein_g': {'state': 'trace'},
      };
      await docs.put('recipe-library', storedDoc.revision + 1, {
        'customMeta': 'keep-me',
        'recipes': [
          {
            'id': 'legacy-r',
            'name': 'Legacy recipe',
            'version': 2,
            'prepMinutes': 8,
            'servings': 1,
            'finishedGrams': null,
            'method': 'Mix.',
            'ingredients': [
              {
                'id': 'rice',
                'name': 'Rice',
                'nutrients': legacyNutrients,
                'source': 'fixture',
                'sourceId': 'rice',
                'sourceVersion': '1',
                'preparation': 'cooked',
                'edibleGrams': 100,
                'purchaseName': 'Rice',
                'purchaseGrams': 100,
              },
            ],
          },
        ],
      });
      final migratedLoaded = await library.load();
      expect(migratedLoaded.single.id, 'legacy-r');
      expect(migratedLoaded.single.version, 2);
      expect(migratedLoaded.single.allergens, isNull);
      expect(
          migratedLoaded.single.ingredients.single.food.source.licence, isNull);
      final afterMigration = await docs.read('recipe-library');
      expect(afterMigration!.data['version'], 1);
      expect(afterMigration.data['customMeta'], 'keep-me');
      final migratedRecipe =
          (afterMigration.data['recipes'] as List).single as Map;
      expect(migratedRecipe['versionFormat'], 1);
      final migratedFood = ((migratedRecipe['ingredients'] as List).single
          as Map)['food'] as Map;
      expect(jsonEncode(migratedFood['per100g']), jsonEncode(legacyNutrients));
    },
  );

  test(
    'CookedBatches preserves recipe metadata, yield/remainder, atomicity, and migrates legacy',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final docs = LocalDocumentStore(db);
      final batches = CookedBatches(docs);

      final recipe = RecipeVersion(
        id: 'local-recipe:soup',
        name: 'Lentil soup',
        version: 2,
        prepMinutes: 25,
        servings: 4,
        finishedGrams: 1000,
        minServings: 0.5,
        maxServings: 2.0,
        allergens: const {'celery'},
        allergenSource: 'label check',
        ingredients: [
          RecipeIngredient(
            food: Food(
              id: 'lentils',
              name: 'Lentils',
              per100g: NutrientProfile({
                NutrientKey.energyKcal: NutrientMeasured(116),
                NutrientKey.fiberG: NutrientEstimated(7.9, basis: 'fdc'),
              }),
              source: const FoodSource(
                dataset: 'fixture',
                datasetId: 'lentils',
                licence: 'CC0',
              ),
              portions: const PortionDefinition(
                portionGrams: 100,
                densityGramsPerMillilitre: 1.1,
              ),
              quality: DataQuality.verified,
              preparation: Preparation.cooked,
              allergens: const {},
              dietaryTags: const {'vegan'},
              isComposite: false,
            ),
            edibleGrams: 400,
            purchaseName: 'Dry lentils',
            purchaseGrams: 200,
            purchaseId: 'dry-lentils',
          ),
        ],
      );

      await batches.add(
        'batch-1',
        CookedRecipeBatch(
          recipe: recipe,
          cookedServings: 4,
          finishedGrams: 1000,
          remainingFraction: 1,
        ),
      );
      final stored = await docs.read('cooked-batches');
      expect(stored!.data['version'], 1);

      final available = await batches.available();
      expect(available.single.batch.cookedServings, 4);
      expect(available.single.batch.finishedGrams, 1000);
      expect(available.single.batch.remainingFraction, 1);
      expect(available.single.batch.recipe.allergens, {'celery'});
      expect(
        available.single.batch.recipe.ingredients.single.purchaseId,
        'dry-lentils',
      );
      expect(
        available.single.batch.recipe.ingredients.single.food.source.licence,
        'CC0',
      );

      final mealDate = DiaryDate.parse('2026-11-19');
      final meal = PhotoMeal(
        id: 'meal-from-batch-1',
        date: mealDate,
        slot: core.MealSlot.dinner,
        caption: 'Soup leftovers',
        createdAt: DateTime.utc(2026, 11, 19, 19),
      );
      expect(
        await batches.log('batch-1', MealPortion(250, MealUnit.grams), meal),
        isTrue,
      );
      // Retry with same meal ID does not consume stock again.
      expect(
        await batches.log('batch-1', MealPortion(250, MealUnit.grams), meal),
        isFalse,
      );
      final remaining = (await batches.available()).single.batch;
      expect(remaining.remainingFraction, closeTo(0.75, 1e-9));
      final logged =
          (await DriftPhotoMealRepository(db).listFor(mealDate)).single;
      expect(logged.items.single.portion?.amount, 100);

      // Legacy untagged cooked-batches lazily migrates preserving unrelated fields.
      final latestDoc = await docs.read('cooked-batches');
      await docs.put('cooked-batches', latestDoc!.revision, {
        'extraNote': 'preserve',
        'batches': [
          {
            'id': 'legacy-b',
            'customBatchTag': 42,
            'recipe': {
              'id': 'legacy-soup',
              'name': 'Legacy soup',
              'version': 1,
              'prepMinutes': 15,
              'servings': 2,
              'finishedGrams': null,
              'method': 'Boil.',
              'ingredients': [
                {
                  'id': 'carrot',
                  'name': 'Carrot',
                  'nutrients': {
                    'energy_kcal': {'state': 'measured', 'value': 41},
                  },
                  'source': 'fixture',
                  'sourceId': 'carrot',
                  'sourceVersion': null,
                  'preparation': 'raw',
                  'edibleGrams': 200,
                  'purchaseName': 'Carrots',
                  'purchaseGrams': 200,
                },
              ],
            },
            'cookedServings': 2,
            'finishedGrams': 500,
            'remainingFraction': 0.5,
          },
        ],
      });
      final migrated = await batches.available();
      expect(migrated.single.id, 'legacy-b');
      expect(migrated.single.batch.remainingFraction, 0.5);
      final migratedDoc = await docs.read('cooked-batches');
      expect(migratedDoc!.data['version'], 1);
      expect(migratedDoc.data['extraNote'], 'preserve');
      expect(
          (migratedDoc.data['batches'] as List).single['customBatchTag'], 42);
    },
  );

  test(
    'FoodLibrary shares PhotoMealItem codec, versions food-library, and lazily migrates legacy',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final docs = LocalDocumentStore(db);
      final library = FoodLibrary(docs);

      const issue = NutritionIssue(
        code: 'macroEnergyMismatch',
        nutrient: NutrientKey.energyKcal,
        blocksAutomaticUse: false,
      );
      final mealItem = PhotoMealItem(
        id: 'saved-item-1',
        name: 'Granola bowl',
        portion: MealPortion(85, MealUnit.grams),
        nutrients: NutrientProfile({
          NutrientKey.energyKcal: NutrientReported(340),
          NutrientKey.proteinG: NutrientMeasured(9.2),
          NutrientKey.fatG: NutrientEstimated(11.0, basis: 'label'),
          NutrientKey.saturatedFatG: const NutrientTrace(),
          NutrientKey.sodiumMg: const NutrientUnknown(),
        }),
        labelPaths: ['/labels/granola-1.jpg', '/labels/granola-2.jpg'],
        source: 'user-label',
        reviewIssues: const [issue],
      );
      await library.saveMeal((
        id: 'meal-1',
        name: 'Morning granola',
        items: [mealItem],
      ));

      final savedDoc = await docs.read('food-library');
      expect(savedDoc!.data['version'], 1);

      final loadedMeal = (await library.meals()).single;
      expect(loadedMeal.items.single.id, 'saved-item-1');
      expect(
        loadedMeal.items.single.labelPaths,
        ['/labels/granola-1.jpg', '/labels/granola-2.jpg'],
      );
      expect(loadedMeal.items.single.reviewIssues, [issue]);
      expect(
        loadedMeal.items.single.nutrients[NutrientKey.energyKcal],
        NutrientReported(340),
      );
      expect(
        loadedMeal.items.single.nutrients[NutrientKey.saturatedFatG],
        const NutrientTrace(),
      );

      // Legacy untagged food-library preserves nutrition JSON and unrelated keys.
      final legacyNutrients = <String, Object?>{
        'energy_kcal': {'state': 'reported', 'value': 250.0},
        'fiber_g': {'state': 'trace'},
      };
      await docs.put('food-library', savedDoc.revision, {
        'customLibraryFlag': true,
        'foods': [
          {
            'id': 'f1',
            'name': 'Oat bar',
            'barcode': '12345678',
            'amount': 50,
            'unit': 'grams',
            'nutrients': legacyNutrients,
          },
        ],
        'meals': [
          {
            'id': 'm-legacy',
            'name': 'Snack',
            'items': [
              {
                'name': 'Oat bar',
                'amount': 50,
                'unit': 'grams',
                'nutrients': legacyNutrients,
                'labelPath': '/labels/legacy.jpg',
              },
            ],
          },
        ],
        'favorites': ['bundled-fdc-173757'],
      });
      final loadedFoods = await library.foods();
      expect(loadedFoods.single.name, 'Oat bar');
      expect((await library.meals()).single.items.single.labelPaths,
          ['/labels/legacy.jpg']);
      expect(await library.favorites(), {'bundled-fdc-173757'});
      final migrated = await docs.read('food-library');
      expect(migrated!.data['version'], 1);
      expect(migrated.data['customLibraryFlag'], isTrue);
      expect(
        jsonEncode((migrated.data['foods'] as List).single['nutrients']),
        jsonEncode(legacyNutrients),
      );
    },
  );

  test(
    'WeekPlanStore and PlanningProfileStore tag version 1 and lazily migrate legacy SQLite docs',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final docs = LocalDocumentStore(db);
      final weekStore = WeekPlanStore(documents: docs);
      final profileStore = PlanningProfileStore(documents: docs);
      final monday = DateTime.utc(2026, 11, 16);
      final weekKey = 'week:2026-11-16';

      // Legacy untagged week doc in SQLite.
      await docs.put(weekKey, 0, {
        'unrelatedWeekNote': 'keep',
        'meals': [
          {
            'day': 0,
            'slot': 'dinner',
            'name': 'Risotto',
            'details': '1 serving',
          },
        ],
        'groceries': [
          {'name': 'Rice', 'amount': '200 g', 'checked': false},
        ],
      });
      final loadedWeek = await weekStore.load(monday);
      expect(loadedWeek.revision, 2);
      expect(
          loadedWeek.meals[(day: 0, slot: MealSlot.dinner)]?.name, 'Risotto');
      final migratedWeek = await docs.read(weekKey);
      expect(migratedWeek!.data['version'], 1);
      expect(migratedWeek.data['unrelatedWeekNote'], 'keep');

      // Subsequent save with updated revision succeeds.
      await weekStore.save(
        loadedWeek.copyWith(
          groceries: const [
            GroceryItem('Rice', amount: '200 g', checked: true),
          ],
        ),
      );
      expect(
        (await weekStore.load(monday)).groceries.single.checked,
        isTrue,
      );

      // Legacy untagged planning-profile in SQLite.
      await docs.put('planning-profile', 0, {
        'unrelatedProfileNote': 'stay',
        'startingWeight': 71.5,
        'weightUnit': 'kilograms',
        'onboarded': true,
      });
      final loadedProfile = await profileStore.load();
      expect(loadedProfile.startingWeight, 71.5);
      expect(loadedProfile.onboarded, isTrue);
      final migratedProfile = await docs.read('planning-profile');
      expect(migratedProfile!.data['version'], 1);
      expect(migratedProfile.data['unrelatedProfileNote'], 'stay');
    },
  );

  test(
    'future-version and malformed documents throw FormatException without overwriting source JSON',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final docs = LocalDocumentStore(db);
      final recipeLibrary = RecipeLibrary(const EmptyCatalogue(), docs);
      final batches = CookedBatches(docs);
      final foodLibrary = FoodLibrary(docs);
      final weekStore = WeekPlanStore(documents: docs);
      final profileStore = PlanningProfileStore(documents: docs);

      final futureRecipeDoc = <String, Object?>{
        'version': 99,
        'sentinel': 'untouched-recipe-lib',
        'recipes': <Object>[],
      };
      await docs.put('recipe-library', 0, futureRecipeDoc);
      await expectLater(recipeLibrary.load(), throwsFormatException);
      await expectLater(
        recipeLibrary.add(
          RecipeVersion(
            id: 'r',
            name: 'R',
            prepMinutes: 5,
            ingredients: [
              RecipeIngredient(
                food: Food(
                  id: 'f',
                  name: 'F',
                  per100g: const NutrientProfile.empty(),
                  source: const FoodSource(dataset: 't', datasetId: 'f'),
                ),
                edibleGrams: 100,
                purchaseName: 'F',
              ),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect((await docs.read('recipe-library'))!.data, futureRecipeDoc);

      final futureBatchesDoc = <String, Object?>{
        'version': 99,
        'sentinel': 'untouched-batches',
        'batches': <Object>[],
      };
      await docs.put('cooked-batches', 0, futureBatchesDoc);
      await expectLater(batches.available(), throwsFormatException);
      expect((await docs.read('cooked-batches'))!.data, futureBatchesDoc);

      final futureFoodDoc = <String, Object?>{
        'version': 99,
        'sentinel': 'untouched-food-lib',
        'foods': <Object>[],
        'meals': <Object>[],
      };
      await docs.put('food-library', 0, futureFoodDoc);
      await expectLater(foodLibrary.foods(), throwsFormatException);
      await expectLater(foodLibrary.meals(), throwsFormatException);
      await expectLater(foodLibrary.toggleFavorite('x'), throwsFormatException);
      expect((await docs.read('food-library'))!.data, futureFoodDoc);

      final malformedFoodDoc = <String, Object?>{
        'sentinel': 'untouched-malformed-food',
        'foods': [
          {
            'id': 'f1',
            'name': 'Bad',
            'amount': -10,
            'unit': 'grams',
            'nutrients': <String, Object?>{},
          },
        ],
      };
      await docs.put('food-library', 1, malformedFoodDoc);
      await expectLater(foodLibrary.foods(), throwsFormatException);
      expect((await docs.read('food-library'))!.data, malformedFoodDoc);

      final monday = DateTime.utc(2026, 11, 16);
      final futureWeekDoc = <String, Object?>{
        'version': 99,
        'sentinel': 'untouched-week',
        'meals': <Object>[],
        'groceries': <Object>[],
      };
      await docs.put('week:2026-11-16', 0, futureWeekDoc);
      await expectLater(weekStore.load(monday), throwsFormatException);
      await expectLater(
          weekStore.save(WeekPlan(monday)), throwsFormatException);
      expect((await docs.read('week:2026-11-16'))!.data, futureWeekDoc);

      final futureProfileDoc = <String, Object?>{
        'version': 99,
        'sentinel': 'untouched-profile',
        'onboarded': true,
      };
      await docs.put('planning-profile', 0, futureProfileDoc);
      await expectLater(profileStore.load(), throwsFormatException);
      await expectLater(
        profileStore.save(const PlanningProfile(startingWeight: 70)),
        throwsFormatException,
      );
      expect((await docs.read('planning-profile'))!.data, futureProfileDoc);
    },
  );
}
