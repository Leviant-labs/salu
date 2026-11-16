import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/batches_screen.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  testWidgets(
      'batch screen shows reservations and requires explicit confirmation for unreserved intake',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedBatch(db,
        id: 'batch-1',
        recipe: recipe,
        available: '500',
        finished: '500',
        allocations: [planAllocation('plan-1', '100', 'planned')]);
    await helpers.pump(tester, db, const BatchesScreen());
    expect(find.text('Reserved 100 g'), findsOneWidget);
    expect(find.textContaining('remaining unreserved: 400 g'), findsOneWidget);

    await tester.tap(find.byTooltip('Log consumed batch portion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '500');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'The amount exceeds the unreserved stock'),
        findsOneWidget);
    expect(await db.select(db.logEntries).get(), isEmpty);

    await tester.tap(find.byTooltip('Log consumed batch portion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '100');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);

    await tester.tap(find.byTooltip('Log consumed batch portion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '100');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(await db.select(db.logEntries).get(), hasLength(1));
    expect(find.text('Consumed 100 g'), findsOneWidget);
    expect(find.text('Reserved 100 g'), findsOneWidget);
    final batch = (await LocalWorkspace(db).read('batch', 'batch-1'))!;
    expect(asMaps(batch.data['allocations']), hasLength(2));
  });
}
