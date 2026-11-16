import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu/src/features/assistant/assistant_controller.dart';
import 'package:salu/src/features/assistant/assistant_screen.dart' show buildAssistantPrompt;
import 'package:salu/src/inference/provider_connection.dart';

PlanAssistanceSuggestion coldProposal() => PlanAssistanceSuggestion(
      action: PlanAssistanceAction.proposePlanChange,
      message: 'Make lunches cold',
      changes: const PlanChangeSuggestion(
        scope: PlanAssistanceScope.selectedMeal,
        slotIds: ['2026-11-12:lunch'],
        coldLunches: true,
      ),
    );
void main() {
  test('cold lunches verdict resolves slot and profile preference', () {
    final verdict = resolveChanges(
      suggestion: coldProposal(),
      allowedRecipeIds: {'starter:a'},
      allowedSlotIds: {'2026-11-12:lunch'},
      baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
      today: DiaryDate(2026, 11, 12),
      planEndIso: '2026-11-18',
      slotDateById: {'2026-11-12:lunch': '2026-11-12'},
    );
    expect(verdict.resolvedSlotIds, ['2026-11-12:lunch']);
    expect(verdict.proposedProfile?.coldLunches, isTrue);
    expect(verdict.cookingMinutesBySlot, isEmpty);
  });

  test('foreign slot id is rejected, never rebased', () {
    expect(
      () => resolveChanges(
        suggestion: const PlanAssistanceSuggestion(
          action: PlanAssistanceAction.proposePlanChange,
          message: 'x',
          changes: PlanChangeSuggestion(
            scope: PlanAssistanceScope.selectedMeal,
            slotIds: ['9999-01-01:lunch'],
            coldLunches: true,
          ),
        ),
        allowedRecipeIds: {'starter:a'},
        allowedSlotIds: {'2026-11-12:lunch'},
        baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
        today: DiaryDate(2026, 11, 12),
        planEndIso: '2026-11-18',
        slotDateById: const {},
      ),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('INVALID_SUGGESTION'))),
    );
  });

  test('foreign recipe rank is rejected', () {
    final suggestion = PlanAssistanceSuggestion(
      action: PlanAssistanceAction.proposePlanChange,
      message: 'x',
      recipeRanks: const [RecipeRankSuggestion(recipeId: 'evil', rank: 1)],
      changes: const PlanChangeSuggestion(
        scope: PlanAssistanceScope.selectedMeal,
        slotIds: ['2026-11-12:lunch'],
        budget: PlanBudget.lowerCost,
      ),
    );
    expect(
      () => resolveChanges(
        suggestion: suggestion,
        allowedRecipeIds: {'starter:a'},
        allowedSlotIds: {'2026-11-12:lunch'},
        baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
        today: DiaryDate(2026, 11, 12),
        planEndIso: '2026-11-18',
        slotDateById: const {'2026-11-12:lunch': '2026-11-12'},
      ),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('INVALID_SUGGESTION'))),
    );
  });

  test('15-minute cap maps to candidate filter for the selected meal only', () {
    final verdict = resolveChanges(
      suggestion: const PlanAssistanceSuggestion(
        action: PlanAssistanceAction.proposePlanChange,
        message: 'x',
        changes: PlanChangeSuggestion(
          scope: PlanAssistanceScope.selectedMeal,
          slotIds: ['2026-11-12:dinner'],
          maximumCookingMinutes: 15,
        ),
      ),
      allowedRecipeIds: {'starter:a'},
      allowedSlotIds: {'2026-11-12:dinner', '2026-11-12:lunch'},
      baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
      today: DiaryDate(2026, 11, 12),
      planEndIso: '2026-11-18',
      slotDateById: const {
        '2026-11-12:dinner': '2026-11-12',
        '2026-11-12:lunch': '2026-11-12',
      },
    );
    expect(verdict.cookingMinutesBySlot, {'2026-11-12:dinner': 15});
    expect(verdict.proposedProfile, isNull);
  });

  test('next-week cheaper resolves start at plan end + 1', () {
    final verdict = resolveChanges(
      suggestion: const PlanAssistanceSuggestion(
        action: PlanAssistanceAction.proposePlanChange,
        message: 'x',
        changes: PlanChangeSuggestion(
          scope: PlanAssistanceScope.nextWeek,
          slotIds: [],
          budget: PlanBudget.lowerCost,
        ),
      ),
      allowedRecipeIds: {'starter:a'},
      allowedSlotIds: {'2026-11-19:lunch'},
      baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
      today: DiaryDate(2026, 11, 12),
      planEndIso: '2026-11-18',
      slotDateById: const {},
    );
    expect(verdict.resolvedStartDate, DiaryDate(2026, 11, 19));
    expect(verdict.proposedProfile?.budget, 'lowerCost');
  });

  test('food and preference IDs outside captured allowlists are rejected', () {
    final suggestion = PlanAssistanceSuggestion(
      action: PlanAssistanceAction.proposePlanChange,
      message: 'x',
      changes: const PlanChangeSuggestion(
        scope: PlanAssistanceScope.nextWeek,
        slotIds: [],
        avoidFoodIds: ['foreign-food'],
      ),
    );
    expect(() => resolveChanges(
      suggestion: suggestion, allowedRecipeIds: {'starter:a'},
      allowedFoodIds: {'food:a'}, allowedSlotIds: {},
      baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
      today: DiaryDate(2026, 11, 12), planEndIso: null,
      slotDateById: const {},
    ), throwsStateError);
  });

  test('remaining-week cold lunches target only available lunch slots', () {
    final verdict = resolveChanges(
      suggestion: const PlanAssistanceSuggestion(
        action: PlanAssistanceAction.proposePlanChange, message: 'x',
        changes: PlanChangeSuggestion(scope: PlanAssistanceScope.remainingWeek,
          slotIds: [], coldLunches: true)),
      allowedRecipeIds: {}, allowedSlotIds: {'lunch', 'dinner', 'old'},
      availableSlotIds: {'lunch', 'dinner', 'old'},
      slotDateById: const {'lunch': '2026-11-12', 'dinner': '2026-11-12', 'old': '2026-11-11'},
      slotLabelById: const {'lunch': 'lunch', 'dinner': 'dinner', 'old': 'lunch'},
      baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
      today: DiaryDate(2026, 11, 12), planEndIso: '2026-11-18',
    );
    expect(verdict.resolvedSlotIds, ['lunch']);
  });

  test('selected meal cannot target another slot', () {
    expect(() => resolveChanges(
      suggestion: coldProposal(), allowedRecipeIds: {},
      allowedSlotIds: {'2026-11-12:lunch'},
      selectedSlotId: '2026-11-12:dinner',
      baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
      today: DiaryDate(2026, 11, 12), planEndIso: '2026-11-18',
      slotDateById: const {'2026-11-12:lunch': '2026-11-12'},
    ), throwsStateError);
  });

  test('replace-this-meal keeps slot and stages a pending proposal', () async {
    final c = AssistantController(
      decider: (_) async => coldProposal(),
      onCancel: () async {},
      onPropose: (_) async => 'draft-1',
      onAccept: (_) async {},
      providerLabel: 'ChatGPT',
    );
    c.verdictBinder = (_) => resolveChanges(
          suggestion: coldProposal(),
          allowedRecipeIds: {'starter:a'},
          allowedSlotIds: {'2026-11-12:lunch'},
          baseProfile: NutritionProfile(goal: AdultGoal.maintainWeight),
          today: DiaryDate(2026, 11, 12),
          planEndIso: '2026-11-18',
          slotDateById: const {'2026-11-12:lunch': '2026-11-12'},
        );
    await c.send('replace this meal; I dislike it',
        payloadClasses: {'text'},
        connection: const ProviderConnectionInfo(
            providerId: 'chatgpt-plan',
            connected: true,
            planUsageGranted: true));
    expect(c.pendingProposal, isNotNull);
    expect(await c.proposePending(), 'draft-1');
  });

  test('why-this-meal explain stays in memory and clears pending proposal', () async {
    final c = AssistantController(
      decider: (_) async => const PlanAssistanceSuggestion(
        action: PlanAssistanceAction.explain,
        message: 'This meal fits your 30-minute window.',
      ),
      onCancel: () async {},
      onPropose: (_) async => throw StateError('unexpected'),
      onAccept: (_) async {},
      providerLabel: 'ChatGPT',
    );
    await c.send('why this meal?',
        payloadClasses: {'text'},
        connection: const ProviderConnectionInfo(
            providerId: 'chatgpt-plan',
            connected: true,
            planUsageGranted: true));
    expect(c.pendingProposal, isNull);
    expect(c.turns.last.text, contains('fits'));
  });

  test('disconnected and scope errors never reach the decider', () async {
    var calls = 0;
    final c = AssistantController(
      decider: (_) async {
        calls++;
        return const PlanAssistanceSuggestion(
            action: PlanAssistanceAction.explain, message: 'x');
      },
      onCancel: () async {},
      onPropose: (_) async => 'd',
      onAccept: (_) async {},
      providerLabel: 'ChatGPT',
    );
    await c.send('make my lunches cold',
        payloadClasses: {'text'},
        connection: const ProviderConnectionInfo(
            providerId: 'chatgpt-plan',
            connected: false,
            planUsageGranted: true));
    expect(calls, 0);
    expect(c.errorCode, 'PROVIDER_NOT_CONNECTED');
    await c.send('make my lunches cold',
        payloadClasses: {'text'},
        connection: const ProviderConnectionInfo(
            providerId: 'chatgpt-plan',
            connected: true,
            planUsageGranted: false));
    expect(calls, 0);
    expect(c.errorCode, 'PROVIDER_SCOPE_REQUIRED');
  });

  test('request hash is derived from the actual transmitted payload', () {
    final prompt = buildAssistantPrompt(
      userText: 'make my lunches cold', locale: 'en',
      eligibleRecipeIds: ['starter:a'], slotIds: ['slot:a'], planTotals: 'partial',
    );
    final decoded = jsonDecode(prompt) as Map<String, dynamic>;
    expect(decoded['eligibleRecipeIds'], ['starter:a']);
    expect(decoded['message'], 'make my lunches cold');
    expect(decoded.containsKey('measurements'), isFalse);
    expect(canonicalRequestHash(prompt), hasLength(64));
    expect(canonicalRequestHash(prompt), isNot(canonicalRequestHash('$prompt ')));
  });
}
