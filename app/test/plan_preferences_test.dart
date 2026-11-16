import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

void main() {
  testWidgets(
      'preferred recipe persists to draft and plan, survives pin and clears only on repair',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    await seedRecipe(db, planRecipe(id: 'stew', name: 'Stew'));
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    expect(find.textContaining('never overrides allergies'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('preferredRecipe:soup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preferredRecipe:soup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();

    // The reviewed preference is stored as soft top-level draft metadata and
    // is not applied to the plan or written as intake by saving inputs.
    var pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(asMap(pending.data['preferences'])['preferredRecipeIds'], ['soup']);
    expect(await loadPlan(db), isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);

    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    var stored = (await loadPlan(db))!;
    expect(
        asMap(stored.document['preferences'])['preferredRecipeIds'], ['soup']);
    // Preference is a tie-breaker only; with both recipes feasible the
    // preferred one is selected and intake stays untouched.
    expect(stored.meals.map((m) => m.recipe.id).toSet(), {'soup'});
    expect(await db.select(db.logEntries).get(), isEmpty);

    // A pin action preserves the reviewed soft metadata.
    await tester.tap(find.byTooltip('Pin meal').first);
    await tester.pumpAndSettle();
    stored = (await loadPlan(db))!;
    expect(
        asMap(stored.document['preferences'])['preferredRecipeIds'], ['soup']);
    expect(stored.meals.where((m) => m.pinned), hasLength(1));

    // Clearing is an explicit reviewed value, but is not applied until the
    // plan is repaired under the newer review revision.
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('preferredRecipe:soup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preferredRecipe:soup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(asMap(pending.data['preferences'])['preferredRecipeIds'], isEmpty);
    stored = (await loadPlan(db))!;
    expect(
        asMap(stored.document['preferences'])['preferredRecipeIds'], ['soup']);

    await tester.tap(find.text('Repair plan'));
    await tester.pumpAndSettle();
    stored = (await loadPlan(db))!;
    expect(asMap(stored.document['preferences'])['preferredRecipeIds'], isEmpty);
    expect(stored.meals, hasLength(7));
    expect(await db.select(db.logEntries).get(), isEmpty);

    // A fresh screen reads the applied preference metadata from storage.
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Preferred recipes (soft'), findsNothing);
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('preferredRecipe:soup')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('preferredRecipe:soup')))
            .value,
        isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('strict safety exclusion wins over a preferred recipe',
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
    await seedRecipe(db, planRecipe(id: 'safe', name: 'Safe'));
    await seedSafety(db, {'milk'});
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('preferredRecipe:milky')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preferredRecipe:milky')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    // Safety excludes Milky from candidacy even though it is preferred; the
    // preference is retained as reviewed metadata rather than discarded.
    expect(stored.meals.map((m) => m.recipe.id).toSet(), {'safe'});
    expect(
        asMap(stored.document['preferences'])['preferredRecipeIds'], ['milky']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('malformed saved preferred ids fail closed without intake',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    await LocalWorkspace(db).put(
        requestId: 'test:malformed-preferences',
        collection: 'preferences',
        id: 'planner',
        expectedRevision: 0,
        data: {
          'preferences': {'preferredRecipeIds': 'soup'}
        });
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Saved planner inputs are invalid and were not applied'),
        findsOneWidget);

    await tester.tap(find.text('Build plan'));
    await tester.pumpAndSettle();
    expect(await loadPlan(db), isNull);
    expect(await db.select(db.logEntries).get(), isEmpty);
    // The malformed document is left untouched for explicit review.
    final pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    expect(pending.data, {'preferences': {'preferredRecipeIds': 'soup'}});
    expect(pending.revision, 1);
  });

  testWidgets('selected id missing from the catalogue is shown and kept',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    await LocalWorkspace(db).put(
        requestId: 'test:missing-preference',
        collection: 'preferences',
        id: 'planner',
        expectedRevision: 0,
        data: {
          'schedule': {
            'startDate': '2026-01-01',
            'days': 7,
            'label': 'dinner',
            'portions': [Exact.one.toJson()],
            'excludedSlotIds': <Object?>[]
          },
          'constraintRevision': 2,
          'preferences': {
            'preferredRecipeIds': ['ghost'],
            'other': 'kept'
          }
        });
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit schedule and constraints'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('preferredRecipe:ghost')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('preferredRecipe:ghost')))
            .value,
        isTrue);
    expect(
        find.textContaining('the preference is kept'), findsOneWidget);
    // Force a reviewed change so saving writes the effective preferences.
    await tester.ensureVisible(find.byKey(const Key('scheduleDaysField')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scheduleDaysField')), '6');
    await tester.tap(find.byKey(const Key('saveScheduleButton')));
    await tester.pumpAndSettle();

    final pending = (await LocalWorkspace(db).read('preferences', 'planner'))!;
    final preferences = asMap(pending.data['preferences']);
    expect(preferences['preferredRecipeIds'], ['ghost']);
    // Sibling preference keys and unrelated metadata are preserved.
    expect(preferences['other'], 'kept');
    expect(pending.data['constraintRevision'], 3);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets(
      'legacy plan without preferences reads empty and pin keeps sibling preference keys',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    final seeded = await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-01-01', 'dinner'), recipe,
          Exact.one)
    ]);
    // The plan predates recipe preferences but already carries an unrelated
    // preference key that this screen does not own.
    await LocalWorkspace(db).put(
        requestId: 'test:legacy-plan-preferences',
        collection: 'plan',
        id: 'current',
        expectedRevision: seeded.revision,
        data: {
          ...seeded.document,
          'preferences': {'other': 'kept'}
        });
    await helpers.pump(tester, db, const PlanScreen());
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    // Absent preferredRecipeIds is legacy absence, not malformed: no
    // preference is applied and no error is shown.
    expect(find.textContaining('Preferred recipes (soft'), findsNothing);
    expect(find.textContaining('Saved planner inputs are invalid'), findsNothing);
    await tester.tap(find.byTooltip('Pin meal'));
    await tester.pumpAndSettle();

    final stored = (await loadPlan(db))!;
    final preferences = asMap(stored.document['preferences']);
    expect(preferences['preferredRecipeIds'], isEmpty);
    expect(preferences['other'], 'kept');
    expect(stored.meals.single.pinned, isTrue);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  testWidgets('Portuguese preference selector exposes localized labels',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await seedRecipe(db, planRecipe(id: 'soup', name: 'Soup'));
    final semantics = tester.ensureSemantics();
    await helpers.pump(tester, db, const PlanScreen(), pt: true);
    await tester.tap(find.text('Plano'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editar horário e restrições'));
    await tester.pumpAndSettle();
    expect(find.text('Receitas preferidas (opcional, suave)'), findsOneWidget);
    expect(
        find.bySemanticsLabel('Receitas preferidas (opcional, suave)'),
        findsOneWidget);
    expect(
        find.textContaining(
            'nunca sobrepõe alergias, restrições alimentares declaradas, ingredientes indisponíveis ou refeições fixadas'),
        findsOneWidget);
    expect(find.byKey(const Key('preferredRecipe:soup')), findsOneWidget);
    semantics.dispose();
  });
}
