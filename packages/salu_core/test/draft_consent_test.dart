import 'dart:async';
import 'dart:typed_data';

import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

class FakeProvider implements InferenceProvider {
  @override
  String get providerId => 'fake';
  @override
  Set<InferenceCapability> capabilities = {
    InferenceCapability.structuredOutput,
    InferenceCapability.imageInput,
  };
  bool malformed = false;
  String? responseRequestId;
  int calls = 0;
  @override
  bool supports(InferenceTask task) => true;
  @override
  Future<InferenceResponse> infer(InferenceRequest request) async {
    calls++;
    return InferenceResponse(
        requestId: responseRequestId ?? request.requestId,
        text: 'untrusted',
        structured: malformed ? null : {'items': const <Object?>[]});
  }

  @override
  Future<void> disconnect() async {}
}

class PendingProvider extends FakeProvider {
  final response = Completer<InferenceResponse>();
  @override
  Future<InferenceResponse> infer(InferenceRequest request) {
    calls++;
    return response.future;
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 8);
  final request = InferenceRequest(
      requestId: 'r',
      task: InferenceTask.labelOcr,
      prompt: 'label',
      images: [ImageAttachment(bytes: Uint8List(0), mimeType: 'image/jpeg')]);
  const authorized = ProviderAuthorization(
      providerId: 'fake', connected: true, planUsageGranted: true);

  TransferConsent consent({
    String provider = 'fake',
    InferenceTask task = InferenceTask.labelOcr,
    Set<String> payloadClasses = const {'text', 'image'},
    String requestId = 'r',
    String draftId = 'd',
    int revision = 1,
    DateTime? expiresAt,
  }) =>
      TransferConsent(
          providerId: provider,
          task: task,
          payloadClasses: payloadClasses,
          requestId: requestId,
          draftId: draftId,
          draftRevision: revision,
          expiresAt: expiresAt ?? now.add(const Duration(minutes: 5)));

  Future<InferenceResponse> send(FakeProvider provider, TransferConsent c,
          {InferenceRequest? req, MealDraft? draft}) =>
      const ReviewedInferenceService().request(
          provider: provider,
          authorization: authorized,
          request: req ?? request,
          draft: draft ?? MealDraft(id: 'd'),
          consent: c,
          now: now);

  test('consent permits only its exact scope', () {
    final c = consent();
    bool allows({
      String provider = 'fake',
      InferenceTask purpose = InferenceTask.labelOcr,
      Set<String> payload = const {'text', 'image'},
      String requestId = 'r',
      String draftId = 'd',
      int revision = 1,
      DateTime? at,
    }) =>
        c.permits(
            provider: provider,
            purpose: purpose,
            payload: payload,
            request: requestId,
            draft: draftId,
            revision: revision,
            now: at ?? now);
    expect(allows(), isTrue);
    expect(allows(provider: 'other'), isFalse);
    expect(allows(purpose: InferenceTask.mealPhoto), isFalse);
    expect(allows(payload: {'text', 'image', 'location'}), isFalse);
    expect(allows(requestId: 'other'), isFalse);
    expect(allows(draftId: 'other'), isFalse);
    expect(allows(revision: 2), isFalse);
    expect(allows(at: now.add(const Duration(minutes: 5))), isFalse);
    expect(allows(at: now.add(const Duration(minutes: 4))), isTrue);
  });

  test('every consent mismatch fails before the provider is called', () async {
    final cases = <(String, TransferConsent, InferenceRequest, MealDraft)>[
      ('provider', consent(provider: 'other'), request, MealDraft(id: 'd')),
      (
        'purpose',
        consent(task: InferenceTask.mealPhoto),
        request,
        MealDraft(id: 'd')
      ),
      ('payload', consent(payloadClasses: {'text'}), request, MealDraft(id: 'd')),
      ('request', consent(requestId: 'other'), request, MealDraft(id: 'd')),
      ('draft', consent(draftId: 'other'), request, MealDraft(id: 'd')),
      ('revision', consent(revision: 2), request, MealDraft(id: 'd')),
      (
        'expired',
        consent(expiresAt: now),
        request,
        MealDraft(id: 'd'),
      ),
      ('revoked', consent()..revoked = true, request, MealDraft(id: 'd')),
      ('consumed', consent()..consumed = true, request, MealDraft(id: 'd')),
    ];
    for (final (reason, c, req, draft) in cases) {
      final provider = FakeProvider();
      await expectLater(send(provider, c, req: req, draft: draft),
          throwsStateError,
          reason: reason);
      expect(provider.calls, 0, reason: reason);
    }
  });

