import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/meals/meal_editor.dart';
import 'package:salu/src/features/meals/meal_editor_ai.dart';
import 'package:salu/src/features/meals/meal_editor_data.dart';
import 'package:salu/src/features/meals/meal_editor_dialogs.dart';
import 'package:salu/src/media/managed_media_store.dart';
import 'package:salu_core/salu_core.dart';

import 'meal_editor_fakes.dart';

void main() {
  final date = DiaryDate.parse('2026-11-18');

  test(
      'parseMealEstimate blocks absurd/invalid values out of totals while preserving safe fields',
      () {
    final items = parseMealEstimate({
      'items': [
        {
          'name': 'Mystery curry',
          'portion': {'amount': 200, 'unit': 'grams'},
          'nutrients': {
            'energy_kcal': 500000,
            'protein_g': 25,
            'fat_g': -4,
            'carbohydrate_g': 300,
            'sodium_mg': 650,
          },
        },
        {
          'name': 'Olive oil',
          'portion': {'amount': 15, 'unit': 'millilitres'},
          'nutrients': {
            'energy_kcal': 120,
            'fat_g': 14,
          },
        },
      ],
    });

    final curry = items.first;
    expect(curry.nutrients[NutrientKey.energyKcal], const NutrientUnknown());
    expect(curry.nutrients[NutrientKey.fatG], const NutrientUnknown());
    expect(curry.nutrients[NutrientKey.carbohydrateG], const NutrientUnknown());
    expect(curry.nutrients[NutrientKey.proteinG].numericValue, 25);
    expect(curry.nutrients[NutrientKey.sodiumMg].numericValue, 650);
    expect(
      curry.reviewIssues.map((i) => (i.code, i.nutrient)),
      containsAll([
        ('absoluteLimit', NutrientKey.energyKcal),
        ('invalidValue', NutrientKey.fatG),
        ('massInconsistent', NutrientKey.carbohydrateG),
      ]),
    );

    // Millilitres must not trigger gram mass checks.
    final oil = items.last;
    expect(oil.nutrients[NutrientKey.energyKcal].numericValue, 120);
    expect(oil.nutrients[NutrientKey.fatG].numericValue, 14);
    expect(oil.reviewIssues, isEmpty);

    // Meal totals only include surviving safe fields, never blocked numbers.
    final totals = mealTotalDetails(items);
    expect(totals, contains('Energy: ≈120 kcal (partial)'));
    expect(totals, contains('Protein: ≈25 g (partial)'));
    expect(totals, contains('Fat: ≈14 g (partial)'));
    expect(totals, contains('Sodium: ≈650 mg (partial)'));
    expect(totals, isNot(contains('500000')));
    expect(totals, isNot(contains('300 g')));
  });

  test('parseMealEstimate retains macro-energy mismatch values with warning',
      () {
    final items = parseMealEstimate({
      'items': [
        {
          'name': 'Toast',
          'portion': {'amount': 100, 'unit': 'grams'},
          'nutrients': {
            'energy_kcal': 800,
            'protein_g': 5,
            'carbohydrate_g': 10,
            'fat_g': 4,
          },
        },
      ],
    });

    final toast = items.single;
    expect(toast.nutrients[NutrientKey.energyKcal].numericValue, 800);
    expect(toast.reviewIssues, [
      const NutritionIssue(
        code: 'macroEnergyMismatch',
        nutrient: NutrientKey.energyKcal,
        blocksAutomaticUse: false,
      ),
    ]);
  });

  test('reviseMealItem preserves reviewIssues on scaling and clears on rename',
      () {
    const issue = NutritionIssue(
      code: 'macroEnergyMismatch',
      nutrient: NutrientKey.energyKcal,
      blocksAutomaticUse: false,
    );
    final rice = PhotoMealItem(
      name: 'Rice',
      portion: MealPortion(100, MealUnit.grams),
      nutrients: NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(200, basis: 'photo'),
      }),
      source: 'ai-meal-estimate',
      reviewIssues: const [issue],
    );

    final scaled = reviseMealItem(
      rice,
      'Rice',
      MealPortion(200, MealUnit.grams),
    );
    expect(scaled.reviewIssues, [issue]);
    expect(scaled.nutrients[NutrientKey.energyKcal].numericValue, 400);

    final renamed = reviseMealItem(
      rice,
      'Quinoa',
      MealPortion(200, MealUnit.grams),
    );
    expect(renamed.reviewIssues, isEmpty);
    expect(renamed.nutrients.hasAnyKnownValue, isFalse);

    final unitChanged = reviseMealItem(
      rice,
      'Rice',
      MealPortion(1, MealUnit.servings),
    );
    expect(unitChanged.reviewIssues, isEmpty);
  });

  testWidgets(
      'suspect AI reply saves meal editable with partial totals and surfaces review warnings',
      (tester) async {
    final store = MemoryPhotoMeals();
    final api = FakeOpenAi(reply: {
      'items': [
        {
          'name': 'Stew',
          'portion': {'amount': 150, 'unit': 'grams'},
          'nutrients': {
            'energy_kcal': 999999,
            'protein_g': 18,
          },
        },
      ],
    });

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => MealEditor(
                  repository: store,
                  assistant: api.assistant,
                  foods: const EmptyCatalogue(),
                  date: date,
                  newId: () => 'meal-suspect',
                ),
              ),
            ),
            child: const Text('Log'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Stew');
    await tester.pumpAndSettle();
    final save = find.text('Save with AI estimate');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final saved = store.meals.values.single;
    expect(saved.estimateStatus, MealEstimateStatus.complete);
    expect(saved.items.single.nutrients[NutrientKey.energyKcal],
        const NutrientUnknown());
    expect(saved.items.single.nutrients[NutrientKey.proteinG].numericValue, 18);
    expect(saved.items.single.reviewIssues.single.code, 'absoluteLimit');

    // Reopening the saved meal shows partial totals, review warning, and remains editable.
    await tester.pumpWidget(MaterialApp(
      home: MealEditor(
        meal: saved,
        repository: store,
        assistant: api.assistant,
        foods: const EmptyCatalogue(),
        date: date,
        newId: () => 'meal-suspect-2',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Needs review'), findsOneWidget);
    expect(
      find.text(
          'Energy exceeded plausibility limits and was left unknown. Review or enter manually.'),
      findsOneWidget,
    );
    expect(
      find.text('Meal totals: Protein: ≈18 g · Other nutrients unknown'),
      findsOneWidget,
    );
    expect(find.text('Edit food'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Save changes'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Save changes'), findsOneWidget);
  });

  test('parseMealLabel screens raw OCR values and surfaces issues', () {
    final label = parseMealLabel({
      'basis': {'amount': 100, 'unit': 'grams'},
      'nutrients': {
        'energy_kcal': 25000,
        'protein_g': 8,
        'fat_g': -1,
      },
    })!;

    expect(label.basis.amount, 100);
    expect(label.basis.unit, MealUnit.grams);
    expect(label.values, {NutrientKey.proteinG: 8.0});
    expect(
      label.issues.map((i) => (i.code, i.nutrient, i.blocksAutomaticUse)),
      unorderedEquals([
        ('absoluteLimit', NutrientKey.energyKcal, true),
        ('invalidValue', NutrientKey.fatG, true),
      ]),
    );
  });

  testWidgets(
      'label dialog displays OCR warnings before applying and manual entry retains unusual value with warning',
      (tester) async {
    final item = PhotoMealItem(
      name: 'Granola',
      portion: MealPortion(100, MealUnit.grams),
    );
    final initial = parseMealLabel({
      'basis': {'amount': 100, 'unit': 'grams'},
      'nutrients': {
        'energy_kcal': 25000,
        'protein_g': 9,
      },
    })!;

    PhotoMealItem? applied;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              applied = await editMealLabel(
                context,
                item: item,
                labelPath: '/tmp/label.jpg',
                media: ManagedMediaStore(
                  directory: () async => Directory.systemTemp,
                  newId: () => 'test-label',
                ),
                initial: initial,
                readLabel: () async => initial,
              );
            },
            child: const Text('Open label'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open label'));
    await tester.pumpAndSettle();

    // OCR warning is shown BEFORE applying label values, and safe protein is filled.
    expect(find.text('Review warnings'), findsOneWidget);
    expect(
      find.text(
          'Energy exceeded plausibility limits and was left unknown. Review or enter manually.'),
      findsOneWidget,
    );
    expect(find.text('9.0'), findsOneWidget);

    // Manual reviewed entry can enter an unusual finite non-negative value
    // (e.g. 1500 kcal on 100g) and retain it with nutrition-label provenance + warning.
    final energyField = find.widgetWithText(TextFormField, 'Energy (kcal)');
    await tester.enterText(energyField, '1500');
    await tester.pumpAndSettle();

    final applyButton = find.text('Apply label values');
    await tester.ensureVisible(applyButton);
    await tester.tap(applyButton);
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.source, 'nutrition-label');
    expect(applied!.nutrients[NutrientKey.energyKcal], NutrientReported(1500));
    expect(applied!.nutrients[NutrientKey.energyKcal],
        isNot(isA<NutrientMeasured>()));
    expect(applied!.nutrients[NutrientKey.proteinG], NutrientReported(9));
    expect(applied!.reviewIssues.single.code, 'massInconsistent');
    expect(applied!.reviewIssues.single.nutrient, NutrientKey.energyKcal);
  });
}
