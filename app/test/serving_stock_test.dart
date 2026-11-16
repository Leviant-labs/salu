import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/batches_screen.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  Future<void> openBatchCreation(WidgetTester tester) async {
    final menu = find.byType(PopupMenuButton<String>).first;
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record a cooked batch'));
    await tester.pumpAndSettle();
  }

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
      'serving batch displays servings and writes intake only after confirmation',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedServingBatch(db, id: 'batch-s', recipe: recipe, available: '2');
    await helpers.pump(tester, db, const BatchesScreen());

    expect(find.textContaining('Equal servings in this batch: 2 servings'),
        findsOneWidget);
    expect(find.textContaining('remaining unreserved: 2 servings'),
        findsOneWidget);
    // No numeric gram quantity is ever shown for this serving stock. A plain
    // ' g' substring also occurs inside prose such as "or guessed", so match a
    // quantity pattern instead.
    expect(find.textContaining(RegExp(r'\d+(?:[.,]\d+)?\s?g\b')),
        findsNothing);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // An amount above the unreserved stock is rejected without intake.
    await tester.tap(find.byTooltip('Log consumed batch portion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The amount exceeds the unreserved stock'),
        findsOneWidget);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // Planning/displaying stock is never intake; cancelling confirms nothing.
    await tester.tap(find.byTooltip('Log consumed batch portion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Record 1 serving from this cooked batch as consumed?'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);

    await tester.tap(find.byTooltip('Log consumed batch portion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final rows = await db.select(db.logEntries).get();
    expect(rows, hasLength(1));
    final entry =
        (await DriftEntryRepository(db).findByRequestId(rows.single.requestId))!;
    expect(entry.items.single.grams, isNull);
    final snapshot = asMap(entry.items.single.sourceSnapshot);
    expect(snapshot['consumedBatchUnit'], 'serving');
    expect(exactJson(snapshot['consumedBatchServings']), Exact.one);
    expect(exactJson(snapshot['allocationScale']), Exact.parse('0.5'));
    expect(exactJson(snapshot['recipeServings']), Exact.parse('2'));
    expect(snapshot.containsKey('consumedBatchGrams'), isFalse);
    expect(snapshot.containsKey('finishedWeightG'), isFalse);

    final batch = (await LocalWorkspace(db).read('batch', 'batch-s'))!;
    final allocations = asMaps(batch.data['allocations']);
    expect(allocations, hasLength(1));
    expect(allocations.single['status'], 'consumed');
    expect(exactJson(allocations.single['amount']), Exact.one);
    expect(batch.data['unit'], 'serving');
    expect(batch.data.containsKey('finishedWeightG'), isFalse);
    expect(find.text('Consumed 1 serving'), findsOneWidget);
  });

  testWidgets(
      'serving stock is created, reserved and consumed as exact servings offline',
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
    ]);
    await helpers.pump(tester, db, const PlanScreen());

    await openBatchCreation(tester);
    await tester.tap(find.text('Equal servings'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No finished weight is measured or guessed'),
        findsOneWidget);
    await tester.tap(find.text('Create batch'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Cooked batch saved'), findsOneWidget);

    var batch = (await LocalWorkspace(db).read('batch',
        (await LocalWorkspace(db).list('batch')).single.id))!;
    expect(batch.data['unit'], 'serving');
    expect(exactJson(batch.data['available']), Exact.parse('2'));
    expect(batch.data.containsKey('finishedWeightG'), isFalse);
    expect(batch.data['allocations'], isEmpty);

    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    await reserveFirstMeal(tester);
    expect(find.textContaining('Reserved 1 serving from cooked stock'),
        findsOneWidget);

    batch = (await LocalWorkspace(db).read('batch', batch.id))!;
    var allocations = asMaps(batch.data['allocations']);
    expect(allocations, hasLength(1));
    expect(allocations.single['status'], 'planned');
    expect(exactJson(allocations.single['amount']), Exact.one);
    // Reserving stock is plan-only: no diary entry, no intake.
    expect(await db.select(db.logEntries).get(), isEmpty);
    var plan = (await loadPlan(db))!;
    expect(plan.meals.single.batchUse, isNotNull);
    expect(plan.meals.single.batchUse!.batchRevision, batch.revision);
    expect(plan.meals.single.batchUse!.allocationId,
        allocations.single['id']);

    // Cancelling the explicit consumption leaves the reservation and diary
    // untouched.
    await tester.tap(find.byTooltip('Confirm actual intake'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Record 1 serving from this cooked batch as consumed'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    batch = (await LocalWorkspace(db).read('batch', batch.id))!;
    expect(asMaps(batch.data['allocations']).single['status'], 'planned');

    await tester.tap(find.byTooltip('Confirm actual intake'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final rows = await db.select(db.logEntries).get();
    expect(rows, hasLength(1));
    final entry =
        (await DriftEntryRepository(db).findByRequestId(rows.single.requestId))!;
    expect(entry.items.single.grams, isNull);
    final snapshot = asMap(entry.items.single.sourceSnapshot);
    expect(snapshot['consumedBatchUnit'], 'serving');
    expect(exactJson(snapshot['consumedBatchServings']), Exact.one);
    expect(exactJson(snapshot['allocationScale']), Exact.parse('0.5'));
    expect(snapshot.containsKey('consumedBatchGrams'), isFalse);
    expect(snapshot['reservedAllocationId'], allocations.single['id']);

    batch = (await LocalWorkspace(db).read('batch', batch.id))!;
    allocations = asMaps(batch.data['allocations']);
    expect(allocations, hasLength(1));
    expect(allocations.single['status'], 'consumed');
    expect(exactJson(allocations.single['amount']), Exact.one);
    plan = (await loadPlan(db))!;
    expect(plan.meals.single.batchUse, isNotNull);
    expect(plan.meals.single.batchUse!.allocationId,
        allocations.single['id']);
  });

  testWidgets('releasing serving stock returns exact servings without intake',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedRecipe(db, recipe);
    await seedServingBatch(db, id: 'batch-s', recipe: recipe, available: '2');
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe,
          Exact.one)
    ]);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await reserveFirstMeal(tester);
    expect(
        asMaps((await LocalWorkspace(db).read('batch', 'batch-s'))!
            .data['allocations']),
        hasLength(1));

    await tester.tap(find.byTooltip('Meal options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release reservation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final batch = (await LocalWorkspace(db).read('batch', 'batch-s'))!;
    expect(asMaps(batch.data['allocations']), isEmpty);
    expect(exactJson(batch.data['available']), Exact.parse('2'));
    final plan = (await loadPlan(db))!;
    expect(plan.meals.single.batchUse, isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('gram batch creation still stores the measured finished weight',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedRecipe(db, recipe);
    await helpers.pump(tester, db, const PlanScreen());

    await openBatchCreation(tester);
    // Measured grams remain the default path, unchanged for existing users.
    await tester.enterText(find.byType(TextField), '750');
    await tester.tap(find.text('Create batch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Cooked batch saved'), findsOneWidget);

    final batch = (await LocalWorkspace(db).list('batch')).single;
    expect(batch.data['unit'], 'g');
    expect(exactJson(batch.data['available']), Exact.parse('750'));
    expect(exactJson(batch.data['finishedWeightG']), Exact.parse('750'));
    expect(batch.data['allocations'], isEmpty);
  });

  testWidgets('serving stock copy is localised to pt-PT and never grams',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup', servings: '2');
    await seedServingBatch(db, id: 'batch-s', recipe: recipe, available: '2');
    await helpers.pump(tester, db, const BatchesScreen(), pt: true);

    expect(find.textContaining('restante não reservado: 2 porções'),
        findsOneWidget);
    expect(find.textContaining('Porções iguais neste lote'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+(?:[.,]\d+)?\s?g\b')),
        findsNothing);

    await tester.tap(find.byTooltip('Registar porção consumida do lote'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Registar 1 porção deste lote confecionado para consumo?'),
        findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);

    // The plan reservation copy is localised too and remains plan-only.
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe,
          Exact.one)
    ]);
    await helpers.pump(tester, db, const PlanScreen(), pt: true);
    await tester.tap(find.text('Plano'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Opções da refeição'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reservar stock de lote confecionado'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Soup · v1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reservar 1 porção deste lote'),
        findsOneWidget);
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reservado 1 porção de stock confecionado'),
        findsOneWidget);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
}
