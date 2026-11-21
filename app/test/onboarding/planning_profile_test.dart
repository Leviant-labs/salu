import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/onboarding_screen.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu_data/salu_data.dart';

class _MemoryProfile extends PlanningProfileStore {
  PlanningProfile profile = const PlanningProfile();
  bool throwOnSave = false;

  @override
  Future<PlanningProfile> load() async => profile;

  @override
  Future<void> save(PlanningProfile next) async {
    if (throwOnSave) throw StateError('disk full');
    profile = next;
  }

  @override
  Future<void> savePreferences(FoodPreferences preferences) async {
    if (throwOnSave) throw StateError('disk full');
    profile = PlanningProfile(
      startingWeight: profile.startingWeight,
      weightUnit: profile.weightUnit,
      energyGoal: profile.energyGoal,
      dailyEnergyKcal: profile.dailyEnergyKcal,
      proteinGrams: profile.proteinGrams,
      carbohydrateGrams: profile.carbohydrateGrams,
      fatGrams: profile.fatGrams,
      habitualActivity: profile.habitualActivity,
      preferences: preferences,
      onboarded: profile.onboarded,
    );
  }
}

void main() {
  testWidgets('first-run setup can be skipped and remembers that choice',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    final onboardingStore = OnboardingStore(docs);
    var finished = false;
    await tester.pumpWidget(MaterialApp(
        home: OnboardingScreen(
      onboardingStore: onboardingStore,
      firstRun: true,
      onSaved: () => finished = true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Salu'), findsOneWidget);
    final skip = find.text('Skip setup');
    await tester.ensureVisible(skip);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    final saved = await docs.read('planning-profile');
    expect(saved, isNotNull);
    expect(saved!.data['onboarded'], isTrue);
  });
  test(
    'preferences persist without weight and can be updated without erasing the profile',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'salu_profile_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = PlanningProfileStore(directory: () async => directory);
      await store.savePreferences(const FoodPreferences(dislikes: 'Mushrooms'));
      final reopenedStore = PlanningProfileStore(
        directory: () async => directory,
      );
      final preferencesOnly = await reopenedStore.load();
      expect(preferencesOnly.startingWeight, isNull);
      expect(preferencesOnly.preferences.dislikes, 'Mushrooms');

      await reopenedStore.save(
        const PlanningProfile(
          startingWeight: 143.5,
          weightUnit: WeightUnit.pounds,
          energyGoal: 'A target I already use',
          dailyEnergyKcal: 2000,
          habitualActivity: 'Walk to work',
        ),
      );
      await reopenedStore.savePreferences(
        const FoodPreferences(
          likes: 'Stews',
          dislikes: 'Mushrooms',
          exclusions: 'Sesame, milk\npeanut',
        ),
      );
      final profile = await store.load();
      expect(profile.startingWeight, 143.5);
      expect(profile.weightUnit, WeightUnit.pounds);
      expect(profile.energyGoal, 'A target I already use');
      expect(profile.dailyEnergyKcal, 2000);
      expect(profile.habitualActivity, 'Walk to work');
      expect(profile.preferences.likes, 'Stews');
      expect(profile.preferences.dislikes, 'Mushrooms');
      expect(profile.preferences.exclusionItems, ['Sesame', 'milk', 'peanut']);
    },
  );

  testWidgets('profile editing does not require a weight', (tester) async {
    final store = _MemoryProfile();
    var saved = false;
    await tester.pumpWidget(MaterialApp(
        home: OnboardingScreen(store: store, onSaved: () => saved = true)));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save profile');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(store.profile.startingWeight, isNull);
  });

  testWidgets(
    'accepts comma-decimal weight, leaves energy and activity blank, and preserves preferences',
    (tester) async {
      final store = _MemoryProfile();
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingScreen(store: store, onSaved: () => saved = true),
        ),
      );
      await tester.pumpAndSettle();

      final weightField = find.widgetWithText(TextFormField, 'Starting weight');
      await tester.ensureVisible(weightField);
      await tester.enterText(weightField, '75,5');
      final dislikes = find.widgetWithText(TextFormField, 'Dislikes');
      await tester.ensureVisible(dislikes);
      await tester.enterText(dislikes, 'Black olives');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'Save profile');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(saved, isTrue);
      expect(store.profile.startingWeight, 75.5);
      expect(store.profile.dailyEnergyKcal, isNull);
      expect(store.profile.habitualActivity, isEmpty);
      expect(store.profile.preferences.dislikes, 'Black olives');
    },
  );

  testWidgets(
    'rejects non-finite or non-positive numbers and retains edits on save error',
    (tester) async {
      final store = _MemoryProfile();
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingScreen(store: store, onSaved: () => saved = true),
        ),
      );
      await tester.pumpAndSettle();

      final weightField = find.widgetWithText(TextFormField, 'Starting weight');
      final save = find.widgetWithText(FilledButton, 'Save profile');

      for (final invalid in ['abc', '-5', '0', 'Infinity', 'NaN']) {
        await tester.ensureVisible(weightField);
        await tester.enterText(weightField, invalid);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(find.text('Enter a number greater than zero.'), findsOneWidget);
        expect(saved, isFalse);
      }

      await tester.ensureVisible(weightField);
      await tester.enterText(weightField, '72.4');
      store.throwOnSave = true;
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(saved, isFalse);
      expect(
        find.text('Could not save. Your edits are still here.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextFormField>(weightField).controller?.text,
        '72.4',
      );
    },
  );

  testWidgets(
    'FoodPreferencesScreen edits preferences without collecting or overwriting weight',
    (tester) async {
      final store = _MemoryProfile()
        ..profile = const PlanningProfile(
          startingWeight: 68,
          energyGoal: 'Stay active',
          preferences: FoodPreferences(likes: 'Oats'),
          onboarded: true,
        );

      await tester.pumpWidget(
        MaterialApp(home: FoodPreferencesScreen(store: store)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Starting weight'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Dislikes'),
        'Olives',
      );
      final save = find.widgetWithText(FilledButton, 'Save preferences');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(store.profile.startingWeight, 68);
      expect(store.profile.energyGoal, 'Stay active');
      expect(store.profile.preferences.likes, 'Oats');
      expect(store.profile.preferences.dislikes, 'Olives');
    },
  );

  testWidgets(
    'compact profile editor renders without overflow at 320px width and 200% text scale',
    (tester) async {
      final store = _MemoryProfile();
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2.0),
            ),
            child: child!,
          ),
          home: OnboardingScreen(store: store, onSaved: () {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final save = find.widgetWithText(FilledButton, 'Save profile');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      expect(save, findsOneWidget);
    },
  );

  testWidgets(
    'strict allergen category chips preserve unmapped legacy terms and warn when unresolved',
    (tester) async {
      final store = _MemoryProfile()
        ..profile = const PlanningProfile(
          preferences: FoodPreferences(strictAllergens: 'leite, kiwi'),
          onboarded: true,
        );

      await tester.pumpWidget(
        MaterialApp(home: FoodPreferencesScreen(store: store)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Milk'))
            .selected,
        isTrue,
      );
      expect(
        find.textContaining('Unrecognized strict allergy term(s): kiwi'),
        findsOneWidget,
      );

      // Selecting Peanut adds it while keeping both leite and unmapped kiwi.
      await tester.ensureVisible(find.widgetWithText(FilterChip, 'Peanut'));
      await tester.tap(find.widgetWithText(FilterChip, 'Peanut'));
      await tester.pumpAndSettle();

      // Deselecting Milk removes leite while keeping Peanut and kiwi.
      await tester.ensureVisible(find.widgetWithText(FilterChip, 'Milk'));
      await tester.tap(find.widgetWithText(FilterChip, 'Milk'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save preferences'));
      await tester.pumpAndSettle();

      expect(store.profile.preferences.strictAllergens, 'kiwi, Peanut');
    },
  );
}
