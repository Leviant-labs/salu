import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/assistant/assistant_controller.dart';
import 'package:salu/src/features/assistant/assistant_screen.dart';
import 'package:salu/src/inference/provider_connection.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'plan_test_support.dart';
import 'support/chatgpt_http_fixture.dart';

void main() {
  testWidgets('confirming a message keeps the nested assistant route and displays the reply', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    var calls = 0;
    final controller = AssistantController(
      decider: (text) async {
        calls++;
        return const PlanAssistanceSuggestion(action: PlanAssistanceAction.explain, message: 'Reply');
      },
      onCancel: () async {},
      onPropose: (_) async => '',
      onAccept: (_) async {},
      providerLabel: 'ChatGPT',
    );
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db),
      secureTokenStoreProvider.overrideWithValue(FakeTokenStore()),
      providerConnectionProvider.overrideWithValue(const ProviderConnectionInfo(
        providerId: 'chatgpt-plan', connected: true, planUsageGranted: true)),
    ], child: MaterialApp(home: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (_) => AssistantScreen(controller: controller))))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('assistantComposer')), 'Is this plan suitable?');
    await tester.tap(find.byKey(const Key('assistantSend')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmSend')));
    await tester.pumpAndSettle();
    expect(find.byType(AssistantScreen), findsOneWidget);
    expect(calls, 1);
    expect(find.text('Reply'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long meal choices fit on a narrow screen', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(name: 'A very long meal name with many ingredients and vegetables');
    await seedRecipe(db, recipe);
    await seedPlan(db, meals: [
      PlannedMeal(const MealSlot('dinner:0', '2026-11-16', 'dinner'), recipe, Exact.one),
    ], startDate: '2026-11-16');
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db),
      secureTokenStoreProvider.overrideWithValue(FakeTokenStore()),
      todayDiaryDateProvider.overrideWithValue(DiaryDate(2026, 11, 16)),
      providerConnectionProvider.overrideWithValue(const ProviderConnectionInfo(
        providerId: 'chatgpt-plan', connected: true, planUsageGranted: true)),
    ], child: MaterialApp(builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!), home: const AssistantScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Selected meal (optional)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
