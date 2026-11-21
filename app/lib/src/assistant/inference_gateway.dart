import 'dart:convert';
import 'dart:typed_data';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'assistant.dart';
import 'credential_store.dart';
import 'endpoint_transport.dart';
import 'operation_fence.dart';
import 'protocol_adapters.dart';

/// Production inference dispatch facade routing strictly to the explicitly
/// selected active provider (`chatgpt-plan` or a configured [EndpointProfile])
/// with zero automatic provider or model fallback.
final class InferenceGateway {
  InferenceGateway({
    required EndpointProfilesStore profiles,
    required CredentialStore credentials,
    required EndpointTransport transport,
    required OperationFence fence,
    required SaluAssistant chatGpt,
    Duration requestTimeout = const Duration(seconds: 45),
  })  : _profiles = profiles,
        _credentials = credentials,
        _transport = transport,
        _fence = fence,
        _chatGpt = chatGpt,
        _requestTimeout = requestTimeout;

  final EndpointProfilesStore _profiles;
  final CredentialStore _credentials;
  final EndpointTransport _transport;
  final OperationFence _fence;
  final SaluAssistant _chatGpt;
  final Duration _requestTimeout;

  int _requestCounter = 0;
  bool _asking = false;

  /// Whether the explicitly active provider currently has a usable credential
  /// or session. Never falls back to another configured provider.
  Future<bool> get isConnected async {
    final state = await _profiles.load();
    final activeId = state.activeId;
    if (activeId == null) return false;
    if (activeId == EndpointProfile.reservedChatGptId) {
      return _chatGpt.isConnected;
    }
    final profile = _findProfile(state.profiles, activeId);
    if (profile == null) return false;
    final secret = await _readSecret(profile.credentialRef);
    return secret != null && secret.trim().isNotEmpty;
  }

  /// Display label for the active connected provider, or `null` when
  /// disconnected.
  Future<String?> get activeProviderLabel async {
    final state = await _profiles.load();
    final activeId = state.activeId;
    if (activeId == null) return null;
    if (activeId == EndpointProfile.reservedChatGptId) {
      return await _chatGpt.isConnected ? 'ChatGPT' : null;
    }
    final profile = _findProfile(state.profiles, activeId);
    if (profile == null) return null;
    final secret = await _readSecret(profile.credentialRef);
    if (secret == null || secret.trim().isEmpty) return null;
    return profile.name;
  }

  /// Neutral provenance identifier for the active connected provider, or `null`
  /// when disconnected.
  Future<String?> get activeProviderProvenance async {
    final state = await _profiles.load();
    final activeId = state.activeId;
    if (activeId == null) return null;
    if (activeId == EndpointProfile.reservedChatGptId) {
      return await _chatGpt.isConnected
          ? EndpointProfile.reservedChatGptId
          : null;
    }
    final profile = _findProfile(state.profiles, activeId);
    if (profile == null) return null;
    final secret = await _readSecret(profile.credentialRef);
    if (secret == null || secret.trim().isEmpty) return null;
    return profile.protocol.name;
  }

  /// Sends one inference request to the explicitly active provider.
  ///
  /// Validates text bounds and detects JPEG/PNG magic bytes locally before
  /// loading credentials or contacting the network.
  Future<Map<String, dynamic>> ask({
    required String instructions,
    required String prompt,
    List<Uint8List> images = const <Uint8List>[],
    InferenceTask task = InferenceTask.mealPhoto,
    String? requestId,
  }) async {
    if (_asking) {
      throw const SaluAssistantException(SaluAssistantErrorCode.busy);
    }
    _asking = true;
    final epoch = _fence.capture();

    try {
      if (instructions.length + prompt.length > maxGenerationTextCodeUnits ||
          images.length > maxGenerationImageCount) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.requestTooLarge,
        );
      }
      if (prompt.trim().isEmpty && images.isEmpty) {
        throw const SaluAssistantException(SaluAssistantErrorCode.invalidInput);
      }

      var totalImageBytes = 0;
      final attachments = <ImageAttachment>[];
      for (final rawImage in images) {
        final snapshot = Uint8List.fromList(rawImage);
        totalImageBytes += snapshot.length;
        if (snapshot.length > maxGenerationImageBytes ||
            totalImageBytes > maxGenerationTotalImageBytes) {
          throw const SaluAssistantException(
            SaluAssistantErrorCode.requestTooLarge,
          );
        }
        final mimeType = detectSupportedImageMimeType(snapshot);
        attachments.add(ImageAttachment(bytes: snapshot, mimeType: mimeType));
      }

      final trimmedRequestId = requestId?.trim();
      final effectiveRequestId =
          (trimmedRequestId != null && trimmedRequestId.isNotEmpty)
              ? trimmedRequestId
              : 'req_${++_requestCounter}';
      final request = InferenceRequest(
        requestId: effectiveRequestId,
        task: task,
        instructions: instructions,
        prompt: prompt,
        images: List<ImageAttachment>.unmodifiable(attachments),
      );

      final state = await _profiles.load();
      if (!_fence.isCurrent(epoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }

      final activeId = state.activeId;
      if (activeId == null) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }

      if (activeId == EndpointProfile.reservedChatGptId) {
        final result = await _chatGpt.ask(
          instructions: request.instructions,
          prompt: request.prompt,
          images: <Uint8List>[
            for (final attachment in request.images) attachment.bytes,
          ],
        );
        if (!_fence.isCurrent(epoch)) {
          throw const SaluAssistantException(
            SaluAssistantErrorCode.connectionChanged,
          );
        }
        return result;
      }

      final profile = _findProfile(state.profiles, activeId);
      if (profile == null) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }
      if (profile.modelId == null || profile.modelId!.trim().isEmpty) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.requestRejected,
        );
      }

      final provider = EndpointInferenceProvider(
        profile: profile,
        credentials: _credentials,
        transport: _transport,
        fence: _fence,
        timeout: _requestTimeout,
      );
      final response = await provider.infer(request);
      if (!_fence.isCurrent(epoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      final structured = response.structured;
      if (structured != null) {
        return Map<String, dynamic>.from(structured);
      }
      return jsonDecode(response.text) as Map<String, dynamic>;
    } finally {
      _asking = false;
    }
  }

  /// Invalidates in-flight fenced operations, clears active selection, and
  /// disconnects any ChatGPT session.
  Future<void> disconnect() async {
    _fence.invalidate();
    await _clearActiveSelection();
    await _chatGpt.disconnect();
  }

  Future<void> _clearActiveSelection() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final state = await _profiles.load();
      if (state.activeId == null) return;
      final saved = await _profiles.save(
        expectedRevision: state.revision,
        profiles: state.profiles,
        activeId: null,
      );
      if (saved) return;
    }
    throw const SaluAssistantException(
      SaluAssistantErrorCode.storageUnavailable,
    );
  }

  Future<String?> _readSecret(String ref) async {
    try {
      return await _credentials.read(ref);
    } on Object {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.storageUnavailable,
      );
    }
  }

  static EndpointProfile? _findProfile(
    List<EndpointProfile> profiles,
    String id,
  ) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }
}
