import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

RecipeVersion recipe(String id, {int minutes = 10, int energy = 500}) =>
    RecipeVersion(id: id, revision: 1, name: id, servings: Exact.one,
        minutes: minutes, allergens: {}, ingredients: [RecipeIngredient(
            Food(id: 'food-$id', name: id,
                source: FoodSource(dataset: 'test', datasetId: id),
                allergens: {}, per100g: NutrientProfile({
                  NutrientKey.energyKcal: NutrientReported(energy.toDouble())
                })), Exact.parse('100'))]);

void main() {
  const planner = PlannerService();
  const breakfast = MealSlot('2026-11-12:breakfast', '2026-11-12', 'breakfast');
  const lunch = MealSlot('2026-11-12:lunch', '2026-11-12', 'lunch');

  test('category candidates are hard in generation and validation', () {
    final oats = recipe('oats');
    final soup = recipe('soup');
    final context = PlannerContext(slots: [breakfast, lunch],
        recipes: [oats, soup], seed: 20261112,
        recipeIdsBySlot: {breakfast.id: {'oats'}, lunch.id: {'soup'}});
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.map((meal) => meal.recipe.id), ['oats', 'soup']);
    expect(planner.validate([
      PlannedMeal(breakfast, soup, Exact.one),
      PlannedMeal(lunch, oats, Exact.one)
    ], context), contains('MEAL_SLOT_RECIPE_CONFLICT'));
  });

  test('explicitly empty slot candidates cannot fall back to all recipes', () {
    final context = PlannerContext(slots: [breakfast],
        recipes: [recipe('soup')], seed: 1,
        recipeIdsBySlot: {breakfast.id: {}});
    expect(planner.plan(context).status, PlannerStatus.provenInfeasible);
  });

  test('soft target prefers closest meal without a calorie access band', () {
    final context = PlannerContext(slots: [breakfast],
        recipes: [recipe('far', energy: 100), recipe('near', energy: 490)],
        seed: 1, targetGoals: {NutrientKey.energyKcal: Exact.parse('500')});
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.single.recipe.id, 'near');
    expect(planner.validate(result.meals, context), isEmpty);
  });

  test('accepted time relaxation retains category restrictions and soft goals', () {
    final oats = recipe('oats', minutes: 20);
    final soup = recipe('soup', minutes: 5);
    final context = PlannerContext(slots: [breakfast],
        recipes: [oats, soup], seed: 1, maximumMinutes: 10,
        recipeIdsBySlot: {breakfast.id: {'oats'}},
        targetGoals: {NutrientKey.energyKcal: Exact.parse('510')},
        recipePreferenceRanks: {'oats': 2, 'soup': 0});
    final repair = planner.repair(context, []);
    final relaxation = repair.relaxations.firstWhere(
        (change) => change.kind == PlannerRelaxationKind.maximumMinutes);
    final accepted = planner.acceptRelaxation(context, relaxation,
        confirmed: true, expectedRevision: 1);
    expect(accepted.result.meals.single.recipe.id, 'oats');
    expect(planner.validate([PlannedMeal(breakfast, soup, Exact.one)],
        accepted.context), contains('MEAL_SLOT_RECIPE_CONFLICT'));
    expect(accepted.context.targetGoals[NutrientKey.energyKcal], Exact.parse('510'));
    expect(accepted.context.recipePreferenceRanks['oats'], 2);
  });
}