  test('closed drafts never reach the provider', () async {
    final cancelled = MealDraft(id: 'd').cancel();
    final committed = MealDraft(id: 'd', status: DraftStatus.review)
        .confirm(expectedRevision: 1, reviewed: true);
    for (final draft in [cancelled, committed]) {
      final provider = FakeProvider();
      await expectLater(
          send(provider, consent(revision: draft.revision), draft: draft),
          throwsStateError);
      expect(provider.calls, 0);
    }
  });

  test('one consent authorizes one transfer and cannot be revived', () async {
    final provider = FakeProvider();
    final c = consent();
    await send(provider, c);
    expect(provider.calls, 1);
    c.consumed = false;
    await expectLater(send(provider, c), throwsStateError);
    expect(provider.calls, 1);

    final withdrawn = consent();
    withdrawn.revoked = true;
    withdrawn.revoked = false;
    expect(withdrawn.revoked, isTrue);
    final second = FakeProvider();
    await expectLater(send(second, withdrawn), throwsStateError);
    expect(second.calls, 0);
  });

  test('empty identifiers cannot authorize or describe a transfer', () async {
    expect(() => consent(requestId: ''), throwsArgumentError);
    expect(() => consent(provider: ''), throwsArgumentError);
    expect(() => consent(draftId: ''), throwsArgumentError);
    expect(() => consent(revision: 0), throwsArgumentError);
    final provider = FakeProvider();
    await expectLater(
        send(provider, consent(),
            req: const InferenceRequest(
                requestId: '',
                task: InferenceTask.labelOcr,
                prompt: 'label')),
        throwsStateError);
    expect(provider.calls, 0);
  });

  test('untrusted provider responses never reach validation', () async {
    for (final malformed in [true, false]) {
      var validated = false;
      final provider = FakeProvider()
        ..malformed = malformed
        ..responseRequestId = malformed ? 'r' : 'other';
      final session = InferenceDraftSession(MealDraft(id: 'd'));
      await expectLater(
          session.requestSuggestion(
              provider: provider,
              authorization: authorized,
              request: request,
              consent: consent(),
              now: now,
              validate: (data) {
                validated = true;
                return data;
              }),
          throwsStateError);
      expect(validated, isFalse);
      expect(session.draft.status, DraftStatus.editing);
      expect(session.draft.revision, 1);
      expect(session.inFlight, isFalse);
    }
  });

  test('an empty validated suggestion leaves the draft unchanged', () async {
    final session = InferenceDraftSession(MealDraft(id: 'd'));
    final permission = consent();
    await expectLater(
        session.requestSuggestion(
            provider: FakeProvider(),
            authorization: authorized,
            request: request,
            consent: permission,
            now: now,
            validate: (_) => <String, Object?>{}),
        throwsStateError);
    expect(session.draft.status, DraftStatus.editing);
    expect(session.draft.revision, 1);
    expect(session.draft.values, isEmpty);
    expect(permission.consumed, isTrue);
    expect(session.inFlight, isFalse);
  });

