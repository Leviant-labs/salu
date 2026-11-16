import 'dart:typed_data';

import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  group('plan assistance parser', () {
    Map<String, Object?> base() => <String, Object?>{
          'schemaVersion': 1,
          'action': 'explain',
          'message': 'This meal is quick and cheap.',
          'question': null,
          'recipeRanks': <Object?>[],
          'changes': null,
        };

    Map<String, Object?> change({
      String scope = 'selectedMeal',
      List<String> slotIds = const ['2026-11-12:lunch'],
      Object? cold = true,
    }) =>
        <String, Object?>{
          'scope': scope,
          'slotIds': slotIds,
          'coldLunches': cold,
          'maximumCookingMinutes': null,
          'budget': null,
          'avoidFoodIds': <Object?>[],
          'likedRecipeIds': <Object?>[],
          'dislikedRecipeIds': <Object?>[],
        };

    test('explain parses', () {
      final s = PlanAssistanceSuggestion.fromJson(base());
      expect(s.action, PlanAssistanceAction.explain);
      expect(s.question, isNull);
    });

    test('clarify requires a question', () {
      final j = base()
        ..['action'] = 'clarify'
        ..['question'] = 'Do you mean lunch or dinner?';
      final s = PlanAssistanceSuggestion.fromJson(j);
      expect(s.action, PlanAssistanceAction.clarify);
      final bad = base()
        ..['action'] = 'clarify'
        ..['question'] = null;
      expect(
          () => PlanAssistanceSuggestion.fromJson(bad), throwsFormatException);
    });

    test('propose cold lunches parses', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['changes'] = change(slotIds: ['2026-11-12:lunch']);
      final s = PlanAssistanceSuggestion.fromJson(j);
      expect(s.action, PlanAssistanceAction.proposePlanChange);
      expect(s.changes!.scope, PlanAssistanceScope.selectedMeal);
      expect(s.changes!.coldLunches, isTrue);
    });

    test('15-minute cooking change parses', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['changes'] = <String, Object?>{
          ...change(cold: null),
          'maximumCookingMinutes': 15,
        };
      final s = PlanAssistanceSuggestion.fromJson(j);
      expect(s.changes!.maximumCookingMinutes, 15);
    });

    test('next-week cheaper parses', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['changes'] = <String, Object?>{
          ...change(scope: 'nextWeek', slotIds: ['2026-11-19:lunch']),
          'budget': 'lowerCost',
        };
      final s = PlanAssistanceSuggestion.fromJson(j);
      expect(s.changes!.scope, PlanAssistanceScope.nextWeek);
      expect(s.changes!.budget, PlanBudget.lowerCost);
    });

    test('rejects unknown fields', () {
      final j = base()..['extra'] = true;
      expect(
          () => PlanAssistanceSuggestion.fromJson(j), throwsFormatException);
    });

    test('rejects foreign recipe id', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['recipeRanks'] = [
          {'recipeId': 'https://example.com/recipe', 'rank': 1},
        ]
        ..['changes'] = change();
      expect(
          () => PlanAssistanceSuggestion.fromJson(j), throwsFormatException);
    });

    test('rejects duplicate slots', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['changes'] = change(slotIds: ['a', 'a']);
      expect(
          () => PlanAssistanceSuggestion.fromJson(j), throwsFormatException);
    });

    test('rejects rank out of range', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['recipeRanks'] = [
          {'recipeId': 'starter:x', 'rank': 101},
        ]
        ..['changes'] = change();
      expect(
          () => PlanAssistanceSuggestion.fromJson(j), throwsFormatException);
    });

    test('rejects no-change proposal', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['changes'] = change(cold: null);
      expect(
          () => PlanAssistanceSuggestion.fromJson(j), throwsFormatException);
    });

    test('round-trips toJson', () {
      final j = base()
        ..['action'] = 'proposePlanChange'
        ..['changes'] = change();
      final s = PlanAssistanceSuggestion.fromJson(j);
      final again = PlanAssistanceSuggestion.fromJson(s.toJson());
      expect(again.action, s.action);
      expect(again.changes!.slotIds, s.changes!.slotIds);
    });
  });

  group('provider authorization semantics', () {
    final now = DateTime.utc(2026, 11, 8);

    test('disconnected fails before transport', () async {
      var calls = 0;
      final provider = _FakeProvider(onInfer: () => calls++);
      final auth = const ProviderAuthorization(providerId: 'fake');
      await expectLater(
        const ReviewedInferenceService().request(
          provider: provider,
          authorization: auth,
          request: InferenceRequest(
              requestId: 'r', task: InferenceTask.labelOcr, prompt: 'x'),
          draft: MealDraft(id: 'd', status: DraftStatus.editing),
          consent: TransferConsent(
            providerId: 'fake',
            task: InferenceTask.labelOcr,
            payloadClasses: const {'text'},
            requestId: 'r',
            draftId: 'd',
            draftRevision: 1,
            expiresAt: DateTime.utc(2027),
          ),
          now: now,
        ),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('PROVIDER_NOT_CONNECTED'))),
      );
      expect(calls, 0);
    });

    test('missing direct grant fails with scope code', () async {
      var calls = 0;
      final provider = _FakeProvider(onInfer: () => calls++);
      const auth = ProviderAuthorization(
          providerId: 'fake', connected: true, planUsageGranted: false);
      final request = InferenceRequest(
          requestId: 'r', task: InferenceTask.labelOcr, prompt: 'x');
      await expectLater(
        const ReviewedInferenceService().request(
          provider: provider,
          authorization: auth,
          request: request,
          draft: MealDraft(id: 'd'),
          consent: TransferConsent(
            providerId: 'fake',
            task: InferenceTask.labelOcr,
            payloadClasses: const {'text'},
            requestId: 'r',
            draftId: 'd',
            draftRevision: 1,
            expiresAt: DateTime.utc(2027),
          ),
          now: now,
        ),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('PROVIDER_SCOPE_REQUIRED'))),
      );
      expect(calls, 0);
    });

    test('null structured maps to INVALID_SUGGESTION, mismatch stays revoked', () async {
      const auth = ProviderAuthorization(
          providerId: 'fake', connected: true, planUsageGranted: true);
      final consentObj = TransferConsent(
        providerId: 'fake',
        task: InferenceTask.planAssistance,
        payloadClasses: const {'text'},
        requestId: 'r',
        draftId: 'd',
        draftRevision: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      final request = InferenceRequest(
          requestId: 'r', task: InferenceTask.planAssistance, prompt: 'x');
      final nullProvider = _FakeProvider(nullStructured: true);
      await expectLater(
        const ReviewedInferenceService().request(
          provider: nullProvider,
          authorization: auth,
          request: request,
          draft: MealDraft(id: 'd'),
          consent: consentObj,
          now: now,
        ),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('INVALID_SUGGESTION'))),
      );
      final consent2 = TransferConsent(
        providerId: 'fake',
        task: InferenceTask.planAssistance,
        payloadClasses: const {'text'},
        requestId: 'r',
        draftId: 'd',
        draftRevision: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      final wrongId = _FakeProvider(responseId: 'other');
      await expectLater(
        const ReviewedInferenceService().request(
          provider: wrongId,
          authorization: auth,
          request: request,
          draft: MealDraft(id: 'd'),
          consent: consent2,
          now: now,
        ),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('UNTRUSTED_OR_REVOKED_RESULT'))),
      );
    });

    test('planAssistance task exists', () {
      expect(InferenceTask.planAssistance.name, 'planAssistance');
    });
  });
}

class _FakeProvider implements InferenceProvider {
  _FakeProvider({Map<String, Object?>? structured, String? responseId,
      bool nullStructured = false, this.onInfer})
      : structured = nullStructured
            ? null
            : (structured ?? const {'items': <Object?>[]}),
        responseId = responseId ?? 'r';
  final Map<String, Object?>? structured;
  final String responseId;
  final void Function()? onInfer;
  @override
  String get providerId => 'fake';
  @override
  Set<InferenceCapability> get capabilities => const {
        InferenceCapability.structuredOutput,
        InferenceCapability.imageInput,
      };
  @override
  bool supports(InferenceTask task) => true;
  @override
  Future<InferenceResponse> infer(InferenceRequest request) async {
    onInfer?.call();
    return InferenceResponse(
        requestId: responseId, text: 'x', structured: structured);
  }

  @override
  Future<void> disconnect() async {}
}
