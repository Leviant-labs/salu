import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/search/search_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

void main() {
  testWidgets('saved draft requires review before diary write', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'apple',
          name: 'Apple',
          per100g: NutrientProfile({}),
          source: const FoodSource(dataset: 'custom', datasetId: 'apple')),
    ]);
    await harness.pump(tester, db, const SearchScreen());
    await tester.enterText(find.byType(TextField).first, 'Apple');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Choose quantity and log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    await tester.tap(find.text('Drafts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit amount'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '75');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    expect(find.textContaining('75.0 g'), findsOneWidget);
    expect(find.text('Record this intake?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), hasLength(1));
    final item = (await db.select(db.logEntryItems).get()).single;
    expect(item.grams, 75);
    expect(find.text('No saved drafts'), findsOneWidget);
  });
  testWidgets('a changed food requires a new review', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repository = DriftFoodRepository(db);
    Food food(String name) => Food(
        id: 'apple',
        name: name,
        per100g: NutrientProfile({}),
        source: const FoodSource(dataset: 'custom', datasetId: 'apple'));
    await repository.replaceCatalogueBatch([food('Apple')]);
    await harness.pump(tester, db, const SearchScreen());
    await tester.enterText(find.byType(TextField).first, 'Apple');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Choose quantity and log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    await repository.replaceCatalogueBatch([food('Changed apple')]);
    await tester.tap(find.text('Drafts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Food changed'), findsOneWidget);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
}
