import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;

void main() {
  testWidgets('manual groceries can be added, edited, checked and removed',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add grocery item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Oats 1 kg');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Oats 1 kg'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit grocery item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Oats 2 kg');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Oats 2 kg'), findsOneWidget);
    final data = (await LocalWorkspace(db).read('groceries', 'manual'))!.data;
    final item = Map<String, Object?>.from(data.values.single as Map);
    expect(item['name'], 'Oats 2 kg');
    expect(item['checked'], true);
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Oats 2 kg'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, true);
    await tester.tap(find.byTooltip('Remove grocery item'));
    await tester.pumpAndSettle();
    expect(find.text('Oats 2 kg'), findsNothing);
    expect(
        (await LocalWorkspace(db).read('groceries', 'manual'))!.data, isEmpty);
  });
}
