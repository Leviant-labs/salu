import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('portion correction scales once and keeps estimate provenance', () {
    final before = PhotoMealItem(
      id: 'item',
      name: 'Soup',
      portion: MealPortion(100, MealUnit.grams),
      nutrients: NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(50, basis: 'fixture'),
      }),
      source: 'model:test',
      labelPaths: const ['labels/soup.jpg'],
      reviewIssues: const [
        NutritionIssue(
          code: 'macroEnergyMismatch',
          nutrient: NutrientKey.energyKcal,
          blocksAutomaticUse: false,
        ),
      ],
    );
    final after = reviseMealItem(
      before,
      'Soup',
      MealPortion(200, MealUnit.grams),
    );
    expect(after.nutrients[NutrientKey.energyKcal].numericValue, 100);
    expect(after.nutrients[NutrientKey.energyKcal], isA<NutrientEstimated>());
    expect(after.id, 'item');
    expect(after.source, 'model:test');
    expect(after.labelPaths, const ['labels/soup.jpg']);
    expect(after.reviewIssues, hasLength(1));
  });

  test('renaming clears nutrients, evidence, label paths, and issues', () {
    final before = PhotoMealItem(
      id: 'item-1',
      name: 'Soup',
      portion: MealPortion(100, MealUnit.grams),
      nutrients: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(50),
      }),
      source: 'catalogue:usda',
      labelPaths: const ['labels/soup.jpg'],
      reviewIssues: const [
        NutritionIssue(
          code: 'macroEnergyMismatch',
          blocksAutomaticUse: false,
        ),
      ],
    );
    final after = reviseMealItem(
      before,
      'Salad',
      MealPortion(100, MealUnit.grams),
    );
    expect(after.id, 'item-1');
    expect(after.name, 'Salad');
    expect(after.nutrients.hasAnyKnownValue, isFalse);
    expect(after.source, isNull);
    expect(after.labelPaths, isEmpty);
    expect(after.reviewIssues, isEmpty);
  });

  test('incompatible units clear nutrients, source, and review issues', () {
    final before = PhotoMealItem(
      id: 'item-2',
      name: 'Milk',
      portion: MealPortion(200, MealUnit.millilitres),
      nutrients: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(120),
      }),
      source: 'label:ocr',
      labelPaths: const ['labels/milk.jpg'],
      reviewIssues: const [
        NutritionIssue(
          code: 'macroEnergyMismatch',
          blocksAutomaticUse: false,
        ),
      ],
    );
    final after = reviseMealItem(
      before,
      'Milk',
      MealPortion(1, MealUnit.servings),
    );
    expect(after.id, 'item-2');
    expect(after.nutrients.hasAnyKnownValue, isFalse);
    expect(after.source, isNull);
    expect(after.labelPaths, const ['labels/milk.jpg']);
    expect(after.reviewIssues, isEmpty);
  });

  test('same portion preserves nutrients and updates casing', () {
    final before = PhotoMealItem(
      id: 'item-3',
      name: 'oats',
      portion: MealPortion(50, MealUnit.grams),
      nutrients: NutrientProfile({
        NutrientKey.proteinG: NutrientMeasured(6.5),
      }),
      source: 'catalogue:usda',
    );
    final after = reviseMealItem(
      before,
      'Oats',
      MealPortion(50, MealUnit.grams),
    );
    expect(after.id, 'item-3');
    expect(after.name, 'Oats');
    expect(after.nutrients[NutrientKey.proteinG].numericValue, 6.5);
    expect(after.source, 'catalogue:usda');
    expect(sameMealPortion(before.portion, after.portion), isTrue);
  });
}
