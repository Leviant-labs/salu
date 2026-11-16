import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

final class _FixedClock implements Clock {
  _FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime nowUtc() => instant.toUtc();
}

Food _food(String id, String name,
        {Preparation preparation = Preparation.raw}) => Food(
      id: id,
      name: name,
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientReported.exact(Exact.parse('100')),
        NutrientKey.proteinG: NutrientReported.exact(Exact.parse('10')),
        NutrientKey.fatG: NutrientReported.exact(Exact.parse('5')),
        NutrientKey.carbohydrateG:
            NutrientReported.exact(Exact.parse('10')),
      }),
      source: FoodSource(dataset: 'test-catalogue', datasetId: id),
      allergens: const {},
      preparation: preparation,
      basisUnit: FoodUnit.g,
      basisValue: '100',
    );

RecipeVersion _recipe(
  String id,
  String ingredientId,
  String ingredientName, {
  String grams = '100',
  String label = 'breakfast',
  int minutes = 10,
  Set<String> dietaryTags = const {},
}) {
  final food = _food(ingredientId, ingredientName);
  return RecipeVersion(
    id: id,
    revision: 1,
    name: 'Recipe $id',
    servings: Exact.one,
    minutes: minutes,
    allergens: const {},
    dietaryTags: dietaryTags,
    ingredients: [
      RecipeIngredient(food, Exact.parse(grams),
          declaredAllergens: const {},
          allergenDeclarationSource: 'guided-test-v1')
    ],
  );
}

Future<void> _seedRecipes(
    AppDatabase db, List<RecipeVersion> recipes, {String prefix = 'seed'}) async {
  for (final recipe in recipes) {
    for (final ingredient in recipe.ingredients) {
      await DriftFoodRepository(db)
          .replaceCatalogueBatch([ingredient.food]);
    }
    final id = '${recipe.id}:${recipe.revision}';
    final workspace = LocalWorkspace(db);
    if (await workspace.read('recipe', id) != null) continue;
    await workspace.put(
      requestId: '$prefix-recipe-$id',
      collection: 'recipe',
      id: id,
      expectedRevision: 0,
      data: recipeSnapshot(recipe),
    );
  }
}

Future<void> _seedContent(AppDatabase db, RecipeVersion recipe,
    {List<String> labels = const ['breakfast', 'lunch', 'dinner'],
    bool coldSuitable = true,
    String costTier = 'lowerCost',
    bool addAlternatives = true,
    String? grainComposition}) async {
  final payload = {
    'schemaVersion': 1,
    'recipeId': recipe.id,
    'revision': recipe.revision,
    'coldSuitable': coldSuitable,
    'costTier': costTier,
    if (grainComposition != null) 'grainComposition': grainComposition,
    'mealLabels': labels,
    'minutes': recipe.minutes,
    'servings': '1',
    'dietaryTags': recipe.dietaryTags.toList()..sort(),
    'titles': {'en': recipe.name, 'pt-PT': recipe.name},
    'descriptions': {'en': 'Test meal.', 'pt-PT': 'Refeição de teste.'},
    'instructions': {
      'en': ['Prepare ${recipe.name}.'],
      'pt-PT': ['Preparar ${recipe.name}.']
    },
  };
  await LocalWorkspace(db).put(
    requestId: 'seed-content-${recipe.id}',
    collection: 'meal-content-v1',
    id: recipe.id,
    expectedRevision: 0,
    data: payload,
  );
  if (addAlternatives) {
    // Four recipes fill seven slots; a fifth leaves a spare for scoped swaps
    // even when the targeted recipe is the only one used once.
    for (var i = 1; i <= 4; i++) {
      final alternative = _recipe('${recipe.id}-alternative-$i',
          'test-food:${recipe.id}:$i', 'Alternative ingredient $i',
          grams: '${100 + i * 10}', minutes: recipe.minutes,
          dietaryTags: recipe.dietaryTags);
      await _seedRecipes(db, [alternative], prefix: 'alternative');
      await _seedContent(db, alternative, labels: labels,
          coldSuitable: coldSuitable, costTier: costTier,
          grainComposition: grainComposition, addAlternatives: false);
    }
  }
}

