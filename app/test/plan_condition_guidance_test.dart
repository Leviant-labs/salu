import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  testWidgets(
      'declared condition changes real plan choices on repair and shows rationale',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final high = planRecipe(
        id: 'high-sat',
        name: 'High sat',
        ingredients: [
          RecipeIngredient(
              planFood('high-sat-food',
                  nutrients: {
                    NutrientKey.energyKcal: NutrientReported(400),
                    NutrientKey.saturatedFatG: NutrientReported(20),
                  }),
              Exact.parse('100'))
        ]);
    final low = planRecipe(
        id: 'low-sat',
        name: 'Low sat',
        ingredients: [
          RecipeIngredient(
              planFood('low-sat-food',
                  nutrients: {
                    NutrientKey.energyKcal: NutrientReported(400),
                    NutrientKey.saturatedFatG: NutrientReported(1),
                  }),
              Exact.parse('100'))
        ]);
    await seedRecipe(db, high);
    await seedRecipe(db, low);

    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    final before = (await loadPlan(db))!;
    expect(before.meals, hasLength(7));
    expect(before.meals.every((meal) => meal.recipe.id == 'low-sat'), isFalse,
        reason: 'without declared conditions no saturated-fat ranking applies');
    expect(find.textContaining('Condition-aware meal planning'), findsNothing);

    // The settings surface writes this document; the planner reads the same
    // declarations and must re-rank instead of returning the valid old plan.
    await seedHealthDeclaration(db, {'highCholesterol': true});
    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();

    final after = (await loadPlan(db))!;
    expect(after.meals, hasLength(7));
    expect(after.meals.every((meal) => meal.recipe.id == 'low-sat'), isTrue,
        reason: 'the known lower-saturated-fat recipe must be preferred');
    expect(after.conditionGuidance!.declared,
        {PlanningCondition.highCholesterol});
    expect(find.textContaining('Condition-aware meal planning'),
        findsOneWidget);
    expect(find.textContaining('Prefer lower saturated fat'), findsOneWidget);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
}
