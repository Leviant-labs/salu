import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  testWidgets(
      'schedule, exact portions and constraints persist as one reviewed revision without intake',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup', minutes: 20));
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scheduleDaysField')), '3');
    await tester.enterText(find.byKey(const Key('scheduleLabelField')), 'lunch');
    await tester.enterText(find.byKey(const Key('portionInputField')), '1.5');
    await tester.ensureVisible(find.byTooltip('Add portion'));
    await tester.tap(find.byTooltip('Add portion'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('scheduleMaxMinutesField')), '30');
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();

    var pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    final schedule = asMap(pending.data['schedule']);
    final constraints = asMap(pending.data['constraints']);
    expect(schedule['days'], 3);
    expect(schedule['label'], 'lunch');
    expect(schedule['portions'], hasLength(2));
    expect(constraints['maximumMinutes'], 30);
    expect(pending.data['constraintRevision'], 2);
    // The plan document is not rewritten with inputs no plan was generated
    // under; the pending revision is persisted separately.
    expect(await loadPlan(db), isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);

    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(3));
    expect(stored.meals.map((m) => m.slot.label).toSet(), {'lunch'});
    expect(stored.meals.map((m) => m.slot.date).toSet(), hasLength(3));
    expect(asMap(stored.document['schedule'])['days'], 3);
    expect(asMap(stored.document['constraints'])['maximumMinutes'], 30);
    expect(stored.document['constraintRevision'], 2);
    pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(pending.data['constraintRevision'], 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'strict exclusions and unknown allergen status block planning with no relaxation offered',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(
        db,
        planRecipe(
            id: 'milky',
            name: 'Milky',
            ingredients: [
              RecipeIngredient(planFood('milk', allergens: {'milk'}),
                  Exact.parse('100'))
            ]));
    await seedRecipe(
        db,
        planRecipe(
            id: 'mystery',
            name: 'Mystery',
            ingredients: [
              RecipeIngredient(planFood('mystery', allergens: null),
                  Exact.parse('100'))
            ]));
    await seedSafety(db, {'milk'});
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Strict exclusions from your safety declarations'),
        findsOneWidget);
    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No combination'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
    expect(await loadPlan(db), isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('pin survives a shorter schedule repair and intake stays empty',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    await seedRecipe(db, planRecipe(id: 'stew', name: 'Stew'));
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    expect((await loadPlan(db))!.meals, hasLength(7));

    await tester.tap(find.byTooltip('Pin meal').first);
    await tester.pumpAndSettle();
    final pinned = (await loadPlan(db))!.meals.firstWhere((m) => m.pinned);
    expect(find.byTooltip('Unpin meal'), findsOneWidget);

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scheduleDaysField')), '5');
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();

    final repaired = (await loadPlan(db))!;
    expect(repaired.meals, hasLength(5));
    final kept = repaired.meals.where((m) => m.pinned).toList();
    expect(kept, hasLength(1));
    expect(kept.single.slot.date, pinned.slot.date);
    expect(kept.single.recipe.name, pinned.recipe.name);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'failed repair proposes a reviewed relaxation and applies only after confirmation',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup', minutes: 30));
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scheduleDaysField')), '2');
    await tester.enterText(
        find.byKey(const Key('scheduleMaxMinutesField')), '10');
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db)
                .read('preferences', 'planner'))!
            .data['constraintRevision'],
        2);
    expect(await loadPlan(db), isNull);

    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    expect(find.text('No plan was installed'), findsOneWidget);
    expect(find.text('Allow recipes up to 30 minutes'), findsOneWidget);
    expect(await loadPlan(db), isNull);

    // Declining the confirmation changes nothing.
    await tester.ensureVisible(find.text('Review').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review').first);
    await tester.pumpAndSettle();
    expect(find.text('Apply this reviewed change?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await loadPlan(db), isNull);
    expect(
        (await LocalWorkspace(db)
                .read('preferences', 'planner'))!
            .data['constraintRevision'],
        2);

    await tester.ensureVisible(find.text('Review').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review').first);
    await tester.pumpAndSettle();
    expect(find.text('Apply this reviewed change?'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(2));
    expect(asMap(stored.document['constraints'])['maximumMinutes'], 30);
    expect(stored.document['constraintRevision'], 3);
    expect(asMaps(stored.document['acceptedRelaxations']), hasLength(1));
    expect(asMaps(stored.document['relaxations']), hasLength(1));
    expect(asMaps(stored.document['acceptedRelaxations']).single['baseRevision'],
        2);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // A fresh screen rebuilds the context from the accepted relaxation history
    // and does not need to propose the same change again.
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Maximum cooking time: 30'), findsOneWidget);
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    expect((await loadPlan(db))!.meals, hasLength(2));
    expect(find.text('No plan was installed'), findsNothing);
  });

  testWidgets(
      'a pin conflicting with a strict exclusion is a conflict, never a relaxation',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final milky = planRecipe(
        id: 'milky',
        name: 'Milky',
        ingredients: [
          RecipeIngredient(
              planFood('milk', allergens: {'milk'}), Exact.parse('100'))
        ]);
    await seedRecipe(db, milky);
    await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'), milky,
          Exact.one,
          pinned: true)
    ], startDate: '2026-01-01');
    // Declare the exclusion only after the plan exists: the commitment service
    // now refuses to write meals that violate the persisted safety profile.
    await seedSafety(db, {'milk'});
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A hard constraint conflicts'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
    final plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.meals.single.pinned, true);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'a first meal can be removed as an exclusion without moving retained meals, pins, dates or portions',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    const first = MealSlot('dinner:0', '2026-01-01', 'dinner');
    const pinned = MealSlot('dinner:1', '2026-01-02', 'dinner');
    const last = MealSlot('dinner:2', '2026-01-03', 'dinner');
    await seedPlan(db, meals: [
      PlannedMeal(first, recipe, Exact.one),
      PlannedMeal(pinned, recipe, Exact.one, pinned: true),
      PlannedMeal(last, recipe, Exact.parse('1.5'))
    ], startDate: '2026-01-01', days: 3, portions: const ['1', '1.5']);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Meal options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from plan'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this planned meal?'), findsOneWidget);
    expect(find.textContaining('2026-01-01 will be excluded'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(2));
    expect(stored.meals.map((m) => m.slot.id), ['dinner:1', 'dinner:2']);
    expect(stored.meals.map((m) => m.slot.date),
        ['2026-01-02', '2026-01-03']);
    expect(stored.meals.last.portions, Exact.parse('1.5'));
    final keptPin = stored.meals.where((m) => m.pinned).single;
    expect(keptPin.slot.id, 'dinner:1');
    expect(keptPin.slot.date, '2026-01-02');
    final schedule = asMap(stored.document['schedule']);
    expect(schedule['startDate'], '2026-01-01');
    expect(schedule['days'], 3);
    expect(schedule['excludedSlotIds'], ['dinner:0']);
    expect(stored.document['constraintRevision'], 2);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // A reload rebuilds the same effective slots from the persisted exclusion.
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    // The plan card grew with the hard-constraint summary, so the second meal
    // card may not be built until the list is scrolled. The stored model above
    // already proves dates and the pin; this scroll proves the reload renders
    // both retained meals without moving them.
    final planList = find.byType(Scrollable).last;
    expect(find.textContaining('2026-01-02 · dinner ·'), findsOneWidget);
    expect(
        find.textContaining(
            'Excluded days (no meal is planned): 2026-01-01'),
        findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('2026-01-03 · dinner ·'), 200,
        scrollable: planList);
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-01-01 · dinner ·'), findsNothing);
    expect(find.textContaining('2026-01-03 · dinner ·'), findsOneWidget);
    expect(find.byTooltip('Meal options'), findsNWidgets(2));
    await tester.scrollUntilVisible(find.text('Repair plan'), -200,
        scrollable: planList);
    await tester.pumpAndSettle();

    // Repair is stable: it never re-adds the removed day or moves a retained
    // meal, and it still writes no intake.
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    final repaired = (await loadPlan(db))!;
    expect(repaired.meals, hasLength(2));
    expect(repaired.meals.map((m) => m.slot.date),
        ['2026-01-02', '2026-01-03']);
    expect(asMap(repaired.document['schedule'])['excludedSlotIds'],
        ['dinner:0']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'a pinned middle meal can be removed with confirmation while every other day stays fixed',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    const first = MealSlot('dinner:0', '2026-01-01', 'dinner');
    const pinned = MealSlot('dinner:1', '2026-01-02', 'dinner');
    const last = MealSlot('dinner:2', '2026-01-03', 'dinner');
    await seedPlan(db, meals: [
      PlannedMeal(first, recipe, Exact.one),
      PlannedMeal(pinned, recipe, Exact.one, pinned: true),
      PlannedMeal(last, recipe, Exact.one)
    ], startDate: '2026-01-01', days: 3);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Meal options').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This pinned meal will be removed'),
        findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(2));
    expect(stored.meals.map((m) => m.slot.id), ['dinner:0', 'dinner:2']);
    expect(stored.meals.map((m) => m.slot.date),
        ['2026-01-01', '2026-01-03']);
    expect(stored.meals.any((m) => m.pinned), isFalse);
    expect(asMap(stored.document['schedule'])['excludedSlotIds'],
        ['dinner:1']);
    expect(asMap(stored.document['schedule'])['days'], 3);
    expect(stored.document['constraintRevision'], 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'the last active meal can be removed without shrinking or moving the schedule',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    const only = MealSlot('dinner:0', '2026-01-01', 'dinner');
    await seedPlan(db, meals: [PlannedMeal(only, recipe, Exact.one)]);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Meal options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('last active day'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    expect(stored.meals, isEmpty);
    final schedule = asMap(stored.document['schedule']);
    expect(schedule['startDate'], '2026-01-01');
    expect(schedule['days'], 1);
    expect(schedule['excludedSlotIds'], ['dinner:0']);
    expect(stored.document['constraintRevision'], 2);
    expect(
        find.textContaining(
            'Every day in the current schedule is excluded'),
        findsOneWidget);
    expect(find.textContaining('All days are excluded'), findsWidgets);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // No fake slot and no silent write: an empty schedule cannot generate one.
    await tester.tap(find.text('Build plan'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect((await loadPlan(db))!.meals, isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // A reload keeps the empty effective schedule explicit.
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Every day in the current schedule is excluded'),
        findsOneWidget);
    expect(find.textContaining('Excluded days (no meal is planned): 2026-01-01'),
        findsOneWidget);
  });

  testWidgets(
      'a legacy plan without exclusions loads unchanged and pins without a revision bump',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'), recipe, Exact.one)
    ]);
    final stored = (await LocalWorkspace(db).read('plan', 'current'))!;
    final data = Map<String, Object?>.from(stored.data);
    final schedule = asMap(data['schedule'])..remove('excludedSlotIds');
    data['schedule'] = schedule;
    // A plan written before unavailable ingredients existed has no key at all;
    // absence means none and never fabricates an inventory.
    final constraints = asMap(data['constraints'])
      ..remove('unavailableFoodIds');
    data['constraints'] = constraints;
    await LocalWorkspace(db).put(
        requestId: 'test:legacy-plan',
        collection: 'plan',
        id: 'current',
        expectedRevision: stored.revision,
        data: data);

    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-01-01 · dinner ·'), findsOneWidget);
    expect(find.textContaining('No ingredients are marked unavailable'),
        findsOneWidget);

    await tester.tap(find.byTooltip('Pin meal').first);
    await tester.pumpAndSettle();
    final loaded = (await loadPlan(db))!;
    expect(loaded.meals.single.pinned, isTrue);
    expect(loaded.document['constraintRevision'], 1);
    expect(asMap(loaded.document['schedule'])['excludedSlotIds'], isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'invalid persisted exclusions fail closed instead of restoring a day',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'), recipe, Exact.one),
      PlannedMeal(
          const MealSlot('dinner:1', '2026-01-02', 'dinner'), recipe, Exact.one)
    ], startDate: '2026-01-01', days: 2);
    final stored = (await LocalWorkspace(db).read('plan', 'current'))!;
    final data = Map<String, Object?>.from(stored.data);
    final schedule = asMap(data['schedule']);
    schedule['excludedSlotIds'] = ['dinner:7'];
    data['schedule'] = schedule;
    await LocalWorkspace(db).put(
        requestId: 'test:invalid-plan',
        collection: 'plan',
        id: 'current',
        expectedRevision: stored.revision,
        data: data);

    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('excluded plan slots are invalid'),
        findsOneWidget);
    expect(find.byTooltip('Meal options'), findsNothing);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('a consumed reservation is never removed or moved by meal removal',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    await seedBatch(db,
        id: 'batch-1',
        recipe: recipe,
        allocations: [planAllocation('plan-1', '300', 'planned')]);
    const first = MealSlot('dinner:0', '2026-01-01', 'dinner');
    const last = MealSlot('dinner:1', '2026-01-02', 'dinner');
    await seedPlan(db, meals: [
      PlannedMeal(first, recipe, Exact.one),
      PlannedMeal(last, recipe, Exact.one,
          batchUse: PlannedBatchUse('batch-1', 1, 'plan-1'))
    ], startDate: '2026-01-01', days: 2);
    await BatchService(db, const SystemClock(), RandomIdGenerator())
        .consumeAmount(
            requestId: 'intake-1',
            batchId: 'batch-1',
            expectedRevision: 1,
            amount: Exact.parse('300'),
            unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'plan-1');
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('recorded as consumed'), findsOneWidget);

    await tester.tap(find.byTooltip('Meal options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('consumed stock history'),
        findsOneWidget);
    expect((await loadPlan(db))!.meals, hasLength(2));
    final batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    final allocation = asMaps(batch.data['allocations']).single;
    expect(allocation['status'], 'consumed');
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });

  testWidgets(
      'removing a meal releases only that meal\'s unconsumed reservation',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    await seedBatch(db,
        id: 'batch-1',
        recipe: recipe,
        allocations: [
          planAllocation('plan-0', '300', 'planned'),
          planAllocation('plan-1', '300', 'planned')
        ]);
    const first = MealSlot('dinner:0', '2026-01-01', 'dinner');
    const last = MealSlot('dinner:1', '2026-01-02', 'dinner');
    await seedPlan(db, meals: [
      PlannedMeal(first, recipe, Exact.one,
          batchUse: PlannedBatchUse('batch-1', 1, 'plan-0')),
      PlannedMeal(last, recipe, Exact.one,
          batchUse: PlannedBatchUse('batch-1', 1, 'plan-1'))
    ], startDate: '2026-01-01', days: 2);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Meal options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(1));
    expect(stored.meals.single.slot.id, 'dinner:1');
    expect(stored.meals.single.slot.date, '2026-01-02');
    expect(stored.meals.single.batchUse!.allocationId, 'plan-1');
    expect(stored.meals.single.batchUse!.batchRevision, 2);
    final batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    final allocations = asMaps(batch.data['allocations']);
    expect(allocations.map((a) => a['id']), ['plan-1']);
    expect(allocations.single['status'], 'planned');
    expect(asMap(stored.document['schedule'])['excludedSlotIds'],
        ['dinner:0']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'a meal whose reservation was already released can be removed to recover',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    await seedBatch(db,
        id: 'batch-1',
        recipe: recipe,
        allocations: [planAllocation('plan-1', '300', 'planned')]);
    const first = MealSlot('dinner:0', '2026-01-01', 'dinner');
    const last = MealSlot('dinner:1', '2026-01-02', 'dinner');
    await seedPlan(db, meals: [
      PlannedMeal(first, recipe, Exact.one),
      PlannedMeal(last, recipe, Exact.one,
          batchUse: PlannedBatchUse('batch-1', 1, 'plan-1'))
    ], startDate: '2026-01-01', days: 2);
    await BatchService(db, const SystemClock(), RandomIdGenerator())
        .releaseReservation(
            requestId: 'manual-release',
            batchId: 'batch-1',
            allocationId: 'plan-1',
            expectedRevision: 1);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Reserved batch stock is no longer available'),
        findsOneWidget);

    await tester.tap(find.byTooltip('Meal options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(1));
    expect(stored.meals.single.slot.id, 'dinner:0');
    expect(asMap(stored.document['schedule'])['excludedSlotIds'],
        ['dinner:1']);
    final batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    expect(asMaps(batch.data['allocations']), isEmpty);
    expect(batch.revision, 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'restoring excluded days is a reviewed revision that keeps retained meals fixed',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    const first = MealSlot('dinner:0', '2026-01-01', 'dinner');
    const last = MealSlot('dinner:2', '2026-01-03', 'dinner');
    await seedPlan(db, meals: [
      PlannedMeal(first, recipe, Exact.one),
      PlannedMeal(last, recipe, Exact.one)
    ], startDate: '2026-01-01', days: 3, excludedSlotIds: const ['dinner:1']);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Excluded days (no meal is planned): 2026-01-02'),
        findsOneWidget);

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restoreExcludedDays')), findsOneWidget);
    expect(find.textContaining('2026-01-02'), findsWidgets);
    // This control sits below the energy fields inside the dialog's scroll
    // view; scroll it into view before tapping so the tap cannot miss.
    await tester.ensureVisible(find.byKey(const Key('restoreExcludedDays')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restoreExcludedDays')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('restoreExcludedDays')))
            .value,
        isTrue);
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();

    // The restored exclusion set is a pending reviewed revision, not a silent
    // rewrite of the applied plan or of any retained meal.
    final pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(asMap(pending.data['schedule'])['excludedSlotIds'], isEmpty);
    expect(pending.data['constraintRevision'], 2);
    expect((await loadPlan(db))!.meals, hasLength(2));
    expect((await loadPlan(db))!.document['constraintRevision'], 1);

    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    final repaired = (await loadPlan(db))!;
    expect(repaired.meals, hasLength(3));
    expect(repaired.meals.map((m) => m.slot.date),
        ['2026-01-01', '2026-01-02', '2026-01-03']);
    expect(repaired.meals.first.recipe.name, 'Soup');
    expect(asMap(repaired.document['schedule'])['excludedSlotIds'], isEmpty);
    expect(repaired.document['constraintRevision'], 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'changing the meal label restores stale exclusions only after review',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'), recipe, Exact.one)
    ], startDate: '2026-01-01', days: 2, excludedSlotIds: const ['dinner:1']);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('scheduleLabelField')), 'lunch');
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    expect(find.text('Restore excluded days with this schedule change?'),
        findsOneWidget);
    // Declining keeps the editor open and writes nothing. Dismiss the
    // confirmation barrier (the editor dialog stays behind it).
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(await LocalWorkspace(db).read('preferences', 'planner'), isNull);

    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    final schedule = asMap(pending.data['schedule']);
    expect(schedule['label'], 'lunch');
    expect(schedule['days'], 2);
    expect(schedule['excludedSlotIds'], isEmpty);
    expect(pending.data['constraintRevision'], 2);

    // Repair rebuilds slots under the reviewed label; the old meal is not
    // silently moved and no intake is written.
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    final repaired = (await loadPlan(db))!;
    expect(repaired.meals, hasLength(2));
    expect(repaired.meals.map((m) => m.slot.label).toSet(), {'lunch'});
    expect(repaired.meals.map((m) => m.slot.date),
        ['2026-01-01', '2026-01-02']);
    expect(repaired.document['constraintRevision'], 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'selecting an unavailable ingredient stops its recipe and persists the reviewed revision',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(
        db,
        planRecipe(
            id: 'bean-soup',
            name: 'Bean soup',
            ingredients: [
              RecipeIngredient(
                  planFood('beans', name: 'Beans'), Exact.parse('300'))
            ]));
    await seedRecipe(
        db,
        planRecipe(
            id: 'rice-stew',
            name: 'Rice stew',
            ingredients: [
              RecipeIngredient(
                  planFood('rice', name: 'Rice'), Exact.parse('300'))
            ]));
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No ingredients are marked unavailable'),
        findsOneWidget);

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not a pantry inventory'), findsOneWidget);
    // Only actual recipe ingredients are reviewable; nothing is inferred.
    expect(find.byKey(const Key('unavailableFood:custom:beans')),
        findsOneWidget);
    expect(find.byKey(const Key('unavailableFood:custom:rice')),
        findsOneWidget);
    expect(find.byKey(const Key('unavailableFood:custom:pantry')),
        findsNothing);
    await tester.ensureVisible(
        find.byKey(const Key('unavailableFood:custom:beans')));
    await tester.pumpAndSettle();
    // The checkbox exposes the ingredient name and checked state to assistive
    // technology through the standard list-tile semantics.
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('Beans')), findsWidgets);
    semantics.dispose();
    await tester.tap(find.byKey(const Key('unavailableFood:custom:beans')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('unavailableFood:custom:beans')))
            .value,
        isTrue);
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();

    final pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(asMap(pending.data['constraints'])['unavailableFoodIds'],
        ['custom:beans']);
    expect(pending.data['constraintRevision'], 2);
    // Saving inputs is not a plan write and never creates intake.
    expect(await loadPlan(db), isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);

    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    final stored = (await loadPlan(db))!;
    expect(stored.meals, isNotEmpty);
    expect(stored.meals.map((m) => m.recipe.id).toSet(), {'rice-stew'});
    expect(asMap(stored.document['constraints'])['unavailableFoodIds'],
        ['custom:beans']);
    expect(stored.document['constraintRevision'], 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'a pinned meal cannot bypass an unavailable ingredient and clearing it enables repair',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final soup = planRecipe(
        id: 'bean-soup',
        name: 'Bean soup',
        ingredients: [
          RecipeIngredient(planFood('beans', name: 'Beans'), Exact.parse('300'))
        ]);
    await seedRecipe(db, soup);
    await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'), soup,
          Exact.one,
          pinned: true)
    ]);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const Key('unavailableFood:custom:beans')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unavailableFood:custom:beans')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db)
                .read('preferences', 'planner'))!
            .data['constraintRevision'],
        2);

    // The pinned meal contains the ingredient now declared unavailable. It is
    // a hard conflict, never an automatic substitution or relaxation.
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A hard constraint conflicts'), findsOneWidget);
    expect(find.text('Review'), findsNothing);
    var plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.meals.single.pinned, isTrue);
    expect(plan.document['constraintRevision'], 1);
    expect(asMap(plan.document['constraints'])['unavailableFoodIds'], isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // Clearing the selection is another reviewed revision; only then can the
    // repair commit the same pinned meal under the applied constraints.
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const Key('unavailableFood:custom:beans')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unavailableFood:custom:beans')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    final cleared =
        (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(asMap(cleared.data['constraints'])['unavailableFoodIds'], isEmpty);
    expect(cleared.data['constraintRevision'], 3);

    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.meals.single.pinned, isTrue);
    expect(plan.document['constraintRevision'], 3);
    expect(asMap(plan.document['constraints'])['unavailableFoodIds'], isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'a selected unavailable id missing from current recipes survives reload and repair',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final soup = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, soup);
    await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'), soup,
          Exact.one)
    ], unavailableFoodIds: ['custom:retired-food']);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Unavailable ingredients (hard constraint'),
        findsOneWidget);
    expect(find.textContaining('custom:retired-food'), findsOneWidget);

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    final missing = find.byKey(
        const Key('unavailableFood:custom:retired-food'));
    expect(missing, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(missing).value, isTrue);
    expect(find.textContaining('Not in the current recipe catalogue'),
        findsOneWidget);
    // An unrelated schedule change keeps the selected id in the new revision.
    await tester.enterText(find.byKey(const Key('scheduleDaysField')), '2');
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    final pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(asMap(pending.data['constraints'])['unavailableFoodIds'],
        ['custom:retired-food']);
    expect(pending.data['constraintRevision'], 2);
    // The plan still records the applied revision; the selection is only a
    // reviewed draft until repair installs it.
    expect((await loadPlan(db))!.document['constraintRevision'], 1);

    // A fresh screen loads the pending revision and keeps the selection.
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(
                const Key('unavailableFood:custom:retired-food')))
            .value,
        isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    final repaired = (await loadPlan(db))!;
    expect(repaired.meals, hasLength(2));
    expect(repaired.document['constraintRevision'], 2);
    expect(asMap(repaired.document['constraints'])['unavailableFoodIds'],
        ['custom:retired-food']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  // A present but malformed availability list must never be read as "none".
  // Duplicate ids get the full recovery flow below; these cover the remaining
  // malformed shapes the transactional validator rejects.
  for (final malformed in <MapEntry<String, Object?>>[
    const MapEntry('non-list', 'custom:beans'),
    const MapEntry('null', null),
    const MapEntry('blank-id', ['']),
    const MapEntry('non-string-id', [1]),
  ]) {
    testWidgets(
        'malformed unavailable ids (${malformed.key}) fail closed without rewriting',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final soup = planRecipe(id: 'soup', name: 'Soup');
      await seedRecipe(db, soup);
      await seedPlan(db, meals: [
        PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'), soup,
            Exact.one)
      ]);
      await LocalWorkspace(db).put(
          requestId: 'test:malformed-planner-inputs',
          collection: 'preferences',
          id: 'planner',
          expectedRevision: 0,
          data: {
            'schedule': {
              'startDate': '2026-01-01',
              'days': 3,
              'label': 'lunch',
              'portions': [Exact.one.toJson()],
              'excludedSlotIds': <Object?>[]
            },
            'constraints': {
              'maximumMinutes': null,
              'maximumRepeats': null,
              'energyMinimum': null,
              'energyMaximum': null,
              'unavailableFoodIds': malformed.value
            },
            'constraintRevision': 2,
            'relaxations': <Object?>[],
            'acceptedRelaxations': <Object?>[]
          });
      await helpers.pump(tester, db, const PlanScreen());
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved planner inputs are invalid'),
          findsOneWidget);
      // The applied schedule is displayed and the invalid draft is untouched.
      expect(find.textContaining('1 days from 2026-01-01 · dinner'),
          findsOneWidget);
      final draft = (await LocalWorkspace(db).read('preferences', 'planner'))!;
      expect(draft.revision, 1);
      expect(asMap(draft.data['constraints'])['unavailableFoodIds'],
          malformed.value);
      expect((await loadPlan(db))!.document['constraintRevision'], 1);
      expect(await db.select(db.logEntries).get(), isEmpty);
    });
  }

  testWidgets(
      'malformed saved unavailable ids fail closed without rewriting the draft',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final soup = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, soup);
    await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'), soup,
          Exact.one)
    ]);
    // A duplicate id is malformed exactly as the transactional validator
    // treats it. The UI must not read the malformed draft as "none".
    await LocalWorkspace(db).put(
        requestId: 'test:malformed-planner-inputs',
        collection: 'preferences',
        id: 'planner',
        expectedRevision: 0,
        data: {
          'schedule': {
            'startDate': '2026-01-01',
            'days': 3,
            'label': 'lunch',
            'portions': [Exact.one.toJson()],
            'excludedSlotIds': <Object?>[]
          },
          'constraints': {
            'maximumMinutes': null,
            'maximumRepeats': null,
            'energyMinimum': null,
            'energyMaximum': null,
            'unavailableFoodIds': ['custom:beans', 'custom:beans']
          },
          'constraintRevision': 2,
          'relaxations': <Object?>[],
          'acceptedRelaxations': <Object?>[]
        });
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved planner inputs are invalid'),
        findsOneWidget);
    // The applied plan stays authoritative; the malformed draft is neither
    // applied nor silently normalized in place.
    expect(find.textContaining('1 days from 2026-01-01 · dinner'),
        findsOneWidget);
    var draft = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(draft.revision, 1);
    expect(asMap(draft.data['constraints'])['unavailableFoodIds'],
        ['custom:beans', 'custom:beans']);

    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved planner inputs are invalid'),
        findsWidgets);
    expect((await loadPlan(db))!.document['constraintRevision'], 1);
    expect((await loadPlan(db))!.meals, hasLength(1));
    expect(await db.select(db.logEntries).get(), isEmpty);

    // Explicit review recovers: saving replaces the unreadable draft with a
    // valid revision, after which repair can apply it.
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    draft = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(draft.revision, 2);
    expect(draft.data['constraintRevision'], 2);
    expect(asMap(draft.data['constraints'])['unavailableFoodIds'], isEmpty);
    expect(find.textContaining('Constraint revision 2 saved'), findsOneWidget);

    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    final plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.document['constraintRevision'], 2);
    expect(asMap(plan.document['constraints'])['unavailableFoodIds'], isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('pt-PT removal copy excludes a day without losing intake separation',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    await helpers.pump(tester, db, const PlanScreen(), pt: true);
    await tester.tap(find.text('Plano'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Criar plano'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Opções da refeição').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Opções da refeição').first);
    await tester.pumpAndSettle();
    expect(find.text('Remover do plano'), findsOneWidget);
    await tester.tap(find.text('Remover do plano'));
    await tester.pumpAndSettle();
    expect(find.text('Remover esta refeição planeada?'), findsOneWidget);
    expect(find.textContaining('será excluído do horário'), findsOneWidget);
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    expect(stored.meals, hasLength(6));
    expect(stored.meals.map((m) => m.slot.id), isNot(contains('dinner:0')));
    expect(asMap(stored.document['schedule'])['excludedSlotIds'],
        ['dinner:0']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('pt-PT planner copy covers schedule, build and groceries',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    await helpers.pump(tester, db, const PlanScreen(), pt: true);
    await tester.tap(find.text('Plano'));
    await tester.pumpAndSettle();
    expect(find.text('Editar horário e restrições'), findsOneWidget);
    expect(find.text('Criar plano'), findsOneWidget);
    await tester.tap(find.text('Editar horário e restrições'));
    await tester.pumpAndSettle();
    expect(find.text('Ingredientes indisponíveis (restrição rígida)'),
        findsOneWidget);
    final availabilityCopy =
        find.textContaining('não um inventário da despensa');
    await tester.ensureVisible(availabilityCopy);
    await tester.pumpAndSettle();
    expect(availabilityCopy, findsOneWidget);
    expect(
        find.textContaining(
            'esta restrição nunca é relaxada automaticamente'),
        findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    expect(find.text('Adicionar artigo'), findsOneWidget);
  });
}