Future<void> _seedProfile(AppDatabase db, NutritionProfile profile) async {
  await LocalWorkspace(db).put(
    requestId: 'seed-profile',
    collection: 'nutrition-profile-v1',
    id: 'current',
    expectedRevision: 0,
    data: profile.toJson(),
  );
}

GuidedPlanService _service(AppDatabase db) => GuidedPlanService(
      db,
      _FixedClock(DateTime.utc(2026, 11, 10, 12)),
      SequentialIdGenerator(prefix: 'guided'),
    );

void main() {
  group('GuidedPlanService', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    test('proposed lipid declarations reach planning and the accepted plan',
        () async {
      final recipe = _recipe('starter:rice', 'insa-bdca:402', 'Rice');
      await _seedRecipes(db, [recipe]);
      await _seedContent(db, recipe, labels: ['lunch'],
          grainComposition: 'refinedGrain');
      final grainFree = _recipe(
          'starter:grain-free', 'insa-bdca:999', 'Grain-free meal');
      await _seedRecipes(db, [grainFree]);
      await _seedContent(db, grainFree, labels: ['lunch'],
          addAlternatives: false);
      final brown = _recipe('starter:brown', 'insa-bdca:401', 'Raw brown rice',
          minutes: 45);
      await _seedRecipes(db, [brown]);
      await _seedContent(db, brown, labels: ['lunch'],
          grainComposition: 'wholeGrain', addAlternatives: false);
      PlannerContext? observed;
      PlannerResult? generatedResult;
      final service = GuidedPlanService(
        db,
        _FixedClock(DateTime.utc(2026, 11, 10, 12)),
        SequentialIdGenerator(prefix: 'conditions'),
        generator: (context, existing) async {
          observed = context;
          final result = PlannerService().plan(context, existing: existing);
          generatedResult = result;
          return result;
        },
      );
      final draft = await service.propose(
        requestId: 'condition-preview',
        expectedProfileRevision: 0,
        startDate: DiaryDate(2026, 11, 10),
        proposedProfile: NutritionProfile(
            goal: AdultGoal.maintainWeight, mealLabels: ['lunch'],
            maximumCookingMinutes: 45),
        proposedHealthDeclaration: {
          'conditions': {'highTriglycerides': true, 'highCholesterol': true},
        },
      );
      final guidance = observed!.conditionGuidance!;
      expect(guidance.input.declared, {
        PlanningCondition.highTriglycerides,
        PlanningCondition.highCholesterol,
      });
      expect(guidance.directives.map((d) => d.nutrient).toSet(), {
        NutrientKey.freeSugarsG,
        NutrientKey.saturatedFatG,
      });
      expect(observed!.objectives, contains(PlannerObjective.guidance));
      // The declaration is a relative preference, not a prohibition on rice.
      expect(observed!.recipeIdsBySlot.values.every(
          (ids) => ids.contains('starter:rice')), isTrue);
      expect(observed!.recipePreferenceRanks['starter:brown'],
          lessThan(observed!.recipePreferenceRanks['starter:rice']!));
      expect(observed!.recipePreferenceRanks['starter:grain-free'],
          observed!.recipePreferenceRanks['starter:brown'],
          reason: 'grain-free meals are not penalized as refined');
      expect(observed!.recipePreferenceRanks['starter:grain-free'],
          lessThan(observed!.recipePreferenceRanks['starter:rice']!));
      expect(generatedResult!.meals.any((meal) => meal.recipe.id == 'starter:brown'),
          isTrue,
          reason: 'the declared conditions softly prefer the whole-grain variant');
      await service.propose(
        requestId: 'condition-preview-absent',
        expectedProfileRevision: 0,
        startDate: DiaryDate(2026, 11, 10),
        proposedProfile: NutritionProfile(
            goal: AdultGoal.maintainWeight, mealLabels: ['lunch'],
            maximumCookingMinutes: 45),
      );
      expect(observed!.recipePreferenceRanks['starter:brown'],
          observed!.recipePreferenceRanks['starter:rice'],
          reason: 'no lipid declaration means no whole-grain preference');
      expect(observed!.recipePreferenceRanks['starter:grain-free'],
          observed!.recipePreferenceRanks['starter:rice']);
      await service.propose(
        requestId: 'condition-preview-short-time',
        expectedProfileRevision: 0,
        startDate: DiaryDate(2026, 11, 10),
        proposedProfile: NutritionProfile(
            goal: AdultGoal.maintainWeight, mealLabels: ['lunch'],
            maximumCookingMinutes: 30),
        proposedHealthDeclaration: {
          'conditions': {'highTriglycerides': true, 'highCholesterol': true},
        },
      );
      expect(observed!.recipeIdsBySlot.values.every(
          (ids) => !ids.contains('starter:brown')), isTrue,
          reason: 'raw brown rice needs its real cooking time, never trimmed');
      await service.accept(draftId: draft.id, expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0, requestId: 'accept-conditions');
      final input = await PlanService(
              db, _FixedClock(DateTime.utc(2026, 11, 10)),
              SequentialIdGenerator(prefix: 'read-conditions'))
          .readConditionGuidanceInput();
      expect(input.declared, guidance.input.declared);
    });

    test('new onboarding commits proposed profile and display choices together',
        () async {
      final recipes = [
        _recipe('starter:breakfast', 'test:breakfast', 'Breakfast'),
        _recipe('starter:lunch', 'test:lunch', 'Lunch'),
        _recipe('starter:dinner', 'test:dinner', 'Dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (var i = 0; i < recipes.length; i++) {
        await _seedContent(db, recipes[i],
            labels: [['breakfast'], ['lunch'], ['dinner']][i]);
      }
      final service = _service(db);
      final draft = await service.propose(
        requestId: 'new-onboarding',
        expectedProfileRevision: 0,
        startDate: DiaryDate(2026, 11, 10),
        proposedProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
        proposedSettings: {'support': true, 'hideCalorieNudges': true},
        completesOnboarding: true,
      );
      expect(await LocalWorkspace(db).read('nutrition-profile-v1', 'current'), isNull);
      expect(await LocalWorkspace(db).read('preferences', 'app'), isNull);
      await service.accept(draftId: draft.id, expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0, requestId: 'accept-new-onboarding');
      expect(await LocalWorkspace(db).read('nutrition-profile-v1', 'current'), isNotNull);
      final settings = (await LocalWorkspace(db).read('preferences', 'app'))!;
      expect(settings.data['support'], true);
      expect(settings.data['hideCalorieNudges'], true);
      expect(settings.data['onboardingVersion'], 2);
    });

    test('onboarding acceptance is atomic: 21 meals, profile, groceries, zero logs',
        () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour',
            minutes: 10),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice',
            label: 'lunch'),
      ];
      // The planner needs candidates for every label in the default profile.
      // Add one breakfast + one lunch + one dinner recipe sharing foods.
      final dinner = _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens',
          label: 'dinner');
      await _seedRecipes(db, [...recipes, dinner]);
      for (final recipe in [...recipes, dinner]) {
        final label = recipe.id.contains('breakfast')
            ? ['breakfast']
            : recipe.id.contains('lunch')
                ? ['lunch']
                : ['dinner'];
        await _seedContent(db, recipe, labels: label);
      }
      final profile = NutritionProfile(goal: AdultGoal.maintainWeight);
      await _seedProfile(db, profile);

      final service = _service(db);
      final draft = await service.propose(
        requestId: 'onboard-1',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 10),
        completesOnboarding: true,
      );
      expect(draft.status, DraftStatus.review);
      expect(draft.revision, 2);
      expect((draft.values['meals'] as List).length, 21);

      final accepted = await service.accept(
        draftId: draft.id,
        expectedDraftRevision: draft.revision,
        expectedPlanRevision: 0,
        requestId: 'accept-1',
      );
      expect(accepted.status, DraftStatus.committed);

      // Plan has 21 meals across 7 days x 3 labels.
      final plan = await service.planForDate(DiaryDate(2026, 11, 10));
      expect(plan, isNotNull);
      expect(plan!.meals, hasLength(21));
      expect(plan.documentId, 'week:2026-11-10');
      final dates = plan.meals.map((m) => m.slot.date).toSet();
      expect(dates, hasLength(7));
      expect(plan.meals.map((m) => m.slot.label).toSet(),
          {'breakfast', 'lunch', 'dinner'});

      // Zero diary entries were logged.
      expect(await db.select(db.logEntries).get(), isEmpty);

      // Onboarding marker written atomically (old key removed, version 2 set).
      final settings =
          await LocalWorkspace(db).read('preferences', 'app');
      expect(settings, isNotNull);
      expect(settings!.data['onboardingVersion'], 2);
      expect(settings.data.containsKey('onboarded'), isFalse);

      // Guided groceries overlay document exists for this week id.
      final groceries =
          await LocalWorkspace(db).read('groceries', 'week:2026-11-10');
      expect(groceries, isNotNull);
      expect(groceries!.data.keys, isNotEmpty);
    });

    test('next-week acceptance keeps current week selection and separate groceries',
        () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      final profile = NutritionProfile(goal: AdultGoal.maintainWeight);
      await _seedProfile(db, profile);
      final service = _service(db);

      // Current week.
      final draft1 = await service.propose(
        requestId: 'week1',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 10),
        completesOnboarding: true,
      );
      await service.accept(
          draftId: draft1.id,
          expectedDraftRevision: draft1.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-week1');

      // Mark one current-week grocery as checked.
      final currentGroceries =
          await LocalWorkspace(db).read('groceries', 'week:2026-11-10');
      final firstKey = currentGroceries!.data.keys.first;
      await LocalWorkspace(db).put(
        requestId: 'check-current',
        collection: 'groceries',
        id: 'week:2026-11-10',
        expectedRevision: currentGroceries.revision,
        data: {
          for (final e in currentGroceries.data.entries)
            e.key: e.key == firstKey
                ? {...(e.value as Map), 'checked': true}
                : e.value,
        },
      );

      // Next week starting at current end + 1.
      final draft2 = await service.propose(
        requestId: 'week2',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 17),
      );
      expect(draft2.values['planDocumentId'], 'week:2026-11-17');
      await service.accept(
          draftId: draft2.id,
          expectedDraftRevision: draft2.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-week2');

      // Both documents persist; Today still selects the current week.
      final today = await service.planForDate(DiaryDate(2026, 11, 10));
      expect(today!.documentId, 'week:2026-11-10');
      final next = await service.planForDate(DiaryDate(2026, 11, 18));
      expect(next!.documentId, 'week:2026-11-17');
      expect(today.meals, hasLength(21));
      expect(next.meals, hasLength(21));

      // Current-week checkmark survived the next-week acceptance.
      final afterCheck =
          await LocalWorkspace(db).read('groceries', 'week:2026-11-10');
      expect((afterCheck!.data[firstKey] as Map)['checked'], isTrue);
      final replay = await service.accept(
          draftId: draft1.id, expectedDraftRevision: draft1.revision,
          expectedPlanRevision: 0, requestId: 'accept-week1');
      expect(replay.status, DraftStatus.committed);

      final overlapping = await service.propose(
        requestId: 'overlapping-week',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 8),
      );
      await expectLater(
        service.accept(draftId: overlapping.id,
            expectedDraftRevision: overlapping.revision,
            expectedPlanRevision: 0, requestId: 'accept-overlapping-week'),
        throwsA(isA<PlanException>().having(
            (error) => error.code, 'code', 'PLAN_PERIOD_OVERLAP')),
      );
      expect(await LocalWorkspace(db).read('plan', 'week:2026-11-08'), isNull);
    });

    test('failed grocery write rolls back the whole acceptance', () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      final profile = NutritionProfile(goal: AdultGoal.maintainWeight);
      await _seedProfile(db, profile);
      final service = _service(db);
      final draft = await service.propose(
        requestId: 'rollback-1',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 10),
      );
      // Corrupt the grocery overlay so reconcile fails inside the transaction:
      // write invalid data that cannot be reconciled is hard; instead corrupt
      // by bumping the grocery revision so the accept's dependency check fails.
      await LocalWorkspace(db).put(
        requestId: 'bump-groceries',
        collection: 'groceries',
        id: 'week:2026-11-10',
        expectedRevision: 0,
        data: {'unrelated|raw': {'checked': true}},
      );
      await expectLater(
        service.accept(
            draftId: draft.id,
            expectedDraftRevision: draft.revision,
            expectedPlanRevision: 0,
            requestId: 'accept-rollback'),
        throwsA(anything),
      );
      // Nothing was committed: no plan document, draft still in review.
      expect(await LocalWorkspace(db).read('plan', 'week:2026-11-10'), isNull);
      expect((await MealDraftStore(db).read(draft.id))!.status,
          DraftStatus.review);
    });

    test('identical retry returns the original confirmed draft', () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      await _seedProfile(db, NutritionProfile(goal: AdultGoal.maintainWeight));
      final service = _service(db);
      final draft = await service.propose(
        requestId: 'retry-1',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 10),
      );
      final first = await service.accept(
          draftId: draft.id,
          expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-retry');
      final second = await service.accept(
          draftId: draft.id,
          expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-retry');
      expect(second.status, DraftStatus.committed);
      expect(second.revision, first.revision);
      final plan = await service.planForDate(DiaryDate(2026, 11, 10));
      expect(plan!.revision, 1);
    });

    test('stale profile at propose time fails closed', () async {
      final recipes = [_recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour')];
      await _seedRecipes(db, recipes);
      await _seedContent(db, recipes.single);
      await _seedProfile(db, NutritionProfile(goal: AdultGoal.maintainWeight));
      // Bump the profile revision so the expected revision is stale.
      final doc =
          await LocalWorkspace(db).read('nutrition-profile-v1', 'current');
      await LocalWorkspace(db).put(
        requestId: 'bump-profile',
        collection: 'nutrition-profile-v1',
        id: 'current',
        expectedRevision: doc!.revision,
        data: NutritionProfile(goal: AdultGoal.loseWeight).toJson(),
      );
      final service = _service(db);
      await expectLater(
        service.propose(
          requestId: 'stale-1',
          expectedProfileRevision: 1,
          startDate: DiaryDate(2026, 11, 10),
        ),
        throwsStateError,
      );
    });

    test('stale profile at accept time fails closed without commit', () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      await _seedProfile(db, NutritionProfile(goal: AdultGoal.maintainWeight));
      final service = _service(db);
      final draft = await service.propose(
        requestId: 'stale-accept-1',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 10),
      );
      // Change the profile after proposing.
      final doc =
          await LocalWorkspace(db).read('nutrition-profile-v1', 'current');
      await LocalWorkspace(db).put(
        requestId: 'stale-bump',
        collection: 'nutrition-profile-v1',
        id: 'current',
        expectedRevision: doc!.revision,
        data: NutritionProfile(goal: AdultGoal.gainWeight).toJson(),
      );
      await expectLater(
        service.accept(
            draftId: draft.id,
            expectedDraftRevision: draft.revision,
            expectedPlanRevision: 0,
            requestId: 'accept-stale'),
        throwsStateError,
      );
      expect(await LocalWorkspace(db).read('plan', 'week:2026-11-10'), isNull);
    });

    test('scoped swap changes only the targeted meal', () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:lunch-b', 'insa-bdca:550', 'Greens', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:600', 'Root', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      await _seedProfile(db, NutritionProfile(goal: AdultGoal.maintainWeight));
      final service = _service(db);
      final draft = await service.propose(
          requestId: 'swap-base',
          expectedProfileRevision: 1,
          startDate: DiaryDate(2026, 11, 10));
      await service.accept(
          draftId: draft.id,
          expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-swap-base');
      final before = (await service.planForDate(DiaryDate(2026, 11, 10)))!;
      final lunchMeals = before.meals
          .where((m) => m.slot.label == 'lunch')
          .toList();
      expect(lunchMeals, isNotEmpty);
      final target = lunchMeals.first;

      final swapDraft = await service.propose(
        requestId: 'swap-1',
        expectedProfileRevision: 1,
        startDate: DiaryDate(2026, 11, 10),
        replaceSlotIds: {target.slot.id},
      );
      await service.accept(
          draftId: swapDraft.id,
          expectedDraftRevision: swapDraft.revision,
          expectedPlanRevision: before.revision,
          requestId: 'accept-swap');
      final after = (await service.planForDate(DiaryDate(2026, 11, 10)))!;
      final afterTarget =
          after.meals.firstWhere((m) => m.slot.id == target.slot.id);
      expect(afterTarget.recipe.id, isNot(target.recipe.id));
      // Non-targeted meals keep their selections.
      for (final slotId in before.meals
          .where((m) => m.slot.id != target.slot.id)
          .map((m) => m.slot.id)) {
        final a =
            before.meals.firstWhere((m) => m.slot.id == slotId);
        final b = after.meals.firstWhere((m) => m.slot.id == slotId);
        expect(b.recipe.id, a.recipe.id, reason: slotId);
      }
      // Temporary generation pins were not persisted.
      expect(after.meals.any((m) => m.pinned), isFalse);
    });

    test('consume links one plan entry and retries idempotently', () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      await _seedProfile(db, NutritionProfile(goal: AdultGoal.maintainWeight));
      final service = _service(db);
      final draft = await service.propose(
          requestId: 'consume-base',
          expectedProfileRevision: 1,
          startDate: DiaryDate(2026, 11, 10));
      await service.accept(
          draftId: draft.id,
          expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-consume-base');
      final plan = (await service.planForDate(DiaryDate(2026, 11, 10)))!;
      final meal = plan.meals.firstWhere((m) => m.slot.label == 'breakfast');
      final stamp =
          EventStamp(instant: DateTime.utc(2026, 11, 10, 8), offsetMinutes: 0);
      final entry = await service.consume(
        planDocumentId: plan.documentId,
        slotId: meal.slot.id,
        portions: Exact.one,
        stamp: stamp,
        diaryDate: DiaryDate(2026, 11, 10),
        expectedPlanRevision: plan.revision,
        requestId: 'consume-1',
      );
      expect(entry.channel, EntryChannel.plan);
      expect(entry.diaryDate, DiaryDate(2026, 11, 10));
      final again = await service.consume(
        planDocumentId: plan.documentId,
        slotId: meal.slot.id,
        portions: Exact.one,
        stamp: stamp,
        diaryDate: DiaryDate(2026, 11, 10),
        expectedPlanRevision: plan.revision,
        requestId: 'consume-1',
      );
      expect(again.id, entry.id);
    });

    test('consume retries after state revision and meal edit return original',
        () async {
      final recipes = [
        _recipe('starter:breakfast-a', 'insa-bdca:11', 'Flour'),
        _recipe('starter:breakfast-b', 'insa-bdca:83', 'Eggs'),
        _recipe('starter:lunch-a', 'insa-bdca:402', 'Rice', label: 'lunch'),
        _recipe('starter:dinner-a', 'insa-bdca:550', 'Greens', label: 'dinner'),
      ];
      await _seedRecipes(db, recipes);
      for (final r in recipes) {
        await _seedContent(db, r,
            labels: r.id.contains('breakfast')
                ? ['breakfast']
                : r.id.contains('lunch')
                    ? ['lunch']
                    : ['dinner']);
      }
      await _seedProfile(db, NutritionProfile(goal: AdultGoal.maintainWeight));
      final service = _service(db);
      final draft = await service.propose(
          requestId: 'consume-base2',
          expectedProfileRevision: 1,
          startDate: DiaryDate(2026, 11, 10));
      await service.accept(
          draftId: draft.id,
          expectedDraftRevision: draft.revision,
          expectedPlanRevision: 0,
          requestId: 'accept-consume-base2');
      final plan = (await service.planForDate(DiaryDate(2026, 11, 10)))!;
      final meal = plan.meals.firstWhere((m) => m.slot.label == 'breakfast');
      final stamp =
          EventStamp(instant: DateTime.utc(2026, 11, 10, 8), offsetMinutes: 0);
      final entry = await service.consume(
        planDocumentId: plan.documentId,
        slotId: meal.slot.id,
        portions: Exact.one,
        stamp: stamp,
        diaryDate: DiaryDate(2026, 11, 10),
        expectedPlanRevision: plan.revision,
        requestId: 'consume-2x',
      );
      // The public service re-reads state revision (now 1) on retry; the
      // helper fingerprint must not include it.
      final again = await service.consume(
        planDocumentId: plan.documentId,
        slotId: meal.slot.id,
        portions: Exact.one,
        stamp: stamp,
        diaryDate: DiaryDate(2026, 11, 10),
        expectedPlanRevision: plan.revision,
        requestId: 'consume-2x',
      );
      expect(again.id, entry.id);
      // Consumed selections cannot be swapped; edit a different slot instead.
      await expectLater(
        service.propose(
          requestId: 'swap-consumed',
          expectedProfileRevision: 1,
          startDate: DiaryDate(2026, 11, 10),
          replaceSlotIds: {meal.slot.id},
        ),
        throwsA(isA<StateError>().having(
            (error) => error.message, 'message', 'MEAL_ALREADY_CONSUMED')),
      );
      final other = plan.meals.firstWhere((m) => m.slot.id != meal.slot.id);
      final prompt = await service.propose(
          requestId: 'swap-after-consume',
          expectedProfileRevision: 1,
          startDate: DiaryDate(2026, 11, 10),
          replaceSlotIds: {other.slot.id});
      await service.accept(
          draftId: prompt.id,
          expectedDraftRevision: prompt.revision,
          expectedPlanRevision: plan.revision,
          requestId: 'accept-swap-after-consume');
      final edited = (await service.planForDate(DiaryDate(2026, 11, 10)))!;
      expect(edited.revision, greaterThan(plan.revision));
      final afterEdit = await service.consume(
        planDocumentId: plan.documentId,
        slotId: meal.slot.id,
        portions: Exact.one,
        stamp: stamp,
        diaryDate: DiaryDate(2026, 11, 10),
        expectedPlanRevision: plan.revision,
        requestId: 'consume-2x',
      );
      expect(afterEdit.id, entry.id);
      expect(await db.select(db.logEntries).get(), hasLength(1));
    });
  });

  group('GroceryService', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    test('legacy bare-bool entries normalize to checked maps', () async {
      expect(GroceryService.normalizeItem(true), {'checked': true});
      expect(GroceryService.normalizeItem(false), {'checked': false});
      expect(GroceryService.normalizeItem(null), isEmpty);
      expect(GroceryService.normalizeItem({'checked': true}),
          {'checked': true});
    });

    test('overlay ids are per plan document; manual is shared', () {
      expect(GroceryService.overlayDocumentIdFor('current'), 'current');
      expect(GroceryService.overlayDocumentIdFor('week:2026-11-10'),
          'week:2026-11-10');
      expect(GroceryService.groceryKey('f1', Preparation.raw), 'f1|raw');
    });

    test('household multiplier scales computed grams only', () async {
      final recipe = _recipe('r1', 'insa-bdca:11', 'Chicken', grams: '160');
      final meal =
          PlannedMeal(MealSlot('2026-11-10:lunch', '2026-11-10', 'lunch'),
              recipe, Exact.one);
      expect(GroceryService.requirementsFor([meal], 1).single.grams,
          Exact.parse('160'));
      expect(GroceryService.requirementsFor([meal], 2).single.grams,
          Exact.parse('320'));
    });

    test('blank name and invalid grams fall back to derived values', () async {
      final recipe = _recipe('r1', 'insa-bdca:11', 'Chicken', grams: '160');
      final meal =
          PlannedMeal(MealSlot('2026-11-10:lunch', '2026-11-10', 'lunch'),
              recipe, Exact.one);
      final list = GroceryService.fold(
        planDocumentId: 'week:2026-11-10',
        meals: [meal],
        overlay: {
          'insa-bdca:11|raw': {
            'name': '   ',
            'grams': {'n': 'not-a-number', 'd': '1'},
            'checked': true
          }
        },
      );
      final row = list.visible.single;
      expect(row.name, 'Chicken');
      expect(row.grams, Exact.parse('160'));
      expect(row.gramsOverrideValid, isFalse);
      expect(row.checked, isTrue);
    });

    test('reconcile prunes stale keys and unchecks changed amounts', () async {
      final recipeA = _recipe('ra', 'insa-bdca:11', 'Chicken', grams: '160');
      final recipeB = _recipe('rb', 'insa-bdca:550', 'Broccoli', grams: '200');
      final mealA =
          PlannedMeal(MealSlot('2026-11-10:lunch', '2026-11-10', 'lunch'),
              recipeA, Exact.one);
      final mealB =
          PlannedMeal(MealSlot('2026-11-10:lunch', '2026-11-10', 'lunch'),
              recipeB, Exact.one);
      final workspace = LocalWorkspace(db);
      final keyA = GroceryService.groceryKey('insa-bdca:11', Preparation.raw);
      final keyB =
          GroceryService.groceryKey('insa-bdca:550', Preparation.raw);
      await workspace.put(
        requestId: 'g1',
        collection: 'groceries',
        id: 'week:2026-11-10',
        expectedRevision: 0,
        data: {
          keyA: {'checked': true, 'name': 'My chicken'},
          keyB: {'checked': true},
          'stale|raw': {'checked': true},
        },
      );
      await workspace.put(
        requestId: 'm1',
        collection: 'groceries',
        id: 'manual',
        expectedRevision: 0,
        data: {
          'manual-1': {'name': 'Extra rice', 'checked': false}
        },
      );
      // New plan: drop keyB, keep keyA with doubled portions (changed amount).
      final mealA2 =
          PlannedMeal(MealSlot('2026-11-10:lunch', '2026-11-10', 'lunch'),
              recipeA, Exact.parse('2'));
      await GroceryService(db).reconcileOverlayWithPrior(
        planDocumentId: 'week:2026-11-10',
        priorMeals: [mealA, mealB],
        newMeals: [mealA2],
        priorPlanDocument: const {},
        newPlanDocument: const {},
        requestId: 'reconcile-1',
      );
      final after =
          await workspace.read('groceries', 'week:2026-11-10');
      final data = after!.data;
      expect(data.containsKey(keyB), isFalse);
      expect(data.containsKey('stale|raw'), isFalse);
      expect((data[keyA] as Map)['checked'], isFalse);
      expect((data[keyA] as Map)['name'], 'My chicken');
      final manual = await workspace.read('groceries', 'manual');
      expect(manual!.data['manual-1'], {'name': 'Extra rice', 'checked': false});
    });
  });
}
