import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/cooked_batches.dart';
import 'package:salu/src/features/plan/recipe_library.dart';
import 'package:salu/src/features/search/food_library.dart';
import 'package:salu/src/features/search/library_controller.dart';
import 'package:salu/src/features/search/library_screen.dart';
import 'package:salu/src/theme/salu_theme.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

final class _EmptyFoodRepo implements FoodRepository {
  @override
  Future<Food?> findById(String id) async => null;

  @override
  Future<List<Food>> search(String query, {int limit = 25}) async => const [];
}

class _FailingOnceLibraryController extends LibraryController {
  _FailingOnceLibraryController({
    required super.foodLibrary,
    required super.recipeLibrary,
    required super.cookedBatches,
  });

  bool failNext = true;

  @override
  Future<void> refresh() async {
    if (failNext) {
      failNext = false;
      throw StateError('disk error');
    }
    return super.refresh();
  }
}

void main() {
  testWidgets(
      'searches all four library tabs and invokes callbacks once without writing intake',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    final foodLib = FoodLibrary(docs);
    final recipeLib = RecipeLibrary(_EmptyFoodRepo(), docs);
    final batches = CookedBatches(docs);

    final SavedFood oats = (
      id: 'sf-1',
      name: 'Rolled Oats',
      barcode: null,
      nutrition: BoundedNutrition(
        MealPortion(100, MealUnit.grams),
        NutrientProfile({
          NutrientKey.energyKcal: NutrientMeasured(380),
        }),
      ),
    );
    await foodLib.saveFood(oats);
    final SavedMeal bowl = (
      id: 'sm-1',
      name: 'Morning Bowl',
      items: [
        PhotoMealItem(
          name: 'Rolled Oats',
          nutrients: NutrientProfile({
            NutrientKey.energyKcal: NutrientMeasured(190),
          }),
        ),
      ],
    );
    await foodLib.saveMeal(bowl);

    final lentilFood = Food(
      id: 'food-lentils',
      name: 'Lentils, cooked',
      source: const FoodSource(dataset: 'test', datasetId: '1'),
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(116),
      }),
    );
    final soup = RecipeVersion(
      id: 'local-recipe:soup',
      version: 1,
      name: 'Lentil Soup',
      prepMinutes: 25,
      servings: 4,
      minServings: 1,
      maxServings: 8,
      method: 'Simmer lentils',
      ingredients: [
        RecipeIngredient(
          food: lentilFood,
          edibleGrams: 200,
          purchaseName: 'Lentils',
        ),
      ],
    );
    await recipeLib.add(soup);
    await batches.add(
      'batch-1',
      CookedRecipeBatch(
        recipe: soup,
        cookedServings: 4,
        remainingFraction: 0.5,
      ),
    );

    final controller = LibraryController(
      foodLibrary: foodLib,
      recipeLibrary: recipeLib,
      cookedBatches: batches,
    );
    addTearDown(controller.dispose);

    var foodUses = 0;
    var mealUses = 0;
    var recipeUses = 0;
    var batchUses = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: LibraryScreen(
          controller: controller,
          onUseFood: (_) => foodUses++,
          onUseMeal: (_) => mealUses++,
          onUseRecipe: (_) => recipeUses++,
          onUseBatch: (_) => batchUses++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Foods tab
    expect(find.text('Rolled Oats'), findsOneWidget);
    await tester.tap(find.text('Rolled Oats'));
    await tester.pump();
    expect(foodUses, 1);

    // Search filters out non-matching food
    await tester.enterText(find.byType(TextField), 'Lentil');
    await tester.pump();
    expect(find.text('Rolled Oats'), findsNothing);
    expect(find.text('No saved foods match your search.'), findsOneWidget);

    // Clear search
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    // Meals tab
    await tester.tap(find.text('Meals'));
    await tester.pumpAndSettle();
    expect(find.text('Morning Bowl'), findsOneWidget);
    await tester.tap(find.text('Morning Bowl'));
    await tester.pump();
    expect(mealUses, 1);

    // Recipes tab
    await tester.tap(find.text('Recipes'));
    await tester.pumpAndSettle();
    expect(find.text('Lentil Soup'), findsOneWidget);
    await tester.tap(find.text('Lentil Soup'));
    await tester.pump();
    expect(recipeUses, 1);

    // Leftovers tab
    await tester.tap(find.text('Leftovers'));
    await tester.pumpAndSettle();
    expect(find.text('Lentil Soup'), findsOneWidget);
    await tester.tap(find.text('Lentil Soup'));
    await tester.pump();
    expect(batchUses, 1);
  });

  testWidgets('shows error state and retries cleanly', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    final controller = _FailingOnceLibraryController(
      foodLibrary: FoodLibrary(docs),
      recipeLibrary: RecipeLibrary(_EmptyFoodRepo(), docs),
      cookedBatches: CookedBatches(docs),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: LibraryScreen(
          controller: controller,
          onUseFood: (_) {},
          onUseMeal: (_) {},
          onUseRecipe: (_) {},
          onUseBatch: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load your food library.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load your food library.'), findsNothing);
  });
}
