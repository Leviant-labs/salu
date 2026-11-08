import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

const protein = NutrientIdentity('protein', 'g', 'protein');
NutrientObservation obs(
        {String? amount = '10',
        ObservationQualifier q = ObservationQualifier.reported,
        NutrientIdentity nutrient = protein,
        FoodUnit unit = FoodUnit.g}) =>
    NutrientObservation(
        nutrient: nutrient,
        basis: FoodAmount('100', unit),
        qualifier: q,
        sourceId: 'label',
        sourceVersion: 'v1',
        origin: 'label',
        amount: amount);
ObservedFood food(String id,
        {String quantity = '150', List<NutrientObservation>? values}) =>
    ObservedFood(
        id: id,
        quantity: FoodAmount(quantity, FoodUnit.g),
        observations: values ?? [obs()]);
Food recipeFood({Set<String>? allergens = const {}, double? energy = 100}) =>
    Food(
        id: 'ingredient',
        name: 'ingredient',
        per100g: NutrientProfile({
          if (energy != null) NutrientKey.energyKcal: NutrientReported(energy),
          NutrientKey.proteinG: NutrientReported(10)
        }),
        source: const FoodSource(dataset: 'test', datasetId: '1'),
        allergens: allergens);
RecipeVersion recipe(String id,
        {Set<String>? allergens = const {}, double? energy = 100}) =>
    RecipeVersion(
        id: id,
        revision: 1,
        name: id,
        ingredients: [
          RecipeIngredient(recipeFood(allergens: allergens, energy: energy),
              Exact.parse('100'))
        ],
        servings: Exact.one,
        minutes: 10,
        allergens: allergens);
