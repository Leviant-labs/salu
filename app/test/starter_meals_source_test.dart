import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/catalogue/built_in_catalogue.dart';
import 'package:salu/src/catalogue/starter_meals.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real workbook installs 35 starter meals with chicken oracle',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await provisionBundledCatalogue(db,
        normalize: importBundledInsaWorkbook);

    final provision = await provisionStarterMeals(db);
    expect(provision.status, StarterMealLibraryStatus.installed);
    expect(provision.recipeCount, 35);

    final workspace = LocalWorkspace(db);
    final recipeDocs = await workspace.list('recipe');
    expect(
        recipeDocs.where((d) => d.id.startsWith('starter:')).length, 35);
    final contentDocs = await workspace.list('meal-content-v1');
    expect(contentDocs, hasLength(35));
    for (final doc in contentDocs) {
      expect(doc.data['schemaVersion'], 1);
      expect(doc.data['recipeId'], doc.id);
      expect(doc.data['revision'], 1);
      expect(doc.data['coldSuitable'], isA<bool>());
      expect(doc.data['costTier'],
          anyOf('lowerCost', 'standard'));
      expect(
          (doc.data['mealLabels'] as List).every((l) =>
              ['breakfast', 'lunch', 'snack', 'dinner'].contains(l)),
          isTrue);
    }
    final receipt = await workspace.read('preferences', 'starter-meals-v1');
    expect(receipt, isNotNull);
    expect(receipt!.data['assetVersion'], 'v3');
    expect(receipt.data['recipeCount'], 35);
    expect((receipt.data['signatures'] as Map).length, 35);
    expect(
        contentDocs
            .where((doc) => doc.data['grainComposition'] == 'wholeGrain')
            .length,
        16);
    expect(
        contentDocs
            .where((doc) => doc.data['grainComposition'] == 'refinedGrain')
            .length,
        9);

    // Re-install is a no-op.
    final second = await provisionStarterMeals(db);
    expect(second.status, StarterMealLibraryStatus.alreadyInstalled);

    final brown = recipeFromSnapshot((await workspace.read(
        'recipe', 'starter:chickpea-tomato-brown-rice'))!.data);
    expect(brown.minutes, 45);
    expect(brown.ingredients.first.food.id, 'insa-bdca:401');
    expect(brown.ingredients.first.grams, Exact.parse('90'));
    final brownContent = (await workspace.read(
        'meal-content-v1', brown.id))!.data;
    expect(brownContent['grainComposition'], 'wholeGrain');
    expect(brownContent['descriptions'], {
      'en': 'Brown rice with cooked chickpeas and tomato.',
      'pt-PT': 'Arroz integral com grão-de-bico cozido e tomate.',
    });

    // --- Real-source chicken oracle ---
    final chickenDoc =
        await workspace.read('recipe', 'starter:chicken-broccoli-rice');
    expect(chickenDoc, isNotNull);
    final recipe = recipeFromSnapshot(chickenDoc!.data);
    expect(recipe.id, 'starter:chicken-broccoli-rice');
    expect(recipe.ingredients.map((i) => i.food.id), [
      'insa-bdca:11',
      'insa-bdca:402',
      'insa-bdca:550',
      'insa-bdca:395',
    ]);
    // Imported Food allergens stay unknown — never rewritten.
    for (final ing in recipe.ingredients) {
      expect(ing.food.allergens, isNull);
      expect(ing.declaredAllergens, isNotNull);
      expect(ing.allergenDeclarationSource, 'salu-starter-v1');
      expect(ing.effectiveAllergens, isNotNull);
    }

    final perServing = recipe.perServing(Exact.one);
    double exactOf(NutrientKey key) =>
        perServing[key]!.exactValue.toDouble();
    expect(exactOf(NutrientKey.energyKcal), closeTo(639, 0.01));
    expect(exactOf(NutrientKey.proteinG), closeTo(51.39, 0.01));
    expect(exactOf(NutrientKey.fatG), closeTo(13.87, 0.01));

    // Source-native INSA carbs via FoodCalculationService with the retained
    // INSA identity — separate from any EU projection.
    const insaCarbIdentity = NutrientIdentity(
        'carbohydrate_g', 'g', 'insa_available_carbohydrate_excluding_fibre');
    final observed = <ObservedFood>[];
    for (final ing in recipe.ingredients) {
      observed.add(ObservedFood(
        id: ing.food.id,
        quantity: FoodAmount.exact(ing.grams, FoodUnit.g),
        observations: [
          for (final obs in ing.food.observations)
            if (obs.nutrient.definition ==
                'insa_available_carbohydrate_excluding_fibre')
              obs,
        ],
      ));
    }
    final insaSummary = const FoodCalculationService().summarize(
      insaCarbIdentity,
      observed,
      DiaryCompleteness.unknown,
    );
    expect(insaSummary.recordedSum, isNotNull);
    expect(insaSummary.recordedSum!.toDouble(), closeTo(73.29, 0.01));

    // Two servings double energy exactly.
    final two = recipe.perServing(Exact.parse('2'));
    expect(two[NutrientKey.energyKcal]!.exactValue.toDouble(),
        closeTo(1278, 0.01));

    // Household-2 groceries scale masses, never per-meal nutrition.
    final meal1 = PlannedMeal(
      MealSlot('2026-11-12:lunch', '2026-11-12', 'lunch'),
      recipe,
      Exact.parse('2'),
    );
    final groceries = groceriesFor([meal1]);
    final Map<String, double> grams = {
      for (final line in groceries)
        line.foodId: line.grams.toDouble(),
    };
    expect(grams['insa-bdca:11'], closeTo(320, 0.01));
    expect(grams['insa-bdca:402'], closeTo(180, 0.01));
    expect(grams['insa-bdca:550'], closeTo(400, 0.01));
    expect(grams['insa-bdca:395'], closeTo(20, 0.01));
    expect(exactOf(NutrientKey.energyKcal), closeTo(639, 0.01));

    // Allergen semantics over the real library: meat has no fish declaration,
    // egg starter must fail egg exclusion, poultry is not vegetarian.
    expect(recipe.eligible({'fish'}, {}), isTrue);
    expect(recipe.eligible({'fish'}, {'vegetarian'}), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
  test('real meals produce a complete cold-lunch, no-fish week with estimates',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await provisionBundledCatalogue(db, normalize: importBundledInsaWorkbook);
    await provisionStarterMeals(db);
    final service = GuidedPlanService(
        db, const SystemClock(), SequentialIdGenerator());
    final draft = await service.propose(
      requestId: 'real-source-onboarding',
      expectedProfileRevision: 0,
      startDate: DiaryDate(2026, 11, 13),
      proposedProfile: NutritionProfile(
        goal: AdultGoal.loseWeight, ageYears: 30,
        heightCm: Exact.parse('180'), weightKg: Exact.parse('80'),
        equationConstant: 5, activityPal: Exact.parse('1.6'),
        coldLunches: true, maximumCookingMinutes: 30,
        avoidedFoodIds: {'insa-bdca:814', 'insa-bdca:876', 'insa-bdca:966'},
      ),
      proposedSafety: const SafetyProfile(),
      recalculateTarget: true,
      completesOnboarding: true,
    );
    expect((draft.values['meals']! as List), hasLength(21));
    final target = DeclaredTarget.fromJson(
        Map<String, Object?>.from(draft.values['target']! as Map));
    expect(target.energyKcal, Exact.parse('2563.2'));
    expect(await db.select(db.logEntries).get(), isEmpty);
    await service.accept(draftId: draft.id, expectedDraftRevision: draft.revision,
        expectedPlanRevision: 0, requestId: 'real-source-confirm');
    final plan = (await service.planForDate(DiaryDate(2026, 11, 13)))!;
    expect(plan.meals, hasLength(21));
    expect(plan.meals.every((meal) => meal.recipe.ingredients.every((ingredient) =>
        !{'insa-bdca:814', 'insa-bdca:876', 'insa-bdca:966'}.contains(ingredient.food.id))), isTrue);
    final contents = {for (final row in await LocalWorkspace(db).list('meal-content-v1'))
      row.id: row.data};
    expect(plan.meals.where((meal) => meal.slot.label == 'lunch').every(
        (meal) => contents[meal.recipe.id]?['coldSuitable'] == true), isTrue);
    expect(await db.select(db.logEntries).get(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
