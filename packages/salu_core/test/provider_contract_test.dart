import 'dart:typed_data';
import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

class FakeProvider implements InferenceProvider {
  @override
  String get providerId => 'fake';
  @override
  Set<InferenceCapability> capabilities = {
    InferenceCapability.structuredOutput,
    InferenceCapability.imageInput
  };
  bool available = true;
  int calls = 0;
  bool malformed = false;
  bool fail = false;
  void Function()? onRequest;
  @override
  bool supports(InferenceTask task) => available;
  @override
  Future<InferenceResponse> infer(InferenceRequest request) async {
    calls++;
    onRequest?.call();
    if (fail) throw StateError('revoked token or failed stream');
    return InferenceResponse(
        requestId: request.requestId,
        text: 'untrusted',
        structured: malformed ? null : {'items': <Object?>[]});
  }

  @override
  Future<void> disconnect() async {}
}

void main() {
  final now = DateTime.utc(2026, 11, 8);
  final request = InferenceRequest(
      requestId: 'r',
      task: InferenceTask.labelOcr,
      prompt: 'label',
      images: [ImageAttachment(bytes: Uint8List(0), mimeType: 'image/jpeg')]);
  TransferConsent consent() => TransferConsent(
      providerId: 'fake',
      task: InferenceTask.labelOcr,
      payloadClasses: {'text', 'image'},
      requestId: 'r',
      draftId: 'd',
      draftRevision: 1,
      expiresAt: now.add(const Duration(minutes: 1)));
  const authorized = ProviderAuthorization(
      providerId: 'fake',
      termsReviewed: true,
      distributionEligible: true,
      transportSupported: true);
  Future<InferenceResponse> send(FakeProvider p, TransferConsent c,
          {ProviderAuthorization auth = authorized}) =>
      const ReviewedInferenceService().request(
          provider: p,
          authorization: auth,
          request: request,
          draft: MealDraft(id: 'd'),
          consent: c,
          now: now);
  test('provider release gate fails before transport', () async {
    final p = FakeProvider();
    await expectLater(
        send(p, consent(),
            auth: const ProviderAuthorization(providerId: 'fake')),
        throwsStateError);
    expect(p.calls, 0);
  });
  test('unsupported image capability fails without transmission', () async {
    final p = FakeProvider()
      ..capabilities = {InferenceCapability.structuredOutput};
    await expectLater(send(p, consent()), throwsStateError);
    expect(p.calls, 0);
  });
  test('malformed output cannot become a reviewed result', () async {
    final p = FakeProvider()..malformed = true;
    await expectLater(send(p, consent()), throwsStateError);
    expect(p.calls, 1);
  });
  test('provider error never queues or retries another transfer', () async {
    final p = FakeProvider()..fail = true;
    final c = consent();
    await expectLater(send(p, c), throwsStateError);
    await expectLater(send(p, c), throwsStateError);
    expect(p.calls, 1);
  });
  test('consent withdrawal during transfer rejects late result', () async {
    final p = FakeProvider();
    final c = consent();
    p.onRequest = () => c.revoked = true;
    await expectLater(send(p, c), throwsStateError);
    expect(p.calls, 1);
  });
}
