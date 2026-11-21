import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu/src/features/plan/plan_suggestions.dart';
import 'package:salu/src/features/plan/recipe_library.dart';
import 'package:salu/src/features/plan/recipe_planning.dart';
import 'package:salu/src/features/plan/week_plan.dart';
import 'package:salu/src/features/search/food_library.dart';
import 'package:salu_core/salu_core.dart' hide MealSlot;
import 'package:salu_data/salu_data.dart';

import '../meals/meal_editor_fakes.dart';

const mondayDinner = (day: 0, slot: MealSlot.dinner);
const fridayDinner = (day: 4, slot: MealSlot.dinner);
final monday = DateTime.utc(2026, 11, 16);

class _MemoryWeek extends WeekPlanStore {
  _MemoryWeek(this.week);
  WeekPlan week;
  @override
  Future<WeekPlan> load(DateTime monday) async => week;
  @override
  Future<void> save(WeekPlan plan) async => week = plan;
}

class _Profile extends PlanningProfileStore {
  _Profile([this.profile = const PlanningProfile(dailyEnergyKcal: 2000)]);
  PlanningProfile profile;
  @override
  Future<PlanningProfile> load() async => profile;
  @override
  Future<void> savePreferences(FoodPreferences preferences) async {
    profile = profile.copyWith(preferences: preferences);
  }
}

class _RecipeLibrary extends RecipeLibrary {
  const _RecipeLibrary(LocalDocumentStore documents, this.recipes)
      : super(const EmptyCatalogue(), documents);
  final List<RecipeVersion> recipes;
  @override
  Future<List<RecipeVersion>> load() async => recipes;
}

RecipeVersion recipe(
  String name,
  String id,
  String ingredient,
  double grams, {
  Set<String>? allergens,
  String? allergenSource,
}) =>
    RecipeVersion(
      id: id,
      name: name,
      prepMinutes: 12,
      allergens: allergens,
      allergenSource: allergenSource,
      ingredients: [
        RecipeIngredient(
            food: Food(
                id: ingredient,
                name: ingredient,
                source: FoodSource(dataset: 'fixture', datasetId: ingredient),
                per100g: NutrientProfile(
                    {NutrientKey.energyKcal: NutrientMeasured(160)})),
            edibleGrams: grams,
            purchaseGrams: grams,
            purchaseName: ingredient)
      ],
    );

