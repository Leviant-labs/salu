import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/meals/meal_editor.dart';
import 'package:salu/src/features/meals/meal_editor_ai.dart';
import 'package:salu/src/features/meals/meal_editor_data.dart';
import 'package:salu_core/salu_core.dart';

import 'meal_editor_fakes.dart';

void main() {
  final date = DiaryDate.parse('2026-11-18');

  testWidgets('a new Lunch request saves estimates without a review step',
      (tester) async {
    final store = MemoryPhotoMeals();
    final api = FakeOpenAi(reply: {
      'items': [
        {
          'name': 'Bean stew',
          'portion': {'amount': 150, 'unit': 'grams'},
          'nutrients': {'energy_kcal': 190}
        },
        {
          'name': 'Unidentified side',
          'portion': null,
          'nutrients': {'energy_kcal': 5}
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
                                newId: () => 'meal-1'),
                          )),
                      child: const Text('Open editor')),
                ))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'This was my lunch today: bean stew');
    await tester.pumpAndSettle();
    final save = find.text('Save with AI estimate');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final meal = store.meals.values.single;
    expect(find.text('Open editor'), findsOneWidget);
    expect(meal.date, date);
    expect(meal.slot, MealSlot.lunch);
    expect(meal.items.first.nutrients[NutrientKey.energyKcal],
        isA<NutrientEstimated>());
    expect(meal.items.last.nutrients[NutrientKey.energyKcal],
        NutrientValue.unknown);
    expect(api.requests, hasLength(1));
  });

  testWidgets('saves before the provider returns and keeps a newer correction',
      (tester) async {
    final store = MemoryPhotoMeals();
    final wait = Completer<void>();
    final api = FakeOpenAi(waitForReply: wait.future, reply: {
      'items': [
        {
          'name': 'Soup',
          'portion': {'amount': 150, 'unit': 'millilitres'},
          'nutrients': {'energy_kcal': 120}
        },
      ]
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
                                    newId: () => 'meal-2',
                                    initialDescription:
                                        'This was yesterday’s lunch',
                                    today: date,
                                  ))),
                      child: const Text('Open editor')),
                ))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final save = find.text('Save with AI estimate');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Open editor'), findsOneWidget);
    final saved = store.meals.values.single;
    expect(saved.date, date.addDays(-1));
    expect(saved.slot, MealSlot.lunch);
    expect(saved.items, isEmpty);
    expect(saved.estimateStatus, MealEstimateStatus.pending);
    expect(api.requests, hasLength(1));
    await store.replace(
        saved.copyWith(items: [PhotoMealItem(name: 'Half a roll')]),
        saved.revision);
    wait.complete();
    await tester.pumpAndSettle();
    expect(store.meals.values.single.items.single.name, 'Half a roll');
    expect(store.meals.values.single.revision, 2);
  });

  test('corrections scale only the same item and compatible unit', () {
    final rice = PhotoMealItem(
        name: 'Rice',
        portion: MealPortion(160, MealUnit.grams),
        nutrients: NutrientProfile(
            {NutrientKey.energyKcal: NutrientEstimated(200, basis: 'photo')}));
    final proposed = parseMealCorrection(
        {
          'edits': [
            {
              'op': 'update',
              'index': 0,
              'portion': {'amount': 80, 'unit': 'grams'}
            },
          ]
        },
        MealSlot.lunch,
        [rice])!;
    expect(proposed.items.single.nutrients[NutrientKey.energyKcal],
        NutrientEstimated(100, basis: 'photo'));
    expect(rice.nutrients[NutrientKey.energyKcal].numericValue, 200);
    expect(
        reviseMealItem(rice, 'Beans', rice.portion).nutrients.hasAnyKnownValue,
        isFalse);
  });

  test(
      'a label per 100 ml scales in ml without a density and preserves printed zero',
      () {
    final label = parseMealLabel({
      'basis': {'amount': 100, 'unit': 'millilitres'},
      'nutrients': {'energy_kcal': 40, 'fat_g': 0, 'unknown_field': 1}
    })!;
    final values = NutrientProfile(label.values
        .map((key, value) => MapEntry(key, NutrientReported(value))));
    final drink = scaleMealLabel(
        values, label.basis, MealPortion(250, MealUnit.millilitres))!;
    expect(drink[NutrientKey.energyKcal], NutrientReported(100));
    expect(drink[NutrientKey.fatG], NutrientReported(0));
    expect(drink[NutrientKey.proteinG], NutrientValue.unknown);
    expect(
        scaleMealLabel(values, label.basis, MealPortion(250, MealUnit.grams)),
        isNull);
  });
}