void main() {
  test('recipe and nutrient snapshots retain exact repeating allocations', () {
    final original =
        NutrientProfile({NutrientKey.proteinG: NutrientReported(10)});
    final third = original.scaledExact(Exact.one / Exact.parse('3'));
    final restored = NutrientProfile.fromJson(third.toJson());
    expect(restored[NutrientKey.proteinG].exactValue! * Exact.parse('3'),
        Exact.parse('10'));
    expect(NutrientReported(1e-7).exactValue, Exact.parse('0.0000001'));
  });
  test(
      'recipe versions freeze ingredient exclusions and compare by definitions',
      () {
    final mutable = <String>{'milk'};
    final f = recipeFood(allergens: mutable);
    final r = RecipeVersion(
        id: 'frozen',
        revision: 1,
        name: 'Frozen',
        ingredients: [RecipeIngredient(f, Exact.parse('100'))],
        servings: Exact.one,
        minutes: 10,
        allergens: {'milk'});
    mutable.clear();
    expect(r.ingredients.single.food.allergens, {'milk'});
    final copy = RecipeVersion(
        id: 'frozen',
        revision: 1,
        name: 'Frozen',
        ingredients: [
          RecipeIngredient(recipeFood(allergens: {'milk'}), Exact.parse('100'))
        ],
        servings: Exact.one,
        minutes: 10,
        allergens: {'milk'});
    expect(copy, r);
    final c = PlannerContext(
        slots: [const MealSlot('s', 'day', 'Dinner')],
        recipes: [copy],
        seed: 1);
    final original = [PlannedMeal(c.slots.single, r, Exact.one)];
    expect(const PlannerService().repair(c, original).diagnostics,
        ['Original plan retained']);
  });

  test('decimal scaling is exact; fractions round-trip without loss', () {
    expect(Exact.parse('0.1') + Exact.parse('0.2'), Exact.parse('0.3'));
    final third = Exact.one / Exact.parse('3');
    expect(Exact.fromJson(third.toJson()) * Exact.parse('3'), Exact.one);
  });
  test('native volume never needs density; incompatible dimensions ask', () {
    const energy = NutrientIdentity('energy', 'kcal', 'label-energy');
    final f = ObservedFood(
        id: 'drink',
        quantity: FoodAmount('250', FoodUnit.ml),
        observations: [obs(amount: '40', nutrient: energy, unit: FoodUnit.ml)]);
    expect(
        const FoodCalculationService()
            .summarize(energy, [f], DiaryCompleteness.userDeclaredComplete)
            .recordedSum,
        Exact.parse('100'));
    expect(
        () => quantityRatio(
            FoodAmount('100', FoodUnit.g), FoodAmount('100', FoodUnit.ml), []),
        throwsStateError);
  });
  test('partial sums identify every missing source; all missing has no total',
      () {
    final s = const FoodCalculationService().summarize(
        protein,
        [food('a'), food('b', values: [])],
        DiaryCompleteness.userDeclaredComplete);
    expect(s.recordedSum, Exact.parse('15'));
    expect(s.missing, ['b']);
    expect(s.permitsComparison, isFalse);
    expect(
        const FoodCalculationService()
            .summarize(
                protein, [food('b', values: [])], DiaryCompleteness.unknown)
            .recordedSum,
        isNull);
  });
  test('trace does not become an exact zero; reported zero retains qualifier',
      () {
    final trace = obs(amount: null, q: ObservationQualifier.trace);
    expect(trace.amount, isNull);
    final zero = obs(amount: '0', q: ObservationQualifier.reportedZero);
    expect(NutrientObservation.fromJson(zero.toJson()).qualifier,
        ObservationQualifier.reportedZero);
  });
  test('known water mass cannot certify missing iodine or free sugars', () {
    const iodine = NutrientIdentity('iodine', 'ug', 'iodine');
    final summary = const FoodCalculationService().summarize(
        iodine,
        [
          food('water',
              quantity: '1000', values: [obs(amount: '0', nutrient: iodine)]),
          food('tiny', quantity: '1', values: [])
        ],
        DiaryCompleteness.userDeclaredComplete);
    expect(summary.permitsComparison, isFalse);
  });
  test('different nutrient definitions never collapse', () {
    const eu =
        NutrientIdentity('carbohydrate', 'g', 'eu-available-includes-polyols');
    const us = NutrientIdentity('carbohydrate', 'g', 'us-total-includes-fibre');
    final f = food('a', values: [obs(nutrient: eu)]);
    expect(
        const FoodCalculationService()
            .summarize(us, [f], DiaryCompleteness.userDeclaredComplete)
            .recordedSum,
        isNull);
  });
  test('estimated decisive values do not authorize comparisons', () {
    final s = const FoodCalculationService().summarize(
        protein,
        [
          food('a', values: [obs(q: ObservationQualifier.estimated)])
        ],
        DiaryCompleteness.userDeclaredComplete);
    final r = ReferencePolicy(
        id: 'test',
        nutrient: protein,
        kind: ReferenceKind.ai,
        source: 'fixture',
        edition: '1',
        temporalBasis: 'day',
        approved: true,
        populationMatches: true,
        lower: Exact.parse('25'));
    expect(const ReferenceComparisonService().compare(s, r),
        ComparisonStatus.insufficientData);
  });
  test('safe intake level is not a toxicity UL', () {
    final s = const FoodCalculationService().summarize(
        protein, [food('a')], DiaryCompleteness.userDeclaredComplete);
    final r = ReferencePolicy(
        id: 'safe',
        nutrient: protein,
        kind: ReferenceKind.safeIntakeLevel,
        source: 'fixture',
        edition: '1',
        temporalBasis: 'day',
        approved: true,
        populationMatches: true,
        upper: Exact.one);
    expect(const ReferenceComparisonService().compare(s, r),
        ComparisonStatus.referenceNotApplicable);
  });
  test('legacy combine counts omitted keys and never certifies partial data',
      () {
    final result = NutrientProfile.combine([
      NutrientProfile({NutrientKey.proteinG: NutrientMeasured(10)}),
      const NutrientProfile.empty()
    ]);
    expect(result[NutrientKey.proteinG]!.isComplete, isFalse);
    expect(NutrientSum.noData.recordedValue, isNull);
  });
  test('safety routes survive empty logs and adaptation remains blocked', () {
    final result = const CoachingService().checkIn(
        const SafetyProfile(
            adult: false, pregnant: true, clinicalNeed: true, symptoms: true),
        []);
    expect(result.safety.recordingAllowed, isTrue);
    expect(result.safety.automaticTargetsAllowed, isFalse);
    expect(
        result.safety.reasonCodes,
        containsAll(
            ['MINOR', 'PREGNANCY', 'CLINICAL_NUTRITION', 'SYMPTOMS_REVIEW']));
    expect(result.findings.first.action, CoachingAction.seekAdvice);
    expect(result.adaptationStatus, 'disabled');
    expect(result.findings.any((f) => f.action == CoachingAction.improveData),
        isTrue);
    expect(result.findings.any((f) => f.action == CoachingAction.hold), isFalse);
  });
  test('empty history does not support a hold-course finding', () {
    final result = const CoachingService().checkIn(const SafetyProfile(), []);
    expect(result.findings.single.action, CoachingAction.improveData);
    expect(result.inputRevisions, isEmpty);
    expect(result.adaptationStatus, 'disabled');
  });
  test('missing weekends never create a TEE estimate', () {
    final days = List.generate(
        28,
        (i) => CoachingDay(
            date: 'day-$i',
            revision: 1,
            completeness: i % 7 > 4
                ? DiaryCompleteness.unknown
                : DiaryCompleteness.userDeclaredComplete));
    final result = const CoachingService().checkIn(const SafetyProfile(), days);
    expect(result.adaptationStatus, 'disabled');
    expect(result.findings.any((f) => f.action == CoachingAction.improveData),
        isTrue);
  });
  test('targets retain ownership; impossible macro allocation is rejected', () {
    expect(
        () => DeclaredTarget(
            id: 't',
            revision: 1,
            origin: TargetOrigin.userDeclared,
            effectiveDate: '2026-11-08',
            policyVersion: 'declared',
            energyKcal: Exact.parse('100'),
            proteinG: Exact.parse('100')),
        throwsStateError);
    expect(
        const TargetService().generateAutomaticTarget(), 'POLICY_NOT_APPROVED');
    expect(
        const TargetService().proposeAdaptation(), 'ADAPTATION_NOT_APPROVED');
  });
  test('planner repeat allowance of two does not make seven dinners impossible',
      () {
    final c = PlannerContext(
        slots: List.generate(7, (i) => MealSlot('s$i', 'day$i', 'Dinner')),
        recipes: List.generate(6, (i) => recipe('r$i')),
        seed: 7,
        maximumRepeats: 2);
    final a = const PlannerService().plan(c);
    final b = const PlannerService().plan(c);
    expect(a.status, PlannerStatus.validPlan);
    expect(a.meals.length, 7);
    expect(a.meals.map((m) => m.recipe.id), b.meals.map((m) => m.recipe.id));
    expect(const PlannerService().validate(a.meals, c), isEmpty);
    expect(
        identical(const PlannerService().repair(c, a.meals).meals.first,
            a.meals.first),
        isTrue);
  });
  test(
      'unknown strict allergens are rejected independently of energy eligibility',
      () {
    final c = PlannerContext(
        slots: [const MealSlot('a', 'day', 'Dinner')],
        recipes: [recipe('unknown', allergens: null)],
        seed: 1,
        strictExclusions: {'gluten'});
    expect(
        const PlannerService().plan(c).status, PlannerStatus.provenInfeasible);
  });
  test('pinned medical conflict cannot be relaxed', () {
    final r = recipe('bad', allergens: {'milk'});
    const slot = MealSlot('a', 'day', 'Dinner');
    final c = PlannerContext(
        slots: [slot],
        recipes: [r, recipe('good')],
        seed: 1,
        strictExclusions: {'milk'});
    expect(
        const PlannerService().plan(c,
            existing: [PlannedMeal(slot, r, Exact.one, pinned: true)]).status,
        PlannerStatus.targetConflict);
  });
  test('search exhaustion, insufficient nutrient data and infeasibility differ',
      () {
    final slots = [const MealSlot('a', 'day', 'Dinner')];
    expect(
        const PlannerService()
            .plan(PlannerContext(
                slots: slots, recipes: [recipe('a')], seed: 1, maxNodes: 1))
            .status,
        PlannerStatus.searchExhausted);
    final c = PlannerContext(
        slots: slots,
        recipes: [recipe('a', energy: null)],
        seed: 1,
        constraints: [
          NumericConstraint(
              NutrientKey.energyKcal, Exact.one, Exact.parse('1000'))
        ]);
    expect(
        const PlannerService().plan(c).status, PlannerStatus.insufficientData);
  });
  test('cooked batch allocations cannot exceed cross-week stock', () {
    final batch = CookedBatch(
        id: 'batch',
        recipe: recipe('r'),
        revision: 1,
        available: Exact.parse('600'),
        unit: FoodUnit.g,
        finishedWeightG: Exact.parse('600'));
    final a = batch
        .allocate(BatchAllocation('week1', Exact.parse('400'), 'planned'),
            expectedRevision: 1)
        .allocate(BatchAllocation('week2', Exact.parse('200'), 'planned'),
            expectedRevision: 2);
    expect(
        () => a.allocate(
            BatchAllocation('extra', Exact.parse('200'), 'planned'),
            expectedRevision: 3),
        throwsStateError);
    expect(batch.nutrientsFor(Exact.parse('200'))[NutrientKey.proteinG]!.value,
        closeTo(10 / 3, 1e-12));
  });
  test('gram-based batch logging requires measured yield', () {
    expect(
        () => CookedBatch(
            id: 'b',
            recipe: recipe('r'),
            revision: 1,
            available: Exact.parse('500'),
            unit: FoodUnit.g),
        throwsStateError);
  });
  test('draft late result cannot overwrite edited or committed revision', () {
    final draft = MealDraft(id: 'd');
    final edited = draft.edit({'quantity': '150'});
    expect(() => edited.receive(expectedRevision: 1, suggestion: {}),
        throwsStateError);
    final reviewed =
        edited.receive(expectedRevision: 2, suggestion: {'food': 'a'});
    expect(() => reviewed.confirm(expectedRevision: 3, reviewed: false),
        throwsStateError);
    final committed = reviewed.confirm(expectedRevision: 3, reviewed: true);
    expect(() => committed.receive(expectedRevision: 4, suggestion: {}),
        throwsStateError);
  });
  test('consent is not transferable to another purpose, provider or draft', () {
    final now = DateTime.utc(2026, 11, 8);
    final consent = TransferConsent(
        providerId: 'one',
        task: InferenceTask.labelOcr,
        payloadClasses: {'text', 'image'},
        requestId: 'r',
        draftId: 'd',
        draftRevision: 1,
        expiresAt: now.add(const Duration(minutes: 5)));
    bool permits(String p, InferenceTask t, int revision) => consent.permits(
        provider: p,
        purpose: t,
        payload: {'image'},
        request: 'r',
        draft: 'd',
        revision: revision,
        now: now);
    expect(permits('one', InferenceTask.labelOcr, 1), isTrue);
    expect(permits('two', InferenceTask.labelOcr, 1), isFalse);
    expect(permits('one', InferenceTask.mealPhoto, 1), isFalse);
    expect(permits('one', InferenceTask.labelOcr, 2), isFalse);
    consent.revoked = true;
    expect(permits('one', InferenceTask.labelOcr, 1), isFalse);
  });
}
