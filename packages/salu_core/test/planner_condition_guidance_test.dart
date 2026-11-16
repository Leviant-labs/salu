import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food _food(String id, Map<NutrientKey, NutrientValue> nutrients,
        {Set<String>? allergens = const {}}) =>
    Food(
      id: id,
      name: id,
      per100g: NutrientProfile(nutrients),
      source: FoodSource(dataset: 'test', datasetId: id),
      allergens: allergens,
    );

RecipeVersion _recipe(String id, Map<NutrientKey, NutrientValue> nutrients,
        {Set<String>? ingredientAllergens = const {}}) =>
    RecipeVersion(
      id: id,
      revision: 1,
      name: id,
      minutes: 10,
      servings: Exact.one,
      ingredients: [
        RecipeIngredient(
            _food('food-$id', nutrients, allergens: ingredientAllergens),
            Exact.parse('100'))
      ],
    );

ConditionGuidanceAssessment _assessment(Set<PlanningCondition> declared,
        {Set<String> exclusions = const {}}) =>
    ConditionGuidancePolicy.assess(
      input: ConditionGuidanceInput(
        policyVersion: ConditionGuidancePolicy.version,
        declaration: {for (final condition in declared) condition.name: true},
      ),
      strictExclusions: exclusions,
    );

void main() {
  const planner = PlannerService();
  const slot = MealSlot('s0', '2026-01-01', 'Dinner');

  test('cholesterol guidance changes the selected meal', () {
    final high = _recipe('a-high-sat', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.saturatedFatG: NutrientReported(10),
    });
    final low = _recipe('b-low-sat', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.saturatedFatG: NutrientReported(1),
    });
    final plain = planner.plan(
        PlannerContext(slots: [slot], recipes: [high, low], seed: 1));
    expect(plain.status, PlannerStatus.validPlan);
    expect(plain.meals.single.recipe.id, 'a-high-sat',
        reason: 'without condition guidance the canonical tie-break wins');

    final guided = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [high, low],
        seed: 1,
        conditionGuidance:
            _assessment({PlanningCondition.highCholesterol})));
    expect(guided.status, PlannerStatus.validPlan);
    expect(guided.meals.single.recipe.id, 'b-low-sat');
    expect(guided.quality!.scores[PlannerObjective.guidance],
        isNot(Exact.zero));
  });

  test('diabetes fibre guidance changes the selected meal', () {
    final lowFibre = _recipe('a-low-fibre', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.fiberG: NutrientReported(1),
    });
    final highFibre = _recipe('b-high-fibre', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.fiberG: NutrientReported(10),
    });
    final plain = planner.plan(PlannerContext(
        slots: [slot], recipes: [lowFibre, highFibre], seed: 1));
    expect(plain.meals.single.recipe.id, 'a-low-fibre');

    final guided = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [lowFibre, highFibre],
        seed: 1,
        conditionGuidance: _assessment({PlanningCondition.diabetes})));
    expect(guided.meals.single.recipe.id, 'b-high-fibre');
  });

  test('total sugars are not treated as added sugars for diabetes', () {
    final highTotal = _recipe('a-high-total-sugar', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.sugarsG: NutrientReported(20),
    });
    final lowTotal = _recipe('b-low-total-sugar', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.sugarsG: NutrientReported(1),
    });
    final guided = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [highTotal, lowTotal],
        seed: 1,
        conditionGuidance: _assessment({PlanningCondition.diabetes})));
    expect(guided.meals.single.recipe.id, 'a-high-total-sugar',
        reason: 'total sugars must not be ranked as added sugars');
  });

  test('total fat is not treated as saturated fat for cholesterol', () {
    final highFat = _recipe('a-high-total-fat', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.fatG: NutrientReported(30),
    });
    final lowFat = _recipe('b-low-total-fat', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.fatG: NutrientReported(1),
    });
    final guided = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [highFat, lowFat],
        seed: 1,
        conditionGuidance: _assessment({PlanningCondition.highCholesterol})));
    expect(guided.meals.single.recipe.id, 'a-high-total-fat',
        reason: 'total fat must not be ranked as saturated fat');
  });

  test('unknown guidance nutrient is never preferred over a known value', () {
    final unknown = _recipe('a-unknown', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.proteinG: NutrientReported(10),
    });
    final knownZero = _recipe('b-known-zero', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.freeSugarsG: NutrientReported(0),
    });
    final guided = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [unknown, knownZero],
        seed: 1,
        conditionGuidance: _assessment({PlanningCondition.highTriglycerides})));
    expect(guided.status, PlannerStatus.validPlan);
    expect(guided.meals.single.recipe.id, 'b-known-zero',
        reason: 'missing free sugar is unknown, never a favourable zero');
  });

  test('known fibre beats an unknown fibre field', () {
    final unknown = _recipe('a-unknown-fibre', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.proteinG: NutrientReported(10),
    });
    final known = _recipe('b-known-fibre', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.fiberG: NutrientReported(5),
    });
    final guided = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [unknown, known],
        seed: 1,
        conditionGuidance: _assessment({PlanningCondition.diabetes})));
    expect(guided.meals.single.recipe.id, 'b-known-fibre');
  });

  test('high-risk conflict abstains instead of ranking with another condition',
      () {
    final high = _recipe('a-high-sat', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.saturatedFatG: NutrientReported(10),
    });
    final low = _recipe('b-low-sat', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.saturatedFatG: NutrientReported(1),
    });
    final assessment = _assessment({
      PlanningCondition.diabetes,
      PlanningCondition.lowBloodGlucoseHistoryOrRisk,
    });
    expect(assessment.abstained, isTrue);
    expect(assessment.directives, isEmpty);
    final result = planner.plan(PlannerContext(
        slots: [slot],
        recipes: [high, low],
        seed: 1,
        conditionGuidance: assessment));
    expect(result.meals.single.recipe.id, 'a-high-sat',
        reason: 'abstention must not silently fall back to a condition rank');
  });

  test('condition guidance never bypasses strict allergen exclusions', () {
    final unknownAllergen = _recipe('a-unknown-allergen', {
      NutrientKey.energyKcal: NutrientReported(100),
      NutrientKey.saturatedFatG: NutrientReported(1),
    }, ingredientAllergens: null);
    final context = PlannerContext(
        slots: [slot],
        recipes: [unknownAllergen],
        seed: 1,
        strictExclusions: const {'peanut'},
        conditionGuidance:
            _assessment({PlanningCondition.foodAllergy},
                exclusions: const {'peanut'}));
    expect(planner.validate([PlannedMeal(slot, unknownAllergen, Exact.one)],
            context),
        contains('ALLERGEN_STATUS_UNKNOWN'));
    expect(planner.plan(context).status, PlannerStatus.provenInfeasible);
    expect(planner.repair(context, const []).relaxations, isEmpty);
  });

  test('assessment must match the context strict exclusions', () {
    final recipe = _recipe('a', {
      NutrientKey.energyKcal: NutrientReported(100),
    });
    expect(
        () => PlannerContext(
            slots: [slot],
            recipes: [recipe],
            seed: 1,
            strictExclusions: const {'peanut'},
            conditionGuidance:
                _assessment({PlanningCondition.foodAllergy},
                    exclusions: const {'milk'})),
        throwsArgumentError);
  });

  test('report marks all-unknown condition data insufficient', () {
    final recipe = _recipe('a', {
      NutrientKey.energyKcal: NutrientReported(100),
    });
    final assessment = _assessment({PlanningCondition.diabetes});
    final report = conditionGuidanceReportFor(
        assessment, [PlannedMeal(slot, recipe, Exact.one)]);
    expect(report.hasTailoredGuidance, isFalse);
    expect(report.allDirectiveDataInsufficient, isTrue);
    expect(report.explanations.map((e) => e.code),
        contains('CONDITION_NUTRIENT_DATA_INSUFFICIENT'));
  });
}
