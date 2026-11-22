import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late LocalDocumentStore docs;
  late DriftFoodRepository foods;

  setUp(() async {
    db = AppDatabase.memory();
    docs = LocalDocumentStore(db);
    foods = DriftFoodRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('FoodLibraryRepository round-trips foods, meals, and favorites',
      () async {
    final repo = FoodLibraryRepository(docs);
    final food = (
      id: 'food-1',
      name: 'Greek Yogurt',
      barcode: '12345678',
      nutrition: BoundedNutrition(
        MealPortion(100, MealUnit.grams),
        NutrientProfile({
          NutrientKey.energyKcal: NutrientReported(95),
          NutrientKey.proteinG: NutrientReported(10),
        }),
      ),
    );
    await repo.saveFood(food);
    expect(await repo.foods(), hasLength(1));
    expect((await repo.foods()).single.name, 'Greek Yogurt');

    // Duplicate barcode rejected.
    await expectLater(
      repo.saveFood((
        id: 'food-2',
        name: 'Other Yogurt',
        barcode: '12345678',
        nutrition: food.nutrition,
      )),
      throwsStateError,
    );

    await repo.saveMeal((
      id: 'meal-1',
      name: 'Morning Bowl',
      items: [
        PhotoMealItem(
          id: 'item-1',
          name: 'Greek Yogurt',
          portion: MealPortion(150, MealUnit.grams),
        ),
      ],
    ));
    expect(await repo.meals(), hasLength(1));
    expect((await repo.meals()).single.name, 'Morning Bowl');

    await repo.toggleFavorite('food-1');
    expect(await repo.favorites(), {'food-1'});
    await repo.toggleFavorite('food-1');
    expect(await repo.favorites(), isEmpty);
  });

  test(
      'RecipeLibraryRepository adds and loads user recipes with versioned codec',
      () async {
    final repo = RecipeLibraryRepository(foods, docs);
    final food = Food(
      id: 'custom-oats',
      name: 'Oats',
      preparation: Preparation.raw,
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(380),
      }),
      source: const FoodSource(dataset: 'test', datasetId: '1'),
    );
    final recipe = RecipeVersion(
      id: 'my-oats',
      name: 'My Oats',
      prepMinutes: 5,
      ingredients: [
        RecipeIngredient(
          food: food,
          edibleGrams: 50,
          purchaseName: 'Oats',
          purchaseGrams: 50,
        ),
      ],
      allergens: const {'wheatGluten'},
      allergenSource: 'test',
    );
    await repo.add(recipe);
    final loaded = await repo.load();
    expect(loaded.any((r) => r.id == 'my-oats' && r.version == 1), isTrue);

    // Duplicate id+version rejected.
    await expectLater(repo.add(recipe), throwsStateError);
  });

  test(
      'WeekPlanRepository round-trips, migrates unversioned docs, and enforces CAS',
      () async {
    final repo = WeekPlanRepository(docs);
    final monday = startOfPlanWeek(DateTime(2026, 11, 21));

    // Seed an unversioned legacy document.
    await docs.put(WeekPlanRepository.keyFor(monday), 0, {
      'meals': [
        {
          'day': 0,
          'slot': 'breakfast',
          'name': 'Oats',
          'details': '1 serving',
          'pinned': true,
        },
      ],
      'groceries': [
        {'name': 'Oats', 'amount': '50 g', 'checked': false},
      ],
    });

    final loaded = await repo.load(monday);
    expect(loaded.revision, 2); // migrated from rev 1 -> rev 2
    expect(
      loaded.meals[(day: 0, slot: PlanMealSlot.breakfast)]?.name,
      'Oats',
    );

    // Save with current revision succeeds.
    await repo.save(
      loaded.copyWith(
        groceries: const [GroceryItem('Oats', amount: '100 g', checked: true)],
      ),
    );
    final reloaded = await repo.load(monday);
    expect(reloaded.revision, 3);
    expect(reloaded.groceries.single.checked, isTrue);

    // Stale revision fails CAS.
    await expectLater(
      repo.save(loaded.copyWith(groceries: const [])),
      throwsStateError,
    );
  });
}
