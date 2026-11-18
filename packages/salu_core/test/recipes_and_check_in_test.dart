import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

final _date = DiaryDate.parse('2026-11-18');
final _rice = Food(
    id: 'rice',
    name: 'Cooked rice',
    source: const FoodSource(dataset: 'test', datasetId: 'rice'),
    per100g: NutrientProfile({NutrientKey.energyKcal: NutrientMeasured(130)}));
final _recipe = RecipeVersion(
    id: 'bowl',
    name: 'Rice bowl',
    prepMinutes: 10,
    servings: 2,
    finishedGrams: 400,
    ingredients: [
      RecipeIngredient(
          food: _rice,
          edibleGrams: 300,
          purchaseName: 'Cooked rice',
          purchaseGrams: 300)
    ]);

void main() {
  test(
      'measured finished mass and equal servings scale from the same frozen ingredients',
      () {
    expect(_recipe.forFinishedGrams(100)![NutrientKey.energyKcal]!.amount,
        closeTo(97.5, 1e-8));
    expect(_recipe.forServings(.5)[NutrientKey.energyKcal]!.amount,
        closeTo(97.5, 1e-8));
    expect(_recipe.forServings(.5)[NutrientKey.fatG]!.amount, isNull);
    expect(
        groceriesFor([
          (recipe: _recipe, servings: 1),
          (recipe: _recipe, servings: .5)
        ]).single.grams,
        225);
  });

  test(
      'hard exclusions and unknown allergen status cannot enter a suggested plan',
      () {
    expect(
        rankRecipePortions(recipes: [_recipe], exclusions: ['rice']), isEmpty);
    expect(rankRecipePortions(recipes: [_recipe], strictAllergens: ['peanuts']),
        isEmpty);
    final ranked = rankRecipePortions(
        recipes: [_recipe], remaining: {NutrientKey.energyKcal: 390});
    expect(ranked.first.servings, 2);
  });

  test(
      'leftover volume is never inferred and insufficient stock refuses a serving',
      () {
    final batch = CookedRecipeBatch(
        recipe: _recipe,
        cookedServings: 4,
        finishedGrams: 800,
        remainingFraction: .25);
    expect(batch.consumptionFraction(MealPortion(200, MealUnit.grams)), .25);
    expect(
        batch.consumptionFraction(MealPortion(2, MealUnit.servings)), isNull);
    expect(batch.consumptionFraction(MealPortion(100, MealUnit.millilitres)),
        isNull);
  });

  test(
      'an unlogged day is not zero and corrections are reflected without changing targets',
      () {
    final days = [
      for (var i = 0; i < 7; i++)
        DayObservation(
            date: _date.addDays(i),
            completeness: i < 6
                ? DiaryCompleteness.declaredComplete
                : DiaryCompleteness.unknown,
            recorded: i < 6
                ? [
                    NutrientProfile(
                        {NutrientKey.energyKcal: NutrientMeasured(2000)})
                  ]
                : [])
    ];
    final before = weeklyCheckIn(days, declaredEnergy: 1800);
    expect(before.energyDays, 6);
    expect(before.recordedEnergyAverage, closeTo(2000, .001));
    expect(before.action, CheckInAction.hold);
    days[6] = DayObservation(
        date: _date.addDays(6),
        completeness: DiaryCompleteness.confirmedNoIntake);
    final after = weeklyCheckIn(days, declaredEnergy: 1800);
    expect(after.energyDays, 7);
    expect(after.recordedEnergyAverage, closeTo(12000 / 7, .001));
    expect(weeklyCheckIn(days.take(2), declaredEnergy: 1800).action,
        CheckInAction.improveRecords);
  });
}
