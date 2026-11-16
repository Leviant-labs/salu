import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food testFood(String id, Map<NutrientKey, NutrientValue>? nutrients,
        {Set<String>? allergens = const {}}) =>
    Food(
        id: id,
        name: id,
        per100g: NutrientProfile(nutrients ?? const {}),
        source: FoodSource(dataset: 'test', datasetId: id),
        allergens: allergens);

RecipeVersion buildRecipe(String id,
        {int revision = 1,
        Map<NutrientKey, NutrientValue>? nutrients,
        Set<String>? allergens = const {},
        Set<String>? ingredientAllergens = const {},
        int minutes = 10,
        String? foodId,
        Set<String> dietaryTags = const {}}) =>
    RecipeVersion(
        id: id,
        revision: revision,
        name: id,
        minutes: minutes,
        servings: Exact.one,
        allergens: allergens,
        dietaryTags: dietaryTags,
        ingredients: [
          RecipeIngredient(
              testFood(
                  foodId ?? 'food-$id',
                  nutrients ??
                      {NutrientKey.energyKcal: NutrientReported(100)},
                  allergens: ingredientAllergens),
              Exact.parse('100'))
        ]);

void main() {
  const planner = PlannerService();
  const slot = MealSlot('s0', '2026-01-01', 'Dinner');
  PlannedMeal meal(RecipeVersion recipe,
          {MealSlot at = slot,
          Exact? portions,
          bool pinned = false,
          PlannedBatchUse? batchUse}) =>
      PlannedMeal(at, recipe, portions ?? Exact.one,
          pinned: pinned, batchUse: batchUse);

  test('strict exclusion rejects unknown ingredient allergen status', () {
    final unsafe = buildRecipe('unsafe',
        allergens: {}, ingredientAllergens: null);
    final context = PlannerContext(
        slots: [slot],
        recipes: [unsafe],
        seed: 1,
        strictExclusions: {'milk'});
    expect(planner.validate([meal(unsafe)], context),
        contains('ALLERGEN_STATUS_UNKNOWN'));
    expect(planner.plan(context).status, PlannerStatus.provenInfeasible);
    final repair = planner.repair(context, const []);
    expect(repair.status, PlannerStatus.provenInfeasible);
    expect(repair.relaxations, isEmpty);
  });

  test('strict exclusion accepts only fully known, non-containing recipes', () {
    final safe = buildRecipe('safe', allergens: {}, ingredientAllergens: {});
    final context = PlannerContext(
        slots: [slot],
        recipes: [safe],
        seed: 1,
        strictExclusions: {'milk'});
    expect(planner.plan(context).status, PlannerStatus.validPlan);
  });

  test('unavailable current ingredients are a hard constraint', () {
    final flour = buildRecipe('flour', foodId: 'flour');
    final context = PlannerContext(
        slots: [slot],
        recipes: [flour],
        seed: 1,
        unavailableFoodIds: {'flour'});
    expect(planner.validate([meal(flour)], context),
        contains('INGREDIENT_UNAVAILABLE'));
    expect(planner.plan(context).status, PlannerStatus.provenInfeasible);
    expect(planner.repair(context, const []).relaxations, isEmpty);
  });

  test('current catalogue definitions invalidate stale recipe snapshots', () {
    final recipe = buildRecipe('r',
        foodId: 'ingredient',
        nutrients: {NutrientKey.energyKcal: NutrientReported(100)});
    final stale = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        currentFoods: {
          'ingredient': testFood('ingredient',
              {NutrientKey.energyKcal: NutrientReported(200)})
        });
    expect(planner.validate([meal(recipe)], stale),
        contains('INGREDIENT_STALE'));
    expect(planner.plan(stale).status, PlannerStatus.provenInfeasible);
    final missing = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        currentFoods: <String, Food>{});
    expect(planner.validate([meal(recipe)], missing),
        contains('INGREDIENT_UNRESOLVED'));
    final current = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        currentFoods: {
          'ingredient': testFood('ingredient',
              {NutrientKey.energyKcal: NutrientReported(100)})
        });
    expect(planner.validate([meal(recipe)], current), isEmpty);
  });

  test('only the current recipe revision is planned', () {
    final revision1 = buildRecipe('r', revision: 1);
    final revision2 = buildRecipe('r', revision: 2);
    final context = PlannerContext(
        slots: [slot], recipes: [revision1, revision2], seed: 1);
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.single.recipe.revision, 2);
    expect(planner.validate([meal(revision1)], context),
        contains('RECIPE_REVISION_MISMATCH'));
  });

  test('hard numeric range selects the explicitly allowed portion', () {
    final recipe = buildRecipe('r',
        nutrients: {NutrientKey.energyKcal: NutrientReported(100)});
    final context = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        portions: [Exact.one, Exact.parse('2')],
        constraints: [
          NumericConstraint(
              NutrientKey.energyKcal, Exact.parse('150'), Exact.parse('250'))
        ]);
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.single.portions, Exact.parse('2'));
    expect(planner.validate(result.meals, context), isEmpty);

    final exact = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        portions: [Exact.one, Exact.parse('2')],
        constraints: [
          NumericConstraint(
              NutrientKey.energyKcal, Exact.parse('200'), Exact.parse('200'))
        ]);
    expect(planner.plan(exact).meals.single.portions, Exact.parse('2'));
  });

  test('unknown nutrients are not zero-cost foods for binding checks', () {
    final measured = buildRecipe('measured',
        nutrients: {NutrientKey.energyKcal: NutrientReported(50)});
    final unmeasured = buildRecipe('unmeasured',
        nutrients: {NutrientKey.proteinG: NutrientReported(10)});
    final context = PlannerContext(
        slots: [slot],
        recipes: [measured, unmeasured],
        seed: 1,
        portions: [Exact.one, Exact.parse('2')],
        constraints: [
          NumericConstraint(
              NutrientKey.energyKcal, Exact.parse('100'), Exact.parse('100'))
        ]);
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.single.recipe.id, 'measured');
    expect(result.meals.single.portions, Exact.parse('2'));
    expect(
        planner.validate([meal(unmeasured)], context),
        contains('INSUFFICIENT_NUTRIENT_DATA'));
  });

  test('data completeness is a soft objective, not a zero-cost claim', () {
    final complete = buildRecipe('complete', nutrients: {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.proteinG: NutrientReported(10)
    });
    final partial = buildRecipe('partial',
        nutrients: {NutrientKey.energyKcal: NutrientReported(100)});
    final context = PlannerContext(
        slots: [slot], recipes: [complete, partial], seed: 1);
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.single.recipe.id, 'complete');
    expect(
        result.quality!.scores[PlannerObjective.dataCompleteness]!
            .compareTo(Exact.parse('1')),
        lessThan(0));
  });

  test('target proximity outranks canonical ordering', () {
    final near = buildRecipe('z-near',
        nutrients: {NutrientKey.energyKcal: NutrientReported(300)});
    final far = buildRecipe('a-far',
        nutrients: {NutrientKey.energyKcal: NutrientReported(450)});
    final context = PlannerContext(
        slots: [slot],
        recipes: [near, far],
        seed: 1,
        constraints: [
          NumericConstraint(
              NutrientKey.energyKcal, Exact.parse('100'), Exact.parse('500'))
        ]);
    final result = planner.plan(context);
    expect(result.meals.single.recipe.id, 'z-near');
    expect(result.quality!.scores[PlannerObjective.targetProximity],
        Exact.zero);
  });

  test('cooking effort, reuse and variety are staged deterministic objectives',
      () {
    final quick = buildRecipe('z-quick', minutes: 10);
    final slow = buildRecipe('a-slow', minutes: 30);
    final effort = PlannerContext(
        slots: [slot], recipes: [quick, slow], seed: 1);
    expect(planner.plan(effort).meals.single.recipe.id, 'z-quick');

    final x = buildRecipe('x', foodId: 'p');
    final y = buildRecipe('y', foodId: 'q');
    final z = buildRecipe('z', foodId: 'p');
    const first = MealSlot('a', '2026-01-01', 'Dinner');
    const second = MealSlot('b', '2026-01-02', 'Dinner');
    final reuse = PlannerContext(
        slots: [first, second], recipes: [x, y, z], seed: 1);
    final reuseResult = planner.plan(reuse);
    expect(reuseResult.status, PlannerStatus.validPlan);
    expect(reuseResult.meals.first.recipe.id, 'x');
    expect(reuseResult.meals.last.recipe.id, 'z');
    expect(reuseResult.quality!.scores[PlannerObjective.ingredientReuse],
        Exact.parse('1') / Exact.parse('2'));

    final variety = PlannerContext(
        slots: [first, second],
        recipes: [
          buildRecipe('a', foodId: 'shared'),
          buildRecipe('b', foodId: 'shared'),
          buildRecipe('c', foodId: 'shared'),
        ],
        seed: 1);
    final varied = planner.plan(variety);
    expect(varied.meals.first.recipe.id,
        isNot(varied.meals.last.recipe.id));
    expect(varied.quality!.scores[PlannerObjective.variety], Exact.zero);
  });

  test('guidance objective stays inert without declared nutrients', () {
    final recipe = buildRecipe('r');
    final context = PlannerContext(
        slots: [slot], recipes: [recipe], seed: 1);
    final result = planner.plan(context);
    expect(result.quality!.scores[PlannerObjective.guidance], Exact.zero);
  });

  test('repair preserves unchanged valid meals around a changed slot', () {
    final a = buildRecipe('a', foodId: 'shared');
    final b = buildRecipe('b', foodId: 'shared');
    final c = buildRecipe('c',
        foodId: 'shared', allergens: {'milk'}, ingredientAllergens: {'milk'});
    final d = buildRecipe('d', foodId: 'shared');
    const other = MealSlot('s1', '2026-01-02', 'Dinner');
    const third = MealSlot('s2', '2026-01-03', 'Dinner');
    final context = PlannerContext(
        slots: [slot, other, third],
        recipes: [a, b, c, d],
        seed: 3,
        strictExclusions: {'milk'});
    final result =
        planner.repair(context, [meal(a), meal(b, at: other), meal(c, at: third)]);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals[0].recipe.id, 'a');
    expect(result.meals[1].recipe.id, 'b');
    expect(result.meals[2].recipe.id, 'd');
    expect(result.quality!.preservedMeals, 2);
  });

  test('relaxations are proposed but never installed automatically', () {
    final slow = buildRecipe('slow', minutes: 30);
    final context = PlannerContext(
        slots: [slot], recipes: [slow], seed: 1, maximumMinutes: 10);
    expect(planner.plan(context).status, PlannerStatus.provenInfeasible);
    final repair = planner.repair(context, const []);
    expect(repair.status, PlannerStatus.proposedRelaxation);
    expect(repair.meals, isEmpty);
    expect(repair.originalStatus, PlannerStatus.provenInfeasible);
    expect(repair.relaxations, isNotEmpty);
    final time = repair.relaxations
        .firstWhere((r) => r.kind == PlannerRelaxationKind.maximumMinutes);
    expect(time.maximumMinutes, 30);
    expect(PlannerRelaxation.fromJson(time.toJson()), time);
    expect(
        () => planner.acceptRelaxation(context, time,
            confirmed: false, expectedRevision: 1),
        throwsStateError);
    expect(
        () => planner.acceptRelaxation(context, time,
            confirmed: true, expectedRevision: 2),
        throwsStateError);
    final accepted = planner.acceptRelaxation(context, time,
        confirmed: true, expectedRevision: 1);
    expect(accepted.context.revision, 2);
    expect(accepted.context.maximumMinutes, 30);
    expect(accepted.context.strictExclusions, context.strictExclusions);
    expect(accepted.context.acceptedRelaxations.single, time);
    expect(accepted.result.status, PlannerStatus.validPlan);
  });

  test('numeric relaxation is explicit and revalidated', () {
    final recipe = buildRecipe('r',
        nutrients: {NutrientKey.energyKcal: NutrientReported(100)});
    final context = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        constraints: [
          NumericConstraint(
              NutrientKey.energyKcal, Exact.parse('200'), Exact.parse('300'))
        ]);
    final repair = planner.repair(context, const []);
    expect(repair.status, PlannerStatus.proposedRelaxation);
    final removal = repair.relaxations.firstWhere(
        (r) => r.kind == PlannerRelaxationKind.numericConstraint);
    expect(removal.constraintNutrient, NutrientKey.energyKcal);
    expect(removal.constraint, isNull);
    final accepted = planner.acceptRelaxation(context, removal,
        confirmed: true, expectedRevision: 1);
    expect(accepted.context.constraints, isEmpty);
    expect(accepted.context.revision, 2);
    expect(accepted.result.status, PlannerStatus.validPlan);
  });

  test('pinned portion conflict proposes its own portion, not a guess', () {
    final recipe = buildRecipe('r');
    final context =
        PlannerContext(slots: [slot], recipes: [recipe], seed: 1);
    final pinned = meal(recipe, portions: Exact.parse('2'), pinned: true);
    final plan = planner.plan(context, existing: [pinned]);
    expect(plan.status, PlannerStatus.provenInfeasible);
    final repair = planner.repair(context, [pinned]);
    expect(repair.status, PlannerStatus.proposedRelaxation);
    final portions = repair.relaxations
        .firstWhere((r) => r.kind == PlannerRelaxationKind.portions);
    expect(portions.portions, [Exact.one, Exact.parse('2')]);
    final accepted = planner.acceptRelaxation(context, portions,
        confirmed: true, expectedRevision: 1, existing: [pinned]);
    expect(accepted.context.portions, [Exact.one, Exact.parse('2')]);
    expect(accepted.result.status, PlannerStatus.validPlan);
  });

  test('pinned time conflict stays a conflict with confirmable options', () {
    final slow = buildRecipe('slow', minutes: 30);
    final context = PlannerContext(
        slots: [slot], recipes: [slow], seed: 1, maximumMinutes: 10);
    final pinned = meal(slow, pinned: true);
    expect(
        planner.plan(context, existing: [pinned]).status,
        PlannerStatus.targetConflict);
    final repair = planner.repair(context, [pinned]);
    expect(repair.status, PlannerStatus.proposedRelaxation);
    expect(repair.originalStatus, PlannerStatus.targetConflict);
    expect(
        repair.relaxations
            .where((r) => r.kind == PlannerRelaxationKind.pin)
            .map((r) => r.reason),
        contains('PIN_TIME_CONFLICT'));
  });

  test('same seed and inputs produce the same bounded plan', () {
    final recipes = [for (var i = 0; i < 6; i++) buildRecipe('r$i')];
    final slots = [
      for (var i = 0; i < 7; i++) MealSlot('s$i', '2026-01-0${i + 1}', 'Dinner')
    ];
    final context = PlannerContext(
        slots: slots,
        recipes: recipes,
        seed: 7,
        maximumRepeats: 2,
        maxNodes: 500);
    final first = planner.plan(context);
    final second = planner.plan(context);
    expect(first.status, PlannerStatus.validPlan);
    expect(second.status, PlannerStatus.validPlan);
    expect(first.meals.map((m) => m.recipe.id),
        second.meals.map((m) => m.recipe.id));
    expect(first.visited, second.visited);
    expect(planner.validate(first.meals, context), isEmpty);
    expect(first.quality!.preservedMeals, 0);
  });

  test('guided search stops after a deterministic valid bounded sample', () {
    final recipes = [for (var i = 0; i < 6; i++) buildRecipe('r$i')];
    final slots = [
      for (var i = 0; i < 7; i++)
        MealSlot('s$i', '2026-01-0${i + 1}', 'dinner')
    ];
    final context = PlannerContext(
        slots: slots,
        recipes: recipes,
        seed: 7,
        maxNodes: 20000,
        maximumRepeats: 2,
        objectives: [PlannerObjective.practicalPreference]);
    final first = planner.plan(context);
    final second = planner.plan(context);
    expect(first.status, PlannerStatus.validPlan);
    expect(first.visited, lessThan(20000));
    expect(first.visited, second.visited);
    expect(first.quality!.canonical, second.quality!.canonical);
    expect(first.diagnostics.join(' '), contains('no global optimality claim'));
    expect(planner.validate(first.meals, context), isEmpty);
  });

  test('guided search does not stop early without a valid plan', () {
    final recipes = [for (var i = 0; i < 4; i++) buildRecipe('r$i')];
    final slots = [
      for (var i = 0; i < 6; i++)
        MealSlot('s$i', '2026-01-01', 'dinner')
    ];
    final context = PlannerContext(
        slots: slots,
        recipes: recipes,
        seed: 7,
        maxNodes: 300,
        constraints: [
          NumericConstraint(NutrientKey.energyKcal, Exact.zero, Exact.zero)
        ],
        objectives: [PlannerObjective.practicalPreference]);
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.searchExhausted);
    expect(result.visited, greaterThan(300));
    expect(result.meals, isEmpty);
  });

  test('guided repeat capacity reserves shared recipes for restricted slots', () {
    final shared = buildRecipe('shared');
    final alternative = buildRecipe('alternative');
    final slots = [
      for (var i = 0; i < 4; i++)
        MealSlot('s$i', '2026-01-01', 'dinner')
    ];
    final context = PlannerContext(
        slots: slots,
        recipes: [shared, alternative],
        seed: 0,
        maxNodes: 100,
        maximumRepeats: 2,
        portions: [for (var i = 1; i <= 8; i++) Exact.parse('$i')],
        recipeIdsBySlot: {
          's0': {'shared', 'alternative'},
          's1': {'shared', 'alternative'},
          's2': {'shared'},
          's3': {'shared'}
        },
        recipePreferenceRanks: {'shared': 0, 'alternative': 1},
        objectives: [PlannerObjective.practicalPreference]);
    final result = planner.plan(context);
    expect(result.status, PlannerStatus.validPlan);
    expect(result.meals.map((meal) => meal.recipe.id),
        ['alternative', 'alternative', 'shared', 'shared']);
    expect(planner.validate(result.meals, context), isEmpty);
  });

  test('grocery aggregation sorts deterministically and merges units', () {
    final recipe = RecipeVersion(
        id: 'mixed',
        revision: 1,
        name: 'mixed',
        servings: Exact.one,
        minutes: 5,
        allergens: {},
        ingredients: [
          RecipeIngredient(
              testFood('b', {NutrientKey.energyKcal: NutrientReported(10)},
                  allergens: {}),
              Exact.parse('100')),
          RecipeIngredient(
              testFood('a', {NutrientKey.energyKcal: NutrientReported(10)},
                  allergens: {}),
              Exact.parse('50')),
        ]);
    final lines = groceriesFor([meal(recipe)]);
    expect(lines.map((l) => l.foodId), ['a', 'b']);
    expect(lines.first.grams, Exact.parse('50'));
    expect(lines.last.grams, Exact.parse('100'));
  });

  test('medical constraints have no relaxation path', () {
    final recipe = buildRecipe('r',
        allergens: {'milk'}, ingredientAllergens: {'milk'});
    final context = PlannerContext(
        slots: [slot],
        recipes: [recipe],
        seed: 1,
        strictExclusions: {'milk'});
    final repair = planner.repair(context, []);
    expect(repair.status, PlannerStatus.provenInfeasible);
    expect(repair.relaxations, isEmpty);
    expect(context.strictExclusions, {'milk'});
  });

  group('explicit recipe preference', () {
    test('default order places preference after guidance, before effort', () {
      expect(defaultPlannerObjectives, [
        PlannerObjective.targetProximity,
        PlannerObjective.dataCompleteness,
        PlannerObjective.guidance,
        PlannerObjective.recipePreference,
        PlannerObjective.cookingEffort,
        PlannerObjective.ingredientReuse,
        PlannerObjective.variety,
      ]);
    });

    test('preferred recipe wins an otherwise exact tie', () {
      final a = buildRecipe('a');
      final b = buildRecipe('b');
      final plain = PlannerContext(slots: [slot], recipes: [a, b], seed: 1);
      expect(planner.plan(plain).meals.single.recipe.id, 'a');
      final preferred = PlannerContext(
          slots: [slot],
          recipes: [a, b],
          seed: 1,
          preferredRecipeIds: {'b'});
      final result = planner.plan(preferred);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.single.recipe.id, 'b');
      expect(result.quality!.scores[PlannerObjective.recipePreference],
          Exact.zero);
      final onlyPreference = PlannerContext(
          slots: [slot],
          recipes: [a],
          seed: 1,
          objectives: const [PlannerObjective.recipePreference],
          preferredRecipeIds: {'other'});
      expect(
          planner
              .plan(onlyPreference)
              .quality!
              .scores[PlannerObjective.recipePreference],
          Exact.one);
    });

    test('target proximity outranks preference', () {
      final near = buildRecipe('z-near',
          nutrients: {NutrientKey.energyKcal: NutrientReported(300)});
      final farPreferred = buildRecipe('a-far',
          nutrients: {NutrientKey.energyKcal: NutrientReported(400)});
      final context = PlannerContext(
          slots: [slot],
          recipes: [near, farPreferred],
          seed: 1,
          constraints: [
            NumericConstraint(
                NutrientKey.energyKcal, Exact.parse('100'), Exact.parse('500'))
          ],
          preferredRecipeIds: {'a-far'});
      final result = planner.plan(context);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.single.recipe.id, 'z-near');
    });

    test('preference outranks cooking effort', () {
      final quick = buildRecipe('z-quick', minutes: 10);
      final slowPreferred = buildRecipe('a-slow', minutes: 30);
      final context = PlannerContext(
          slots: [slot],
          recipes: [quick, slowPreferred],
          seed: 1,
          preferredRecipeIds: {'a-slow'});
      final result = planner.plan(context);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.single.recipe.id, 'a-slow');
    });

    test('empty preference set is fully inert', () {
      final recipes = [for (var i = 0; i < 4; i++) buildRecipe('r$i')];
      final slots = [
        for (var i = 0; i < 3; i++)
          MealSlot('s$i', '2026-01-0${i + 1}', 'Dinner')
      ];
      final base =
          PlannerContext(slots: slots, recipes: recipes, seed: 5);
      final empty = PlannerContext(
          slots: slots,
          recipes: recipes,
          seed: 5,
          preferredRecipeIds: const {});
      final baseline = planner.plan(base);
      final result = planner.plan(empty);
      expect(result.status, baseline.status);
      expect(result.visited, baseline.visited);
      expect(result.meals.map((m) => m.recipe.id),
          baseline.meals.map((m) => m.recipe.id));
      expect(result.quality!.canonical, baseline.quality!.canonical);
      expect(result.quality!.scores, baseline.quality!.scores);
      expect(result.quality!.scores[PlannerObjective.recipePreference],
          Exact.zero);
    });

    test('nonmatching preference ids do not change selection or search', () {
      final recipes = [for (var i = 0; i < 4; i++) buildRecipe('r$i')];
      final slots = [
        for (var i = 0; i < 3; i++)
          MealSlot('s$i', '2026-01-0${i + 1}', 'Dinner')
      ];
      final base =
          PlannerContext(slots: slots, recipes: recipes, seed: 5);
      final other = PlannerContext(
          slots: slots,
          recipes: recipes,
          seed: 5,
          preferredRecipeIds: {'missing'});
      final baseline = planner.plan(base);
      final result = planner.plan(other);
      expect(result.status, baseline.status);
      expect(result.visited, baseline.visited);
      expect(result.meals.map((m) => m.recipe.id),
          baseline.meals.map((m) => m.recipe.id));
      expect(result.quality!.canonical, baseline.quality!.canonical);
      // A non-empty preference set still reports the literal share: no meal
      // is explicitly preferred, but every plan ties so ranking is unchanged.
      expect(result.quality!.scores[PlannerObjective.recipePreference],
          Exact.one);
    });

    test('blank ids are rejected and the stored set is frozen', () {
      final recipe = buildRecipe('r');
      for (final ids in [<String>{''}, <String>{'  '}]) {
        expect(
            () => PlannerContext(
                slots: [slot],
                recipes: [recipe],
                seed: 1,
                preferredRecipeIds: ids),
            throwsArgumentError);
      }
      final context = PlannerContext(
          slots: [slot],
          recipes: [recipe],
          seed: 1,
          preferredRecipeIds: {'r'});
      expect(() => context.preferredRecipeIds.add('x'),
          throwsUnsupportedError);
    });

    test('preference matches stable ids, never display names', () {
      RecipeVersion named(String id, String name) => RecipeVersion(
          id: id,
          revision: 1,
          name: name,
          servings: Exact.one,
          minutes: 10,
          allergens: const {},
          ingredients: [
            RecipeIngredient(
                testFood('food-$id',
                    {NutrientKey.energyKcal: NutrientReported(100)}),
                Exact.parse('100'))
          ]);
      final zPreferredName = named('z', 'preferred');
      final a = named('a', 'other');
      final byName = PlannerContext(
          slots: [slot],
          recipes: [zPreferredName, a],
          seed: 1,
          preferredRecipeIds: {'preferred'});
      expect(planner.plan(byName).meals.single.recipe.id, 'a');
      final byId = PlannerContext(
          slots: [slot],
          recipes: [zPreferredName, a],
          seed: 1,
          preferredRecipeIds: {'z'});
      expect(planner.plan(byId).meals.single.recipe.id, 'z');
    });

    test('preference cannot select an older recipe revision', () {
      final old = buildRecipe('r', revision: 1);
      final current = buildRecipe('r', revision: 2);
      final context = PlannerContext(
          slots: [slot],
          recipes: [old, current],
          seed: 1,
          preferredRecipeIds: {'r'});
      final result = planner.plan(context);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.single.recipe.revision, 2);
      expect(planner.validate([meal(old)], context),
          contains('RECIPE_REVISION_MISMATCH'));
    });

    test('allergy exclusion dominates preference', () {
      final safe = buildRecipe('safe');
      final preferredUnsafe = buildRecipe('preferred-unsafe',
          allergens: {'milk'}, ingredientAllergens: {'milk'});
      final context = PlannerContext(
          slots: [slot],
          recipes: [safe, preferredUnsafe],
          seed: 1,
          strictExclusions: {'milk'},
          preferredRecipeIds: {'preferred-unsafe'});
      final result = planner.plan(context);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.single.recipe.id, 'safe');
      final onlyUnsafe = PlannerContext(
          slots: [slot],
          recipes: [preferredUnsafe],
          seed: 1,
          strictExclusions: {'milk'},
          preferredRecipeIds: {'preferred-unsafe'});
      expect(planner.plan(onlyUnsafe).status, PlannerStatus.provenInfeasible);
      expect(planner.repair(onlyUnsafe, const []).relaxations, isEmpty);
    });

    test('unavailable ingredients dominate preference', () {
      final available = buildRecipe('available');
      final unavailable =
          buildRecipe('preferred-unavailable', foodId: 'missing-food');
      final context = PlannerContext(
          slots: [slot],
          recipes: [available, unavailable],
          seed: 1,
          unavailableFoodIds: {'missing-food'},
          preferredRecipeIds: {'preferred-unavailable'});
      final result = planner.plan(context);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.single.recipe.id, 'available');
      final onlyUnavailable = PlannerContext(
          slots: [slot],
          recipes: [unavailable],
          seed: 1,
          unavailableFoodIds: {'missing-food'},
          preferredRecipeIds: {'preferred-unavailable'});
      expect(
          planner.plan(onlyUnavailable).status, PlannerStatus.provenInfeasible);
      expect(planner.repair(onlyUnavailable, const []).relaxations, isEmpty);
    });

    test('pinned and unchanged meals dominate preference', () {
      final a = buildRecipe('a');
      final b = buildRecipe('b');
      final context = PlannerContext(
          slots: [slot],
          recipes: [a, b],
          seed: 1,
          preferredRecipeIds: {'b'});
      final pinnedResult = planner.plan(context, existing: [meal(a, pinned: true)]);
      expect(pinnedResult.meals.single.recipe.id, 'a');
      expect(pinnedResult.quality!.preservedMeals, 1);
      final unchanged = planner.plan(context, existing: [meal(a)]);
      expect(unchanged.meals.single.recipe.id, 'a');
      expect(unchanged.diagnostics, ['Original plan retained']);
    });

    test('preference score is the exact share of non-preferred meals', () {
      final a = buildRecipe('a');
      final b = buildRecipe('b');
      const first = MealSlot('s0', '2026-01-01', 'Dinner');
      const second = MealSlot('s1', '2026-01-02', 'Dinner');
      final context = PlannerContext(
          slots: [first, second],
          recipes: [a, b],
          seed: 1,
          maximumRepeats: 1,
          preferredRecipeIds: {'a'});
      final result = planner.plan(context);
      expect(result.status, PlannerStatus.validPlan);
      expect(result.meals.map((m) => m.recipe.id).toSet(), {'a', 'b'});
      expect(
          result.quality!.scores[PlannerObjective.recipePreference],
          Exact.parse('1') / Exact.parse('2'));
    });

    test('same seed and preferences produce the same bounded plan', () {
      final recipes = [for (var i = 0; i < 3; i++) buildRecipe('r$i')];
      final slots = [
        for (var i = 0; i < 4; i++)
          MealSlot('s$i', '2026-01-0${i + 1}', 'Dinner')
      ];
      final context = PlannerContext(
          slots: slots,
          recipes: recipes,
          seed: 11,
          maximumRepeats: 2,
          preferredRecipeIds: {'r1'});
      final first = planner.plan(context);
      final second = planner.plan(context);
      expect(first.status, PlannerStatus.validPlan);
      expect(second.status, PlannerStatus.validPlan);
      expect(first.meals.map((m) => m.recipe.id),
          second.meals.map((m) => m.recipe.id));
      expect(first.visited, second.visited);
      expect(first.quality!.canonical, second.quality!.canonical);
      expect(
          first.quality!.scores[PlannerObjective.recipePreference],
          Exact.parse('1') / Exact.parse('2'));
    });

    test('accepted relaxation preserves preferences and replans', () {
      final slow = buildRecipe('slow', minutes: 30);
      final context = PlannerContext(
          slots: [slot],
          recipes: [slow],
          seed: 1,
          maximumMinutes: 10,
          preferredRecipeIds: {'slow'});
      final repair = planner.repair(context, const []);
      expect(repair.status, PlannerStatus.proposedRelaxation);
      final time = repair.relaxations
          .firstWhere((r) => r.kind == PlannerRelaxationKind.maximumMinutes);
      final accepted = planner.acceptRelaxation(context, time,
          confirmed: true, expectedRevision: 1);
      expect(accepted.context.revision, 2);
      expect(accepted.context.preferredRecipeIds, {'slow'});
      expect(accepted.result.status, PlannerStatus.validPlan);
      expect(accepted.result.meals.single.recipe.id, 'slow');
      expect(accepted.result.quality!.scores[PlannerObjective.recipePreference],
          Exact.zero);
    });
  });
}
