import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  Future<void> reserveFirstMeal(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Meal options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reserve cooked batch stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Soup · v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'reserved cooked stock persists separately from intake and is consumed once',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedRecipe(db, recipe);
    await seedBatch(db, id: 'batch-1', recipe: recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe,
          Exact.one)
    ], startDate: '2026-01-01');
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);

    await reserveFirstMeal(tester);

    var batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    var allocations = asMaps(batch.data['allocations']);
    expect(allocations, hasLength(1));
    expect(allocations.single['status'], 'planned');
    expect(exactJson(allocations.single['amount']), Exact.parse('300'));
    // Reservation is a plan-level hold: no diary entry and no consumption.
    expect(await db.select(db.logEntries).get(), isEmpty);
    var plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.meals.single.batchUse, isNotNull);
    expect(plan.meals.single.batchUse!.batchRevision, batch.revision);
    expect(
        plan.meals.single.batchUse!.allocationId,
        allocations.single['id']);

    // Cancelling the explicit consumption confirmation changes nothing.
    await tester.tap(find.byTooltip('Confirm actual intake'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    expect(
        asMaps(batch.data['allocations']).single['status'], 'planned');

    await tester.tap(find.byTooltip('Confirm actual intake'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(await db.select(db.logEntries).get(), hasLength(1));
    batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    allocations = asMaps(batch.data['allocations']);
    expect(allocations, hasLength(1));
    expect(allocations.single['status'], 'consumed');
    expect(exactJson(allocations.single['amount']), Exact.parse('300'));
    plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.meals.single.batchUse, isNotNull);
    expect(plan.meals.single.batchUse!.allocationId,
        allocations.single['id']);
  });

  testWidgets('releasing a reservation returns stock without intake',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedRecipe(db, recipe);
    await seedBatch(db, id: 'batch-1', recipe: recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe,
          Exact.one)
    ], startDate: '2026-01-01');
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await reserveFirstMeal(tester);
    expect(
        asMaps((await LocalWorkspace(db).read('batch', 'batch-1'))!
            .data['allocations']),
        hasLength(1));

    await tester.tap(find.byTooltip('Meal options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release reservation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    expect(asMaps(batch.data['allocations']), isEmpty);
    final plan = (await loadPlan(db))!;
    expect(plan.meals, hasLength(1));
    expect(plan.meals.single.batchUse, isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('no reservation candidate is offered without measured stock',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe,
          Exact.one)
    ], startDate: '2026-01-01');
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Meal options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reserve cooked batch stock'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'No cooked batch of this recipe has enough unreserved stock'),
        findsOneWidget);
    final plan = (await loadPlan(db))!;
    expect(plan.meals.single.batchUse, isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
}
