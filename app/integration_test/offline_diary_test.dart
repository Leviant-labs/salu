import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:salu/src/app.dart';
import 'package:salu/src/features/today/today_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_core/salu_core.dart';

import 'support/test_database.dart';

final class _RejectingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw StateError('External HTTP is forbidden in the offline smoke test');
  }
}

Future<void> _scrollAndTap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offline meal survives reopening database', (tester) async {
    final fixture = await DeviceTestDatabase.create();
    addTearDown(fixture.dispose);
    final date = DiaryDate.parse('2026-11-19');
    final meal = PhotoMeal(
      id: 'offline',
      date: date,
      slot: MealSlot.lunch,
      caption: 'Offline lunch',
      createdAt: DateTime.utc(2026, 11, 19),
    );
    expect(await fixture.meals.saveNew(meal), isTrue);
    await fixture.reopen();
    final reloaded = (await fixture.meals.listFor(date)).single;
    expect(reloaded.id, 'offline');
    expect(reloaded.items, isEmpty);
    expect(reloaded.estimateStatus, MealEstimateStatus.none);
  });

  testWidgets(
      'offline diary UI logs, edits quantity, keeps nutrition unknown, and survives DB reopen without HTTP',
      (tester) async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RejectingHttpOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final fixture = await DeviceTestDatabase.create();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(fixture.db)],
        child: const SaluApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Salu'), findsOneWidget);
    await _scrollAndTap(tester, find.text('Skip setup'));

    await _scrollAndTap(tester, find.text('Log a meal'));

    await tester.enterText(
      find.widgetWithText(
          TextField, 'What did you have? (optional with photo)'),
      'Lunch: oat porridge',
    );
    await tester.pumpAndSettle();

    await _scrollAndTap(tester, find.text('Save without AI'));

    expect(find.byType(SnackBar), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(TodayScreen)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();

    expect(find.text('Lunch: oat porridge'), findsOneWidget);
    expect(find.text('Foods and portions not identified yet'), findsOneWidget);
    expect(find.text('-- kcal'), findsOneWidget);
    expect(find.text('0 kcal'), findsNothing);

    await _scrollAndTap(tester, find.text('Lunch: oat porridge'));

    await _scrollAndTap(tester, find.text('Add food by name'));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Food name'),
      'Rolled oats',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount eaten (optional)'),
      '40',
    );
    await tester.tap(find.text('Apply to draft'));
    await tester.pumpAndSettle();

    expect(find.text('Rolled oats'), findsOneWidget);
    expect(find.text('40 g'), findsOneWidget);
    expect(find.text('Nutrition unknown'), findsOneWidget);

    await _scrollAndTap(tester, find.text('Edit food'));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount eaten (optional)'),
      '65',
    );
    await tester.tap(find.text('Apply to draft'));
    await tester.pumpAndSettle();

    expect(find.text('65 g'), findsOneWidget);
    expect(find.text('Meal totals: Nutrition unknown'), findsOneWidget);

    await _scrollAndTap(tester, find.text('Save changes'));

    expect(find.text('Lunch: oat porridge'), findsOneWidget);
    expect(find.text('Rolled oats'), findsOneWidget);
    expect(find.text('-- kcal'), findsWidgets);
    expect(find.text('0 kcal'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await fixture.reopen();

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [databaseProvider.overrideWithValue(fixture.db)],
        child: const SaluApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Salu'), findsNothing);
    expect(find.text('Lunch: oat porridge'), findsOneWidget);
    expect(find.text('Rolled oats'), findsOneWidget);
    expect(find.text('-- kcal'), findsWidgets);
    expect(find.text('0 kcal'), findsNothing);

    await tester.tap(find.text('Lunch: oat porridge'));
    await tester.pumpAndSettle();

    expect(find.text('65 g'), findsOneWidget);
    expect(find.text('Nutrition unknown'), findsOneWidget);
    expect(find.text('Meal totals: Nutrition unknown'), findsOneWidget);

    final today = DiaryDate.ofLocal(DateTime.now());
    final savedMeals = await fixture.meals.listFor(today);
    expect(savedMeals, hasLength(1));
    final savedItem = savedMeals.single.items.single;
    expect(savedItem.name, 'Rolled oats');
    expect(savedItem.portion?.amount, 65);
    expect(savedItem.portion?.unit, MealUnit.grams);
    expect(savedItem.nutrients.hasAnyKnownValue, isFalse);
  });
}
