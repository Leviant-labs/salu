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
        BatchAllocation('existing', Exact.parse('200'), 'planned'),
        BatchAllocation('new', Exact.parse('200'), 'planned')
      ]);
  const first = MealSlot('first', '2026-01-01', 'Dinner');
  const second = MealSlot('second', '2026-01-02', 'Dinner');
  final context = PlannerContext(
      slots: [first, second],
      recipes: [recipe],
      portions: [Exact.one],
      batches: [batch],
      seed: 1);
  PlannedMeal meal(MealSlot slot, String allocation,
          {int revision = 2, Exact? portions, bool pinned = true}) =>
      PlannedMeal(slot, recipe, portions ?? Exact.one,
          pinned: pinned,
          batchUse: PlannedBatchUse('batch', revision, allocation));
  const planner = PlannerService();

  test('existing cross-week reservation is counted once', () {
    final meals = [meal(first, 'existing'), meal(second, 'new')];
    expect(planner.validate(meals, context), isEmpty);
    expect(planner.repair(context, meals).status, PlannerStatus.validPlan);
  });
  test('later reservations do not invalidate an older recorded revision', () {
    final meals = [meal(first, 'existing', revision: 1), meal(second, 'new')];
    expect(planner.validate(meals, context), isEmpty);
    expect(planner.repair(context, meals).status, PlannerStatus.validPlan);
  });
  test('a recorded revision from the future is rejected', () {
    expect(
        planner.validate(
            [meal(first, 'existing', revision: 3), meal(second, 'new')],
            context),
        contains('BATCH_REVISION_MISMATCH'));
  });
  test('duplicated and missing allocations cannot become valid plans', () {
    expect(
        planner.validate(
            [meal(first, 'existing'), meal(second, 'existing')], context),
        contains('DUPLICATE_BATCH_USE'));
    final missing = planner.validate(
        [meal(first, 'existing'), meal(second, 'absent')], context);
    expect(missing, contains('BATCH_ALLOCATION_MISSING'));
    expect(missing, contains('BATCH_STOCK_EXCEEDED'));
  });
  test('cannot reserve stock already used across weeks', () {
    final meals = [meal(first, 'new-a'), meal(second, 'new-b')];
    final errors = planner.validate(meals, context);
    expect(errors, contains('BATCH_ALLOCATION_MISSING'));
    expect(errors, contains('BATCH_STOCK_EXCEEDED'));
    expect(planner.repair(context, meals).status, PlannerStatus.targetConflict);
  });
  test('a consumed reservation is accounted once, not re-reserved', () {
    final cooked = CookedBatch(
        id: 'cooked',
        recipe: recipe,
        revision: 4,
        available: Exact.parse('600'),
        unit: FoodUnit.g,
        finishedWeightG: Exact.parse('600'),
        allocations: [
          BatchAllocation('plan-1', Exact.parse('400'),
              BatchAllocation.consumedStatus,
              intakeRequestId: 'intake-1'),
          BatchAllocation('plan-2', Exact.parse('200'),
              BatchAllocation.plannedStatus)
        ]);
    final cookedContext = PlannerContext(
        slots: [first, second],
        recipes: [recipe],
        portions: [Exact.one, Exact.parse('2')],
        batches: [cooked],
        seed: 1);
    final meals = [
      PlannedMeal(first, recipe, Exact.parse('2'),
          pinned: true,
          batchUse: PlannedBatchUse('cooked', 4, 'plan-1')),
      PlannedMeal(second, recipe, Exact.one,
          pinned: true,
          batchUse: PlannedBatchUse('cooked', 4, 'plan-2'))
    ];
    expect(planner.validate(meals, cookedContext), isEmpty);
    expect(cooked.allocated, Exact.parse('600'));
    expect(cooked.consumedAllocated, Exact.parse('400'));
    expect(cooked.plannedAllocated, Exact.parse('200'));
    expect(
        planner.repair(cookedContext, meals).status, PlannerStatus.validPlan);
  });
  test('legacy re-keyed consumption is not silently double counted', () {
    final legacy = CookedBatch(
        id: 'legacy',
        recipe: recipe,
        revision: 3,
        available: Exact.parse('600'),
        unit: FoodUnit.g,
        finishedWeightG: Exact.parse('600'),
        allocations: [
          BatchAllocation('intake-1', Exact.parse('400'),
              BatchAllocation.consumedStatus,
              intakeRequestId: 'intake-1')
        ]);
    final legacyContext = PlannerContext(
        slots: [first],
        recipes: [recipe],
        portions: [Exact.parse('2')],
        batches: [legacy],
        seed: 1);
    final errors = planner.validate([
      PlannedMeal(first, recipe, Exact.parse('2'),
          pinned: true,
          batchUse: PlannedBatchUse('legacy', 3, 'plan-1'))
    ], legacyContext);
    expect(errors, contains('BATCH_ALLOCATION_MISSING'));
    expect(errors, contains('BATCH_STOCK_EXCEEDED'));
  });
  test('groceries exclude cooked batch uses by default', () {
    final stocked = [meal(first, 'existing')];
    expect(groceriesFor(stocked), isEmpty);
    final purchased = groceriesFor(stocked, includeStockedMeals: true);
    expect(purchased.single.foodId, 'beans');
    expect(purchased.single.grams, Exact.parse('100'));
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
  test('consumed allocation identity survives a later batch revision', () {
    final consumed = CookedBatch(
        id: 'batch',
        recipe: recipe,
        revision: 5,
        available: Exact.parse('600'),
        unit: FoodUnit.g,
        finishedWeightG: Exact.parse('600'),
        allocations: [
          BatchAllocation('existing', Exact.parse('200'),
              BatchAllocation.consumedStatus,
              intakeRequestId: 'intake-9'),
          BatchAllocation('new', Exact.parse('200'), 'planned')
        ]);
    final later = consumed.allocate(
        BatchAllocation('later', Exact.parse('200'), 'planned'),
        expectedRevision: 5);
    expect(later.allocation('existing')!.status, 'consumed');
    expect(later.allocation('existing')!.intakeRequestId, 'intake-9');
    expect(later.revision, 6);
    expect(later.consumedAllocated, Exact.parse('200'));
  });
  test('intake request linkage is consumed-only and unique', () {
    expect(
        () => BatchAllocation('p', Exact.parse('10'), 'planned',
            intakeRequestId: 'intake-1'),
        throwsArgumentError);
    expect(
        () => CookedBatch(
            id: 'b',
            recipe: recipe,
            revision: 1,
            available: Exact.parse('100'),
            unit: FoodUnit.g,
            finishedWeightG: Exact.parse('100'),
            allocations: [
              BatchAllocation('a', Exact.parse('10'), 'consumed',
                  intakeRequestId: 'intake-1'),
              BatchAllocation('b', Exact.parse('10'), 'consumed',
                  intakeRequestId: 'intake-1')
            ]),
        throwsStateError);
    final legacy = BatchAllocation(
        'intake-legacy', Exact.parse('10'), 'consumed');
    expect(legacy.intakeRequestId, isNull);
  });
}