  test('a response arriving after an edit cannot enter review', () async {
    final session =
        InferenceDraftSession(MealDraft(id: 'd', values: {'text': 'apple'}));
    final provider = PendingProvider();
    final permission = consent();
    var validated = false;
    final pending = session.requestSuggestion(
        provider: provider,
        authorization: authorized,
        request: request,
        consent: permission,
        now: now,
        validate: (data) {
          validated = true;
          return data;
        });
    session.edit({'text': 'pear'});
    provider.response.complete(const InferenceResponse(
        requestId: 'r', text: '', structured: {'items': <Object?>[]}));
    await expectLater(pending, throwsStateError);
    expect(validated, isFalse);
    expect(session.draft.status, DraftStatus.editing);
    expect(session.draft.revision, 2);
    expect(session.draft.values['text'], 'pear');
    expect(permission.consumed, isTrue);
    expect(session.inFlight, isFalse);
  });

  test('a response arriving after cancellation is discarded', () async {
    final session =
        InferenceDraftSession(MealDraft(id: 'd', values: {'text': 'apple'}));
    final provider = PendingProvider();
    var validated = false;
    final pending = session.requestSuggestion(
        provider: provider,
        authorization: authorized,
        request: request,
        consent: consent(),
        now: now,
        validate: (data) {
          validated = true;
          return data;
        });
    session.cancel();
    provider.response.complete(const InferenceResponse(
        requestId: 'r', text: '', structured: {'items': <Object?>[]}));
    await expectLater(pending, throwsStateError);
    expect(validated, isFalse);
    expect(session.draft.status, DraftStatus.cancelled);
    expect(session.draft.values['text'], 'apple');
    expect(session.inFlight, isFalse);
  });

  test('withdrawal while pending is rejected and retry needs new consent',
      () async {
    final session = InferenceDraftSession(MealDraft(id: 'd'));
    final provider = PendingProvider();
    final permission = consent();
    final pending = session.requestSuggestion(
        provider: provider,
        authorization: authorized,
        request: request,
        consent: permission,
        now: now,
        validate: (data) => data);
    permission.revoked = true;
    provider.response.complete(const InferenceResponse(
        requestId: 'r', text: '', structured: {'items': <Object?>[]}));
    await expectLater(pending, throwsStateError);
    expect(session.draft.status, DraftStatus.editing);

    final retryProvider = FakeProvider();
    await expectLater(
        session.requestSuggestion(
            provider: retryProvider,
            authorization: authorized,
            request: request,
            consent: permission,
            now: now,
            validate: (data) => data),
        throwsStateError);
    expect(retryProvider.calls, 0);
    expect(session.draft.status, DraftStatus.editing);

    await session.requestSuggestion(
        provider: retryProvider,
        authorization: authorized,
        request: request,
        consent: consent(),
        now: now,
        validate: (data) => {'food': 'apple'});
    expect(session.draft.status, DraftStatus.review);
    expect(session.draft.values['food'], 'apple');
  });

  test('an old consent cannot authorize a later draft revision', () async {
    final session = InferenceDraftSession(MealDraft(id: 'd'));
    final permission = consent(revision: 1);
    session.edit({'text': 'changed'});
    final provider = FakeProvider();
    await expectLater(
        session.requestSuggestion(
            provider: provider,
            authorization: authorized,
            request: request,
            consent: permission,
            now: now,
            validate: (data) => data),
        throwsStateError);
    expect(provider.calls, 0);
    expect(session.draft.status, DraftStatus.editing);
    expect(session.draft.revision, 2);
  });

  test('session confirmation happens once and closes the draft', () async {
    final session = InferenceDraftSession(MealDraft(id: 'd'));
    await session.requestSuggestion(
        provider: FakeProvider(),
        authorization: authorized,
        request: request,
        consent: consent(),
        now: now,
        validate: (data) => {'food': 'apple'});
    final reviewRevision = session.draft.revision;
    expect(
        () => session.confirm(
            expectedRevision: reviewRevision, reviewed: false),
        throwsStateError);
    expect(session.draft.status, DraftStatus.review);
    session.confirm(expectedRevision: reviewRevision, reviewed: true);
    expect(session.draft.status, DraftStatus.committed);
    expect(
        () => session.confirm(
            expectedRevision: session.draft.revision, reviewed: true),
        throwsStateError);
    expect(() => session.edit({'food': 'pear'}), throwsStateError);
    expect(session.cancel, throwsStateError);
  });
}
