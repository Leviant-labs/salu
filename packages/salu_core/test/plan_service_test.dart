import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food _food(String id, String name, double kcalPer100g, double proteinPer100g) =>
    Food(
      id: id,
      name: name,
      preparation: Preparation.cooked,
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(kcalPer100g),
        NutrientKey.proteinG: NutrientMeasured(proteinPer100g),
      }),
      source: const FoodSource(
        dataset: 'test',
        datasetId: '1',
      ),
    );

RecipeVersion _recipe({
  required String id,
  required String name,
  required List<RecipeIngredient> ingredients,
  int prepMinutes = 15,
  Set<String>? allergens,
}) =>
    RecipeVersion(
      id: id,
      name: name,
      prepMinutes: prepMinutes,
      ingredients: ingredients,
      allergens: allergens,
      allergenSource: allergens != null ? 'test' : null,
    );

void main() {
  const service = PlanService();
  final monday = startOfPlanWeek(DateTime(2026, 11, 21));

  test('toIntakeMealSlot converts explicitly without relying on enum index',
      () {
    expect(toIntakeMealSlot(PlanMealSlot.breakfast), MealSlot.breakfast);
    expect(toIntakeMealSlot(PlanMealSlot.lunch), MealSlot.lunch);
    expect(toIntakeMealSlot(PlanMealSlot.dinner), MealSlot.dinner);
  });

  test('dayTotals sums recipe nutrients for the requested day only', () {
    final oats = _food('oats', 'Oats', 380, 13);
    final lentils = _food('lentils', 'Lentils', 120, 9);
    final breakfast = _recipe(
      id: 'oats-bowl',
      name: 'Oats bowl',
      ingredients: [
        RecipeIngredient(
          food: oats,
          edibleGrams: 100,
          purchaseName: 'Dry oats',
          purchaseGrams: 100,
        ),
      ],
      allergens: const {},
    );
    final lunch = _recipe(
      id: 'lentil-bowl',
      name: 'Lentil bowl',
      ingredients: [
        RecipeIngredient(
          food: lentils,
          edibleGrams: 200,
          purchaseName: 'Cooked lentils',
          purchaseGrams: 200,
        ),
      ],
      allergens: const {},
    );
    final recipes = {breakfast.key: breakfast, lunch.key: lunch};
    final meals = <PlanMealPosition, PlannedMeal>{
      (day: 0, slot: PlanMealSlot.breakfast): PlannedMeal(
        breakfast.name,
        recipeKey: breakfast.key,
        servings: 1,
      ),
      (day: 0, slot: PlanMealSlot.lunch): PlannedMeal(
        lunch.name,
        recipeKey: lunch.key,
        servings: 1,
      ),
      (day: 1, slot: PlanMealSlot.breakfast): PlannedMeal(
        breakfast.name,
        recipeKey: breakfast.key,
        servings: 1,
      ),
    };

    final day0 = service.dayTotals(meals, 0, recipes);
    expect(day0[NutrientKey.energyKcal]!.amount, closeTo(620, 0.01));
    expect(day0[NutrientKey.proteinG]!.amount, closeTo(31, 0.01));

    final day1 = service.dayTotals(meals, 1, recipes);
    expect(day1[NutrientKey.energyKcal]!.amount, closeTo(380, 0.01));
  });

  test('reconcileGroceries preserves manual, overridden, and checked rows', () {
    final oats = _food('oats', 'Oats', 380, 13);
    final lentils = _food('lentils', 'Lentils', 120, 9);
    final breakfast = _recipe(
      id: 'oats-bowl',
      name: 'Oats bowl',
      ingredients: [
        RecipeIngredient(
          food: oats,
          edibleGrams: 50,
          purchaseName: 'Dry oats',
          purchaseGrams: 50,
        ),
      ],
      allergens: const {},
    );
    final lunch = _recipe(
      id: 'lentil-bowl',
      name: 'Lentil bowl',
      ingredients: [
        RecipeIngredient(
          food: lentils,
          edibleGrams: 100,
          purchaseName: 'Cooked lentils',
          purchaseGrams: 100,
        ),
      ],
      allergens: const {},
    );
    final recipes = {breakfast.key: breakfast, lunch.key: lunch};

    final initial = service.reconcileGroceries(
      WeekPlan(
        monday,
        meals: {
          (day: 0, slot: PlanMealSlot.breakfast): PlannedMeal(
            breakfast.name,
            recipeKey: breakfast.key,
            servings: 1,
          ),
          (day: 0, slot: PlanMealSlot.lunch): PlannedMeal(
            lunch.name,
            recipeKey: lunch.key,
            servings: 1,
          ),
        },
        groceries: const [GroceryItem('Coffee', amount: '1 bag')],
      ),
      recipes,
    );
    expect(initial.groceries.any((g) => g.name == 'Coffee'), isTrue);
    final oatsRow = initial.groceries.firstWhere((g) => g.name == 'Dry oats');
    final lentilsRow =
        initial.groceries.firstWhere((g) => g.name == 'Cooked lentils');

    // User checks oats, overrides lentils, and removes lunch from the plan.
    final edited = initial.copyWith(
      meals: {
        (day: 0, slot: PlanMealSlot.breakfast): PlannedMeal(
          breakfast.name,
          recipeKey: breakfast.key,
          servings: 2, // increased from 1 -> 2
        ),
      },
      groceries: [
        for (final item in initial.groceries)
          if (item.requirementKey == oatsRow.requirementKey)
            item.withChecked(true)
          else if (item.requirementKey == lentilsRow.requirementKey)
            GroceryItem(
              'Red lentils (custom)',
              amount: '2 bags',
              requirementKey: item.requirementKey,
              requiredGrams: item.requiredGrams,
              override: true,
            )
          else
            item,
      ],
    );

    final reconciled = service.reconcileGroceries(edited, recipes);
    expect(reconciled.groceries.any((g) => g.name == 'Coffee'), isTrue);
    final updatedOats =
        reconciled.groceries.firstWhere((g) => g.name == 'Dry oats');
    expect(updatedOats.checked, isTrue);
    expect(updatedOats.changed, isTrue);
    expect(updatedOats.amount, '100 g');
    // Overridden row for removed lunch is preserved as a manual row.
    expect(
      reconciled.groceries.any(
        (g) => g.name == 'Red lentils (custom)' && g.amount == '2 bags',
      ),
      isTrue,
    );
  });

  test('findPinnedConflicts detects strict allergens and exclusions', () {
    final milk = _food('milk', 'Milk', 60, 3);
    final yogurt = _recipe(
      id: 'yogurt',
      name: 'Yogurt bowl',
      ingredients: [
        RecipeIngredient(
          food: milk,
          edibleGrams: 150,
          purchaseName: 'Yogurt',
          purchaseGrams: 150,
        ),
      ],
      allergens: const {'milk'},
    );
    final recipes = {yogurt.key: yogurt};
    final plan = WeekPlan(
      monday,
      meals: {
        (day: 0, slot: PlanMealSlot.breakfast): PlannedMeal(
          yogurt.name,
          recipeKey: yogurt.key,
          servings: 1,
          pinned: true,
        ),
        (day: 0, slot: PlanMealSlot.lunch): const PlannedMeal(
          'Peanut noodles',
          details: 'Homemade',
          pinned: true,
        ),
        (day: 0, slot: PlanMealSlot.dinner): PlannedMeal(
          yogurt.name,
          recipeKey: yogurt.key,
          servings: 1,
          pinned: false,
        ),
      },
    );
    const profile = PlanningProfile(
      preferences: FoodPreferences(
        strictAllergens: 'milk',
        exclusions: 'peanut',
      ),
    );

    final conflicts = service.findPinnedConflicts(plan, recipes, profile);
    expect(conflicts, hasLength(2));
    expect(
      conflicts
          .firstWhere(
              (c) => c.position == (day: 0, slot: PlanMealSlot.breakfast))
          .reasons,
      contains('containsAllergen:milk'),
    );
    expect(
      conflicts
          .firstWhere((c) => c.position == (day: 0, slot: PlanMealSlot.lunch))
          .reasons,
      containsAll(['unknownAllergenStatus', 'excludedIngredient:peanut']),
    );
  });
}
