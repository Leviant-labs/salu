import '../providers/inference.dart';

/// Authorization is scoped to the provider, purpose, payload and draft revision.
final class TransferConsent {
  TransferConsent(
      {required this.providerId,
      required this.task,
      required Set<String> payloadClasses,
      required this.requestId,
      required this.draftId,
      required this.draftRevision,
      required this.expiresAt})
      : payloadClasses = Set.unmodifiable(payloadClasses);
  final String providerId, requestId, draftId;
  final InferenceTask task;
  final Set<String> payloadClasses;
  final int draftRevision;
  final DateTime expiresAt;
  bool revoked = false;
  bool consumed = false;
  bool permits(
          {required String provider,
          required InferenceTask purpose,
          required Set<String> payload,
          required String request,
          required String draft,
          required int revision,
          required DateTime now}) =>
      !revoked &&
      !consumed &&
      now.isBefore(expiresAt) &&
      provider == providerId &&
      purpose == task &&
      request == requestId &&
      draft == draftId &&
      revision == draftRevision &&
      payloadClasses.containsAll(payload);
}

enum DraftStatus { editing, awaitingProvider, review, committed, cancelled }

final class MealDraft {
  MealDraft(
      {required this.id,
      this.revision = 1,
      this.status = DraftStatus.editing,
      Map<String, Object?> values = const {}})
      : values = Map.unmodifiable(values);
  final String id;
  final int revision;
  final DraftStatus status;
  final Map<String, Object?> values;
  MealDraft edit(Map<String, Object?> replacement) {
    if (status == DraftStatus.committed || status == DraftStatus.cancelled) {
      throw StateError('DRAFT_CLOSED');
    }
    return MealDraft(id: id, revision: revision + 1, values: replacement);
  }

  MealDraft receive(
      {required int expectedRevision,
      required Map<String, Object?> suggestion}) {
    if (expectedRevision != revision ||
        status == DraftStatus.committed ||
        status == DraftStatus.cancelled) {
      throw StateError('STALE_DRAFT');
    }
    return MealDraft(
        id: id,
        revision: revision + 1,
        status: DraftStatus.review,
        values: suggestion);
  }

  MealDraft confirm({required int expectedRevision, required bool reviewed}) {
    if (expectedRevision != revision ||
        !reviewed ||
        status != DraftStatus.review) {
      throw StateError('DRAFT_REVIEW_REQUIRED');
    }
    return MealDraft(
        id: id,
        revision: revision + 1,
        status: DraftStatus.committed,
        values: values);
  }

  MealDraft cancel() => MealDraft(
      id: id,
      revision: revision + 1,
      status: DraftStatus.cancelled,
      values: values);
}

final class ProviderAuthorization {
  const ProviderAuthorization(
      {required this.providerId,
      this.termsReviewed = false,
      this.distributionEligible = false,
      this.transportSupported = false});
  final String providerId;
  final bool termsReviewed, distributionEligible, transportSupported;
  bool get enabled =>
      termsReviewed && distributionEligible && transportSupported;
}

final class ReviewedInferenceService {
  const ReviewedInferenceService();

  /// Never queues offline uploads, switches providers or retries implicitly.
  Future<InferenceResponse> request(
      {required InferenceProvider provider,
      required ProviderAuthorization authorization,
      required InferenceRequest request,
      required MealDraft draft,
      required TransferConsent consent,
      required DateTime now}) async {
    if (!authorization.enabled ||
        authorization.providerId != provider.providerId) {
      throw StateError('PROVIDER_RELEASE_GATE');
    }
    if (draft.status == DraftStatus.cancelled ||
        draft.status == DraftStatus.committed) {
      throw StateError('DRAFT_CLOSED');
    }
    if (!provider.supports(request.task) ||
        !provider.capabilities.contains(InferenceCapability.structuredOutput) ||
        (request.images.isNotEmpty &&
            !provider.capabilities.contains(InferenceCapability.imageInput))) {
      throw StateError('CAPABILITY_UNSUPPORTED');
    }
    final payload = <String>{'text', if (request.images.isNotEmpty) 'image'};
    if (!consent.permits(
        provider: provider.providerId,
        purpose: request.task,
        payload: payload,
        request: request.requestId,
        draft: draft.id,
        revision: draft.revision,
        now: now)) {
      throw StateError('CONSENT_REQUIRED');
    }
    consent.consumed = true;
    final result = await provider.infer(request);
    if (consent.revoked ||
        result.requestId != request.requestId ||
        result.structured == null) {
      throw StateError('UNTRUSTED_OR_REVOKED_RESULT');
    }
    return result;
  }
}
