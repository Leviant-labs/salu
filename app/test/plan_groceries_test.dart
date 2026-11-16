import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  testWidgets(
      'generated groceries can be edited, checked, removed and restored without losing manual entries',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(
        id: 'soup',
        name: 'Soup',
        ingredients: [
          RecipeIngredient(planFood('beans', name: 'Beans'), Exact.parse('300'))
        ]);
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(
          const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe,
          Exact.one)
    ], startDate: '2026-01-01');
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Beans'), findsOneWidget);
    expect(find.textContaining('150 g'), findsOneWidget);

    await tester.tap(find.byTooltip('Grocery item options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit grocery item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Beans (tin)');
    await tester.enterText(find.byType(TextField).at(1), '500');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Beans (tin)'), findsOneWidget);
    expect(find.textContaining('500 g'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        true);

    await tester.tap(find.text('Add grocery item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Oats');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Oats'), findsOneWidget);

    // Repair re-runs planning but must not touch grocery edits or checkmarks.
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Beans (tin)'), findsOneWidget);
    expect(find.text('Oats'), findsOneWidget);
    expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        true);

    await tester.tap(find.byTooltip('Grocery item options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove grocery item'));
    await tester.pumpAndSettle();
    expect(find.text('Beans (tin)'), findsNothing);
    expect(find.textContaining('Restore removed grocery items (1)'),
        findsOneWidget);
    await tester.tap(find.textContaining('Restore removed grocery items (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Beans (tin)'), findsOneWidget);

    final generated = asMap(
        (await LocalWorkspace(db).read('groceries', 'current'))!
            .data['custom:beans|raw']);
    expect(generated['name'], 'Beans (tin)');
    expect(exactJson(generated['grams']), Exact.parse('500'));
    expect(generated['checked'], true);
    expect(generated['removed'], false);
    final manual =
        (await LocalWorkspace(db).read('groceries', 'manual'))!.data;
    expect(manual, hasLength(1));
    expect(asMap(manual.values.single)['name'], 'Oats');
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
  testWidgets('cooked rice remains a cooked-weight requirement with an editable name',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final rice = Food(
        id: 'insa-bdca:403',
        name: 'Arroz cozido simples',
        per100g: NutrientProfile(const {}),
        source: FoodSource(dataset: 'test', datasetId: '403'),
        quality: DataQuality.userEntered,
        allergens: const {},
        preparation: Preparation.cooked);
    final recipe = planRecipe(servings: '1', ingredients: [
      RecipeIngredient(rice, Exact.parse('250'))
    ]);
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'),
          recipe, Exact.one)
    ], startDate: '2026-01-01');
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(find.text('Ready-cooked plain rice'), findsOneWidget);
    expect(find.textContaining('250 g'), findsOneWidget);
    expect(find.textContaining('No dry weight is estimated'), findsOneWidget);
    await tester.tap(find.byTooltip('Grocery item options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit grocery item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Rice from home');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Rice from home'), findsOneWidget);
    expect(find.textContaining('No dry weight is estimated'), findsOneWidget);
    final overlay = (await LocalWorkspace(db).read('groceries', 'current'))!.data;
    expect(asMap(overlay['insa-bdca:403|cooked'])['name'], 'Rice from home');
    expect(recipe.ingredients.single.food.name, 'Arroz cozido simples');
  });
}
