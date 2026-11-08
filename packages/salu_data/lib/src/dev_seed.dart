/// A tiny fixture catalogue so the app has something to search before the real
/// import pipeline exists.
///
/// Values are plausible placeholders, not sourced data: the dataset is
/// `dev-fixture` and nothing here may be described as verified.
library;

import 'package:salu_core/salu_core.dart';

import 'database/app_database.dart';
import 'repositories/drift_food_repository.dart';

/// Inserts the fixture catalogue when the database has no foods yet.
///
/// Returns the number of foods written (0 when the catalogue was not empty).
Future<int> seedDevelopmentCatalogue(AppDatabase db) async {
  final existing = await DriftFoodRepository(db).search('', limit: 1);
  if (existing.isNotEmpty) return 0;

  final foods = developmentCatalogue();
  await DriftFoodRepository(db).replaceCatalogueBatch(foods);
  return foods.length;
}

/// The fixture foods themselves.
List<Food> developmentCatalogue() => [
      _food(
        id: 'dev-chicken-breast',
        name: 'Chicken breast, cooked',
        kcal: 165,
        protein: 31,
        carbs: 0,
        fat: 3.6,
        fiber: 0,
        portionGrams: 120,
      ),
      _food(
        id: 'dev-rice-white',
        name: 'Rice, white, cooked',
        kcal: 130,
        protein: 2.7,
        carbs: 28,
        fat: 0.3,
        fiber: 0.4,
      ),
      _food(
        id: 'dev-egg',
        name: 'Egg, whole, boiled',
        kcal: 155,
        protein: 13,
        carbs: 1.1,
        fat: 11,
        fiber: 0,
        portionGrams: 55,
      ),
      _food(
        id: 'dev-apple',
        name: 'Apple, with skin',
        kcal: 52,
        protein: 0.3,
        carbs: 14,
        fat: 0.2,
        fiber: 2.4,
        portionGrams: 180,
      ),
      _food(
        id: 'dev-olive-oil',
        name: 'Olive oil',
        kcal: 884,
        protein: 0,
        carbs: 0,
        fat: 100,
        fiber: 0,
        density: 0.91,
      ),
      _food(
        id: 'dev-milk-semi',
        name: 'Milk, semi-skimmed',
        kcal: 46,
        protein: 3.4,
        carbs: 4.8,
        fat: 1.6,
        fiber: 0,
        density: 1.03,
      ),
      _food(
        id: 'dev-yogurt-greek',
        name: 'Yogurt, Greek, plain',
        kcal: 97,
        protein: 9,
        carbs: 3.9,
        fat: 5,
        fiber: 0,
        portionGrams: 125,
      ),
      _food(
        id: 'dev-bread-wholemeal',
        name: 'Bread, wholemeal',
        kcal: 247,
        protein: 13,
        carbs: 41,
        fat: 3.4,
        fiber: 6,
        portionGrams: 35,
      ),
    ];

Food _food({
  required String id,
  required String name,
  required double kcal,
  required double protein,
  required double carbs,
  required double fat,
  required double fiber,
  double? portionGrams,
  double? density,
}) =>
    Food(
      id: id,
      name: name,
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(kcal),
        NutrientKey.proteinG: NutrientMeasured(protein),
        NutrientKey.carbohydrateG: NutrientMeasured(carbs),
        NutrientKey.fatG: NutrientMeasured(fat),
        NutrientKey.fiberG: NutrientMeasured(fiber),
      }),
      source: const FoodSource(dataset: 'dev-fixture', datasetId: 'fixture'),
      portions: PortionDefinition(
        portionGrams: portionGrams,
        densityGramsPerMillilitre: density,
      ),
      quality: DataQuality.curated,
      allergens: const <String>{},
    );
