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
    return MealDraft(
        id: id,
        revision: revision + 1,
        status: status == DraftStatus.review
            ? DraftStatus.review
            : DraftStatus.editing,
        values: replacement);
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

  MealDraft cancel() {
    if (status == DraftStatus.committed || status == DraftStatus.cancelled) {
      throw StateError('DRAFT_CLOSED');
    }
    return MealDraft(
        id: id,
        revision: revision + 1,
        status: DraftStatus.cancelled,
        values: values);
  }
}

/// Owns the current draft while a provider response is in flight. Only an
/// explicitly validated response can be placed in the review state.
/// Editing or cancelling invalidates an outstanding result; retries require a
/// new explicit request and consent. This object never writes a diary entry.
final class InferenceDraftSession {
  InferenceDraftSession(MealDraft draft) : _draft = draft;

  MealDraft _draft;
  bool _inFlight = false;
  MealDraft get draft => _draft;
  bool get inFlight => _inFlight;

  void edit(Map<String, Object?> replacement) {
    _draft = _draft.edit(replacement);
  }

  void cancel() {
    _draft = _draft.cancel();
  }

  void confirm({required int expectedRevision, required bool reviewed}) {
    _draft =
        _draft.confirm(expectedRevision: expectedRevision, reviewed: reviewed);
  }

  Future<void> requestSuggestion({
    required InferenceProvider provider,
    required ProviderAuthorization authorization,
    required InferenceRequest request,
    required TransferConsent consent,
    required DateTime now,
    required Map<String, Object?> Function(Map<String, Object?>) validate,
  }) async {
    if (_inFlight) throw StateError('REQUEST_IN_FLIGHT');
    final origin = _draft;
    _inFlight = true;
    try {
      final response = await const ReviewedInferenceService().request(
        provider: provider,
        authorization: authorization,
        request: request,
        draft: origin,
        consent: consent,
        now: now,
      );
      if (_draft.revision != origin.revision ||
          _draft.id != origin.id ||
          _draft.status == DraftStatus.cancelled ||
          _draft.status == DraftStatus.committed) {
        throw StateError('STALE_DRAFT');
      }
      final validated = validate(response.structured!);
      _draft = _draft.receive(
          expectedRevision: origin.revision, suggestion: validated);
    } finally {
      _inFlight = false;
    }
  }
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
