import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  final recipe = RecipeVersion(
      id: 'soup',
      revision: 1,
      name: 'Soup',
      servings: Exact.parse('3'),
      minutes: 30,
      allergens: {},
      ingredients: [
        RecipeIngredient(
            Food(
                id: 'beans',
                name: 'Beans',
                per100g: NutrientProfile({}),
                source: const FoodSource(dataset: 'test', datasetId: 'beans'),
                allergens: {}),
            Exact.parse('300'))
      ]);
  final batch = CookedBatch(
      id: 'batch',
      recipe: recipe,
      revision: 2,
      available: Exact.parse('600'),
      unit: FoodUnit.g,
      finishedWeightG: Exact.parse('600'),
      allocations: [
        BatchAllocation('other-week', Exact.parse('200'), 'planned'),
        BatchAllocation('existing', Exact.parse('200'), 'planned')
      ]);
  const first = MealSlot('first', '2026-01-01', 'Dinner');
  const second = MealSlot('second', '2026-01-02', 'Dinner');
  final context = PlannerContext(
      slots: [first, second],
      recipes: [recipe],
      portions: [Exact.one],
      batches: [batch],
      seed: 1);
  PlannedMeal meal(MealSlot slot, String allocation, {int revision = 2}) =>
      PlannedMeal(slot, recipe, Exact.one,
          pinned: true,
          batchUse: PlannedBatchUse('batch', revision, allocation));
  const planner = PlannerService();

  test('existing cross-week reservation is counted once', () {
    final meals = [meal(first, 'existing'), meal(second, 'new')];
    expect(planner.validate(meals, context), isEmpty);
    expect(planner.repair(context, meals).status, PlannerStatus.validPlan);
  });
  test('cannot reserve stock already used across weeks', () {
    final meals = [meal(first, 'new-a'), meal(second, 'new-b')];
    expect(planner.validate(meals, context), contains('BATCH_STOCK_EXCEEDED'));
    expect(planner.repair(context, meals).status, PlannerStatus.targetConflict);
  });
  test('stale stock and duplicated allocation cannot become valid plans', () {
    expect(
        planner.validate(
            [meal(first, 'existing', revision: 1), meal(second, 'new')],
            context),
        contains('BATCH_REVISION_MISMATCH'));
    expect(
        planner.validate(
            [meal(first, 'existing'), meal(second, 'existing')], context),
        contains('DUPLICATE_BATCH_USE'));
  });
  test('repair never drops a pin when a slot has disappeared', () {
    const removed = MealSlot('removed', '2026-01-03', 'Dinner');
    final result = planner.repair(context, [meal(removed, 'existing')]);
    expect(result.status, PlannerStatus.targetConflict);
    expect(result.meals, isEmpty);
  });
  test('repair refuses a duplicated slot containing a pin', () {
    final unpinned = PlannedMeal(first, recipe, Exact.one);
    final result = planner.repair(context, [unpinned, meal(first, 'existing')]);
    expect(result.status, PlannerStatus.targetConflict);
    expect(result.meals, isEmpty);
  });
}
