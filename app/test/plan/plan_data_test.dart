import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/plan_suggestions.dart';
import 'package:salu/src/features/plan/week_plan.dart';

void main() {
  test(
    'writes separate week files and reloads meals and shopping state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'salu_week_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = WeekPlanStore(directory: () async => directory);
      final week = startOfPlanWeek(DateTime(2026, 1, 1));
      expect(week, DateTime.utc(2025, 12, 29));
      final nextWeek = week.add(const Duration(days: 7));
      const position = (day: 6, slot: MealSlot.dinner);
      await store.save(
        WeekPlan(
          week,
          meals: const {
            position: PlannedMeal('Risotto', details: 'Rice, leeks'),
          },
          groceries: const [GroceryItem('Leeks', amount: '2', checked: true)],
        ),
      );
      await store.save(
        WeekPlan(nextWeek, groceries: const [GroceryItem('Apples')]),
      );
      final reopened = WeekPlanStore(directory: () async => directory);
      final saved = await reopened.load(week);
      expect(saved.dateFor(6), DateTime.utc(2026, 1, 4));
      expect(saved.meals[position]?.name, 'Risotto');
      expect(saved.meals[position]?.details, 'Rice, leeks');
      expect(saved.groceries.single.amount, '2');
      expect(saved.groceries.single.checked, isTrue);
      expect((await reopened.load(nextWeek)).groceries.single.name, 'Apples');
    },
  );

  test(
    'draft parser rejects malformed positions, repeated slots and absent ingredients',
    () {
      final meal = <String, Object>{
        'day': 0,
        'slot': 'dinner',
        'name': 'Stew',
        'ingredients': ['peas'],
      };
      for (final rows in [
        [meal, meal],
        [
          {...meal, 'day': 7},
        ],
        [
          {...meal, 'slot': 'late night'},
        ],
        [
          {...meal, 'ingredients': <String>[]},
        ],
      ]) {
        expect(
          () =>
              PlanDraft.fromResponse({'meals': rows, 'groceries': <Object>[]}),
          throwsFormatException,
        );
      }
      final parsed = PlanDraft.fromResponse({
        'meals': [meal],
        'groceries': <Object>[],
      });
      expect(parsed.meals[(day: 0, slot: MealSlot.dinner)]?.details, 'peas');
    },
  );

  test(
    'sends preferences only and checks direct exclusion mentions in meals and groceries',
    () {
      const preferences = FoodPreferences(
        likes: 'Stews',
        dislikes: 'Olives',
        exclusions: 'peanut\ncrème fraîche',
      );
      expect(jsonDecode(planSuggestionPrompt(preferences)), {
        'likes': 'Stews',
        'dislikes': 'Olives',
        'mustExclude': ['peanut', 'crème fraîche'],
      });
      final withMeal = PlanDraft(
        meals: const {
          (day: 0, slot: MealSlot.dinner): PlannedMeal(
            'Risotto',
            details: 'rice, CRÈME-FRAÎCHE',
          ),
        },
        groceries: const [],
      );
      final withGrocery = PlanDraft(
        meals: const {},
        groceries: const [GroceryItem('Roasted PEANUTS')],
      );
      final unrelated = PlanDraft(
        meals: const {},
        groceries: const [GroceryItem('Stew vegetables')],
      );
      expect(withMeal.mentionsExclusion(preferences), isTrue);
      expect(withGrocery.mentionsExclusion(preferences), isTrue);
      expect(unrelated.mentionsExclusion(preferences), isFalse);
    },
  );

  test('selected grocery updates preserve already checked state', () {
    final original = WeekPlan(
      DateTime.utc(2026, 1, 5),
      groceries: const [
        GroceryItem('Red onion', amount: 'one', checked: true),
        GroceryItem('Eggs', amount: 'six'),
      ],
    );
    final merged = PlanDraft(
      meals: const {},
      groceries: const [
        GroceryItem('red  onion', amount: 'two'),
        GroceryItem('Beans'),
      ],
    ).applyTo(original);
    expect(merged.groceries.map((item) => item.nameKey), [
      'red onion',
      'eggs',
      'beans',
    ]);
    expect(merged.groceries.first.amount, 'two');
    expect(merged.groceries.first.checked, isTrue);
  });
}
