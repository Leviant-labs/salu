import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu/src/features/plan/plan_suggestions.dart';
import 'package:salu/src/features/plan/recipe_library.dart';
import 'package:salu/src/features/plan/recipe_planning.dart';
import 'package:salu/src/features/plan/week_plan.dart';
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
  @override
  Future<PlanningProfile> load() async =>
      const PlanningProfile(dailyEnergyKcal: 2000);
}

class _RecipeLibrary extends RecipeLibrary {
  const _RecipeLibrary(LocalDocumentStore documents, this.recipes)
      : super(const EmptyCatalogue(), documents);
  final List<RecipeVersion> recipes;
  @override
  Future<List<RecipeVersion>> load() async => recipes;
}

RecipeVersion recipe(String name, String id, String ingredient, double grams) =>
    RecipeVersion(
      id: id,
      name: name,
      prepMinutes: 12,
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
}
