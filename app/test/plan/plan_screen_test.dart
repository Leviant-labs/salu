import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu/src/features/plan/plan_suggestions.dart';
import 'package:salu/src/features/plan/week_plan.dart';

final _monday = DateTime.utc(2026, 1, 5);
const _breakfast = (day: 0, slot: MealSlot.breakfast);
const _lunch = (day: 0, slot: MealSlot.lunch);

class _MemoryPlan extends WeekPlanStore {
  final weeks = <DateTime, WeekPlan>{};
  int saves = 0;

  @override
  Future<void> save(WeekPlan plan) async {
    saves++;
    weeks[plan.monday] = plan;
  }

  @override
  Future<WeekPlan> load(DateTime monday) async =>
      weeks[monday] ?? WeekPlan(monday);
}

class _MemoryProfile extends PlanningProfileStore {
  FoodPreferences preferences = const FoodPreferences();

  @override
  Future<PlanningProfile> load() async =>
      PlanningProfile(preferences: preferences);

  @override
  Future<void> savePreferences(FoodPreferences next) async =>
      preferences = next;
}

class _FakeSuggestions implements PlanSuggestionSource {
  _FakeSuggestions(this.draft);

  final PlanDraft draft;
  final requests = <FoodPreferences>[];

  @override
  Future<PlanDraft> suggest(FoodPreferences preferences,
      {PlanSuggestionContext? context}) async {
    requests.add(preferences);
    return draft;
  }
}

Future<void> _openPlan(
  WidgetTester tester,
  _MemoryPlan plan, {
  PlanningProfileStore? profile,
  PlanSuggestionSource? suggestions,
}) async {
  tester.view.physicalSize = const Size(390, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlanScreen(
          store: plan,
          profileStore: profile,
          suggestions: suggestions,
          now: () => _monday,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('edits a meal and groceries offline and keeps weeks separate', (
    tester,
  ) async {
    final store = _MemoryPlan();
    final profile = _MemoryProfile();
    await _openPlan(tester, store, profile: profile);
    await _tap(tester, find.byKey(const ValueKey('meal-0-breakfast')));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Meal name'),
      'Toast',
    );
    await _tap(tester, find.text('Save'));
    expect(store.weeks[_monday]?.meals[_breakfast]?.name, 'Toast');

    final sunday = find.byKey(const ValueKey('meal-6-dinner'));
    await tester.scrollUntilVisible(sunday, 240);
    expect(sunday, findsOneWidget);

    await _tap(tester, find.text('Groceries'));
    await _tap(tester, find.text('Add grocery item'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Item name'),
      'Bread',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount (optional)'),
      '1 loaf',
    );
    await _tap(tester, find.text('Save'));
    await _tap(tester, find.text('Bread'));
    expect(store.weeks[_monday]?.groceries.single.checked, isTrue);

    await _tap(tester, find.byTooltip('Next week'));
    expect(find.text('Bread'), findsNothing);
    await _tap(tester, find.text('Back to this week'));
    expect(find.text('Bread'), findsOneWidget);
    expect(find.text('1 of 1 checked off'), findsOneWidget);

    await _tap(tester, find.text('Food preferences'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Dislikes'),
      'Olives',
    );
    await _tap(tester, find.text('Save preferences'));
    expect(profile.preferences.dislikes, 'Olives');
    expect(find.text('Bread'), findsOneWidget);
  });

  testWidgets(
    'requires request consent and saves only editable, confirmed draft choices',
    (tester) async {
      final store = _MemoryPlan()
        ..weeks[_monday] = WeekPlan(
          _monday,
          meals: const {_breakfast: PlannedMeal('Toast')},
        );
      final profile = _MemoryProfile()
        ..preferences = const FoodPreferences(
          likes: 'Stews',
          dislikes: 'Olives',
          exclusions: 'Peanuts',
        );
      final suggestions = _FakeSuggestions(
        PlanDraft(
          meals: const {
            _breakfast: PlannedMeal('Pancakes'),
            _lunch: PlannedMeal('Bean salad', details: 'Beans'),
          },
          groceries: const [GroceryItem('Beans')],
        ),
      );
      await _openPlan(
        tester,
        store,
        profile: profile,
        suggestions: suggestions,
      );

      final request = find.text('Suggest meals & groceries');
      await _tap(tester, request);
      await _tap(tester, find.text('Cancel'));
      expect(suggestions.requests, isEmpty);
      await _tap(tester, request);
      await _tap(tester, find.text('Request suggestions'));
      expect(
        suggestions.requests.single.toJson(),
        profile.preferences.toJson(),
      );
      expect(store.saves, 0);
      expect(find.text('Confirm selected (2)'), findsOneWidget);

      final edit = find.byTooltip('Edit Bean salad');
      await _tap(tester, edit);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Ingredients or notes (optional)'),
        'Peanuts',
      );
      await _tap(tester, find.text('Save'));
      await _tap(tester, find.text('Confirm selected (2)'));
      expect(find.textContaining('Edit or deselect it'), findsOneWidget);
      expect(store.saves, 0);

      await _tap(tester, edit);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Meal name'),
        'Warm bean salad',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Ingredients or notes (optional)'),
        'Beans, carrots',
      );
      await _tap(tester, find.text('Save'));
      await _tap(tester, find.text('Confirm selected (2)'));
      expect(store.saves, 1);
      final saved = store.weeks[_monday]!;
      expect(saved.meals[_breakfast]?.name, 'Toast');
      expect(saved.meals[_lunch]?.name, 'Warm bean salad');
      expect(saved.groceries.single.name, 'Beans');
    },
  );

  testWidgets('blocks a draft that mentions an exclusion without retrying', (
    tester,
  ) async {
    final store = _MemoryPlan();
    final profile = _MemoryProfile()
      ..preferences = const FoodPreferences(exclusions: 'Sesame');
    final suggestions = _FakeSuggestions(
      PlanDraft(meals: const {}, groceries: const [GroceryItem('Sesame oil')]),
    );
    await _openPlan(tester, store, profile: profile, suggestions: suggestions);
    await _tap(tester, find.text('Suggest meals & groceries'));
    await _tap(tester, find.text('Request suggestions'));
    expect(find.text('Review meal suggestions'), findsNothing);
    expect(find.textContaining('Must exclude'), findsOneWidget);
    expect(suggestions.requests, hasLength(1));
    expect(store.saves, 0);
  });
}