void main() {
  testWidgets(
      'recipe plan and groceries change together only on the review confirmation',
      (tester) async {
    final before = recipe('Carbonara', 'carbonara', 'Pasta', 125);
    final after = recipe('Rice bowl', 'rice', 'Rice', 200);
    final friday = recipe('Friday soup', 'soup', 'Carrots', 75);
    final recipes = [before, after, friday];
    final stored = _MemoryWeek(reconcileGroceries(
        WeekPlan(monday, meals: {
          mondayDinner: plannedRecipe(before, 1),
          fridayDinner: plannedRecipe(friday, 1),
        }, groceries: const [
          GroceryItem('Coffee', checked: true)
        ]),
        {for (final recipe in recipes) recipe.key: recipe}));
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final api = FakeOpenAi(reply: {
      'meals': [
        {'day': 0, 'slot': 'dinner', 'recipeKey': after.key, 'servings': 1.5}
      ]
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlanScreen(
      now: () => monday,
      store: stored,
      profileStore: _Profile(),
      recipePlanning: RecipePlanning(
          _RecipeLibrary(LocalDocumentStore(db), recipes), api.assistant),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest meals & groceries'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'Replace carbonara, keep Friday');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Review plan and shopping changes'), findsOneWidget);
    expect(find.textContaining('480 kcal'), findsWidgets);
    expect(stored.week.meals[mondayDinner]!.name, 'Carbonara');
    await tester.tap(find.text('Confirm plan and groceries'));
    await tester.pumpAndSettle();
    expect(stored.week.meals[mondayDinner]!.name, 'Rice bowl');
    expect(stored.week.meals[fridayDinner]!.name, 'Friday soup');
    expect(
        stored.week.groceries
            .singleWhere((item) => item.name == 'Rice')
            .requiredGrams,
        300);
    expect(
        stored.week.groceries
            .singleWhere((item) => item.name == 'Coffee')
            .checked,
        isTrue);
  });

  test(
      'carbonara swap preserves Friday and recomputes requirements from the confirmed recipes',
      () async {
    final carbonara = recipe('Carbonara', 'carbonara', 'Pasta', 125);
    final rice = recipe('Rice bowl', 'rice', 'Rice', 200);
    final soup = recipe('Soup', 'soup', 'Carrots', 75);
    final api = FakeOpenAi(reply: {
      'meals': [
        {'day': 0, 'slot': 'dinner', 'recipeKey': rice.key, 'servings': 1.5}
      ]
    });
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final planner = RecipePlanning(
        RecipeLibrary(const EmptyCatalogue(), LocalDocumentStore(db)),
        api.assistant);
    final recipes = [carbonara, rice, soup];
    final byKey = {for (final value in recipes) value.key: value};
    final original = reconcileGroceries(
        WeekPlan(monday, meals: {
          mondayDinner: plannedRecipe(carbonara, 1),
          fridayDinner: plannedRecipe(soup, 1)
        }, groceries: const [
          GroceryItem('Coffee', checked: true)
        ]),
        byKey);
    final profile = PlanningProfile(
        dailyEnergyKcal: 2000,
        preferences: const FoodPreferences(dislikes: 'Carbonara'));
    final request = PlanSuggestionContext.forWeek(original,
        request: 'Replace carbonara, keep Friday');
    final changes =
        await planner.propose(original, recipes, profile, request, useAI: true);
    final confirmed = reconcileGroceries(
        original.copyWith(meals: {...original.meals, ...changes}), byKey);
    expect(original.meals[mondayDinner]!.name, 'Carbonara');
    expect(confirmed.meals[mondayDinner]!.name, 'Rice bowl');
    expect(confirmed.meals[fridayDinner], same(original.meals[fridayDinner]));
    expect(confirmed.groceries.map((item) => item.name),
        unorderedEquals(['Coffee', 'Carrots', 'Rice']));
    expect(
        confirmed.groceries
            .singleWhere((item) => item.name == 'Rice')
            .requiredGrams,
        300);
    expect(
        confirmed.groceries
            .singleWhere((item) => item.name == 'Coffee')
            .checked,
        isTrue);
    expect(dayTotals(confirmed.meals, 0, byKey)[NutrientKey.energyKcal]!.amount,
        480);
    expect(api.requests, hasLength(1));
    expect(
        userContent(api.requests.single).toString(), isNot(contains('2000')));
  });

  test(
      'rejects an AI update to a protected day and flags a larger checked requirement',
      () async {
    final rice = recipe('Rice bowl', 'rice', 'Rice', 100);
    final api = FakeOpenAi(reply: {
      'meals': [
        {'day': 4, 'slot': 'dinner', 'recipeKey': rice.key, 'servings': 2}
      ]
    });
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final planner = RecipePlanning(
        RecipeLibrary(const EmptyCatalogue(), LocalDocumentStore(db)),
        api.assistant);
    final byKey = {rice.key: rice};
    final original = reconcileGroceries(
        WeekPlan(monday, meals: {fridayDinner: plannedRecipe(rice, 1)}), byKey);
    await expectLater(
        planner.propose(original, [rice], const PlanningProfile(),
            PlanSuggestionContext.forWeek(original, request: 'keep Friday'),
            useAI: true),
        throwsFormatException);
    final checked = original
        .copyWith(groceries: [original.groceries.single.withChecked(true)]);
    final increased = reconcileGroceries(
        checked.copyWith(meals: {fridayDinner: plannedRecipe(rice, 2)}), byKey);
    expect(increased.groceries.single.checked, isTrue);
    expect(increased.groceries.single.changed, isTrue);
    expect(increased.groceries.single.requiredGrams, 200);
  });

  test(
      'starter recipes declare reviewed allergens and keep unverified commercial dishes unknown',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await installBundledCatalogue(db);
    final library =
        RecipeLibrary(DriftFoodRepository(db), LocalDocumentStore(db));
    final starters = {for (final r in await library.load()) r.id: r};

    expect(starters, hasLength(8));
    final chickpea = starters['chickpea-tomato']!;
    final yogurt = starters['yogurt-oats']!;
    final sardine = starters['sardine-toast']!;
    final tofu = starters['tofu-quinoa']!;

    expect(chickpea.allergens, isEmpty);
    expect(chickpea.allergenSource, isNotNull);
    expect(yogurt.allergens, {'milk', 'wheatGluten'});
    expect(tofu.allergens, {'soy'});
    expect(sardine.allergens, isNull);

    // Documented eligible and rejected starters under strict Portuguese milk allergy:
    expect(
      recipeEligible(chickpea, strictAllergens: const ['leite']),
      isTrue,
    );
    expect(
      recipeIneligibilityReasons(yogurt, strictAllergens: const ['leite']),
      ['containsAllergen:milk'],
    );
    expect(
      recipeIneligibilityReasons(sardine, strictAllergens: const ['leite']),
      ['unknownAllergenStatus'],
    );
    expect(
      recipeIneligibilityReasons(tofu, strictAllergens: const ['soja']),
      ['containsAllergen:soy'],
    );
  });

  test(
      'pinned meals conflicting with strict allergens or exclusions are detected and cannot be overridden',
      () async {
    final yogurt = recipe(
      'Yogurt oats',
      'yogurt',
      'Yogurt',
      200,
      allergens: const {'milk'},
      allergenSource: 'fixture',
    );
    final rice = recipe(
      'Rice bowl',
      'rice',
      'Rice',
      200,
      allergens: const {},
      allergenSource: 'fixture',
    );
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final planner = RecipePlanning(
      RecipeLibrary(const EmptyCatalogue(), LocalDocumentStore(db)),
      FakeOpenAi(reply: const {}).assistant,
    );
    final recipes = [yogurt, rice];

    final milkPlan = WeekPlan(
      monday,
      meals: {mondayDinner: plannedRecipe(yogurt, 1, pinned: true)},
    );
    await expectLater(
      planner.propose(
        milkPlan,
        recipes,
        const PlanningProfile(
          preferences: FoodPreferences(strictAllergens: 'leite'),
        ),
        PlanSuggestionContext.forWeek(milkPlan),
        useAI: false,
      ),
      throwsA(isA<PinnedMealConflictException>().having(
        (e) => e.conflicts.single.reasons,
        'reasons',
        ['containsAllergen:milk'],
      )),
    );

    final excludedPlan = WeekPlan(
      monday,
      meals: {mondayDinner: plannedRecipe(rice, 1, pinned: true)},
    );
    await expectLater(
      planner.propose(
        excludedPlan,
        recipes,
        const PlanningProfile(
          preferences: FoodPreferences(exclusions: 'rice'),
        ),
        PlanSuggestionContext.forWeek(excludedPlan),
        useAI: false,
      ),
      throwsA(isA<PinnedMealConflictException>().having(
        (e) => e.conflicts.single.reasons,
        'reasons',
        ['excludedIngredient:rice'],
      )),
    );

    final manualPinnedPlan = WeekPlan(
      monday,
      meals: {
        mondayDinner: const PlannedMeal(
          'Homemade snack',
          details: 'Manual note',
          pinned: true,
        ),
      },
    );
    await expectLater(
      planner.propose(
        manualPinnedPlan,
        recipes,
        const PlanningProfile(
          preferences: FoodPreferences(strictAllergens: 'peanut'),
        ),
        PlanSuggestionContext.forWeek(manualPinnedPlan),
        useAI: false,
      ),
      throwsA(isA<PinnedMealConflictException>().having(
        (e) => e.conflicts.single.reasons,
        'reasons',
        ['unknownAllergenStatus'],
      )),
    );
  });

  testWidgets(
      'PlanScreen surfaces pinned conflicts, ineligibility reasons, and revalidates profile changes on confirmation',
      (tester) async {
    final yogurt = recipe(
      'Yogurt bowl',
      'yogurt',
      'Greek yogurt',
      150,
      allergens: const {'milk'},
      allergenSource: 'fixture',
    );
    final unknownDish = recipe('Mystery soup', 'mystery', 'Stock', 200);
    final rice = recipe(
      'Rice bowl',
      'rice',
      'Rice',
      200,
      allergens: const {},
      allergenSource: 'fixture',
    );
    final recipes = [yogurt, unknownDish, rice];
    final stored = _MemoryWeek(
      WeekPlan(
        monday,
        meals: {mondayDinner: plannedRecipe(yogurt, 1, pinned: true)},
      ),
    );
    final profileStore = _Profile(
      const PlanningProfile(
        dailyEnergyKcal: 2000,
        preferences: FoodPreferences(strictAllergens: 'leite'),
      ),
    );
    final db = AppDatabase.memory();
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanScreen(
          now: () => monday,
          store: stored,
          profileStore: profileStore,
          recipePlanning: RecipePlanning(
            _RecipeLibrary(LocalDocumentStore(db), recipes),
            FakeOpenAi(reply: const {}).assistant,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Pinned meal conflict is visible immediately and offers preference editing.
    expect(find.byKey(const ValueKey('pinned-conflicts-card')), findsOneWidget);
    expect(find.textContaining('Contains declared allergen: Milk.'),
        findsOneWidget);
    expect(find.text('Edit food preferences'), findsOneWidget);

    // Offline fill refuses to keep/override the conflicting pinned meal.
    await tester.tap(find.text('Fill empty slots offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Pinned meal conflicts with exclusions'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    // Replacing the conflicting pinned slot with an eligible recipe succeeds.
    final slotFinder = find.byKey(const ValueKey('meal-0-dinner'));
    await tester.ensureVisible(slotFinder);
    await tester.tap(slotFinder);
    await tester.pumpAndSettle();
    expect(find.textContaining('Excluded recipes (2)'), findsOneWidget);
    await tester.ensureVisible(find.byType(DropdownButton<RecipeVersion>));
    await tester.tap(find.byType(DropdownButton<RecipeVersion>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice bowl').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Review change'));
    await tester.tap(find.text('Review change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm plan and groceries'));
    await tester.pumpAndSettle();

    expect(stored.week.meals[mondayDinner]?.name, 'Rice bowl');
    expect(find.byKey(const ValueKey('pinned-conflicts-card')), findsNothing);

    // Profile reload & plan confirm revalidation:
    // If preferences change to exclude rice while the review dialog is open,
    // confirmation refuses to save.
    profileStore.profile = const PlanningProfile(dailyEnergyKcal: 2000);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanScreen(
          key: const ValueKey('plan-revalidation'),
          now: () => monday,
          store: stored,
          profileStore: profileStore,
          recipePlanning: RecipePlanning(
            _RecipeLibrary(LocalDocumentStore(db), recipes),
            FakeOpenAi(reply: const {}).assistant,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('meal-0-breakfast')));
    await tester.tap(find.byKey(const ValueKey('meal-0-breakfast')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButton<RecipeVersion>));
    await tester.tap(find.byType(DropdownButton<RecipeVersion>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yogurt bowl').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Review change'));
    await tester.tap(find.text('Review change'));
    await tester.pumpAndSettle();

    // Mutate stored preferences before confirming.
    profileStore.profile = const PlanningProfile(
      dailyEnergyKcal: 2000,
      preferences: FoodPreferences(strictAllergens: 'milk'),
    );
    await tester.tap(find.text('Confirm plan and groceries'));
    await tester.pumpAndSettle();

    expect(
      find.text(
          'The food exclusions changed. Review a new plan before saving.'),
      findsOneWidget,
    );
    expect(stored.week.meals[(day: 0, slot: MealSlot.breakfast)], isNull);
  });

  testWidgets(
      'PlanScreen shows empty-state reasons for unresolved strict terms without suggesting disabling allergies',
      (tester) async {
    final rice = recipe(
      'Rice bowl',
      'rice',
      'Rice',
      200,
      allergens: const {},
      allergenSource: 'fixture',
    );
    final stored = _MemoryWeek(WeekPlan(monday));
    final profileStore = _Profile(
      const PlanningProfile(
        preferences: FoodPreferences(strictAllergens: 'nuts'),
      ),
    );
    final db = AppDatabase.memory();
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlanScreen(
          now: () => monday,
          store: stored,
          profileStore: profileStore,
          recipePlanning: RecipePlanning(
            _RecipeLibrary(LocalDocumentStore(db), [rice]),
            FakeOpenAi(reply: const {}).assistant,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('unresolved-allergens-card')),
        findsOneWidget);

    await tester.tap(find.text('Fill empty slots offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request suggestions'));
    await tester.pumpAndSettle();

    expect(find.text('No eligible recipes found'), findsOneWidget);
    expect(find.textContaining('Unrecognized strict allergy'), findsWidgets);
    expect(find.text('Edit food preferences'), findsWidgets);
  });

  test('RecipeLibrary preserves unknown vs empty vs declared allergens',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final library =
        RecipeLibrary(const EmptyCatalogue(), LocalDocumentStore(db));
    final unknown = recipe('Unknown', 'u1', 'Item', 100);
    final declaredNone = recipe(
      'Declared none',
      'd0',
      'Item',
      100,
      allergens: const {},
      allergenSource: 'manual label review',
    );
    final declaredMilk = recipe(
      'Declared milk',
      'd1',
      'Milk',
      100,
      allergens: const {'milk'},
      allergenSource: 'manual label review',
    );
    await library.add(unknown);
    await library.add(declaredNone);
    await library.add(declaredMilk);

    final loaded = {
      for (final item in await library.load())
        if ({'u1', 'd0', 'd1'}.contains(item.id)) item.id: item,
    };
    expect(loaded['u1']!.allergens, isNull);
    expect(loaded['d0']!.allergens, isEmpty);
    expect(loaded['d0']!.allergenSource, 'manual label review');
    expect(loaded['d1']!.allergens, {'milk'});
  });

  testWidgets(
      'recipe creation distinguishes unknown status from explicit empty declaration',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await installBundledCatalogue(db);
    final docs = LocalDocumentStore(db);
    final library = RecipeLibrary(DriftFoodRepository(db), docs);
    final chickpeas = (await library.foods.findById('bundled-fdc-173757'))!;
    final safeBase = RecipeVersion(
      id: 'local-recipe:base',
      name: 'Chickpea base',
      prepMinutes: 10,
      ingredients: [
        RecipeIngredient(
          food: chickpeas,
          edibleGrams: 150,
          purchaseName: 'Chickpeas',
          purchaseGrams: 150,
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => createRecipe(
              context,
              library,
              'local-recipe:custom',
              previous: safeBase,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ));

    // 1. Default stays unknown (never inferred empty from ingredients).
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save recipe'));
    await tester.pumpAndSettle();

    var saved = (await library.load())
        .where((r) => r.id == 'local-recipe:custom')
        .single;
    expect(saved.allergens, isNull);

    // 2. Explicit declared-none saves empty set + provenance.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => createRecipe(
              context,
              library,
              'local-recipe:declared-empty',
              previous: safeBase,
            ),
            child: const Text('Open 2'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open 2'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Declared allergens'));
    await tester.tap(find.text('Declared allergens'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(TextFormField, 'Allergen source / provenance'),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Allergen source / provenance'),
      'Checked package labels',
    );
    await tester.tap(find.text('Save recipe'));
    await tester.pumpAndSettle();

    saved = (await library.load())
        .where((r) => r.id == 'local-recipe:declared-empty')
        .single;
    expect(saved.allergens, isEmpty);
    expect(saved.allergenSource, 'Checked package labels');
  });
}
