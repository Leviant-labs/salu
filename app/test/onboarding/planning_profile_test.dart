import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/onboarding_screen.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';

class _MemoryProfile extends PlanningProfileStore {
  PlanningProfile profile = const PlanningProfile();

  @override
  Future<PlanningProfile> load() async => profile;

  @override
  Future<void> save(PlanningProfile next) async => profile = next;

  @override
  Future<void> skipOnboarding() async =>
      profile = const PlanningProfile(onboarded: true);
}

void main() {
  testWidgets('first-run setup can be skipped and remembers that choice',
      (tester) async {
    final store = _MemoryProfile();
    var finished = false;
    await tester.pumpWidget(MaterialApp(
        home: OnboardingScreen(
      store: store,
      firstRun: true,
      onSaved: () => finished = true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Salu'), findsOneWidget);
    final skip = find.text('Skip for now');
    await tester.ensureVisible(skip);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(store.profile.onboarded, isTrue);
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

  testWidgets(
    'requires starting weight but lets the user leave energy and activity blank',
    (tester) async {
      final store = _MemoryProfile();
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingScreen(store: store, onSaved: () => saved = true),
        ),
      );
      await tester.pumpAndSettle();

      final save = find.widgetWithText(FilledButton, 'Save profile');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Enter a starting weight.'), findsOneWidget);
      expect(saved, isFalse);

      final weightField = find.widgetWithText(TextFormField, 'Starting weight');
      await tester.ensureVisible(weightField);
      await tester.enterText(weightField, '75,5');
      final dislikes = find.widgetWithText(TextFormField, 'Dislikes');
      await tester.ensureVisible(dislikes);
      await tester.enterText(dislikes, 'Black olives');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
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
}
