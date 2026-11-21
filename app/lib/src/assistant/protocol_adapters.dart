import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:salu_core/salu_core.dart';

import 'assistant.dart';
import 'credential_store.dart';
import 'endpoint_transport.dart';
import 'operation_fence.dart';

const int maxGenerationTextCodeUnits = 24 * 1024;
const int maxGenerationImageCount = 4;
const int maxGenerationImageBytes = 4 * 1024 * 1024;
const int maxGenerationTotalImageBytes = 8 * 1024 * 1024;
const int maxGenerationTokens = 2048;
const int maxGenerationResultDepth = 32;
const String anthropicApiVersion = '2023-06-01';

final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');
const _invalidResponse =
    SaluAssistantException(SaluAssistantErrorCode.invalidResponse);
const _requestRejected =
    SaluAssistantException(SaluAssistantErrorCode.requestRejected);

/// Joins [relativePath] onto [root] while preserving any deployment path prefix.
///
/// Rejects absolute URLs, scheme/authority overrides, `..` traversal,
/// query strings, fragments, userinfo, and control characters.
Uri endpointUri(Uri root, String relativePath) {
  _validateRootUri(root);

  if (relativePath.isEmpty ||
      relativePath.trim() != relativePath ||
      _controlChars.hasMatch(relativePath) ||
      relativePath.startsWith('/') ||
      relativePath.contains('\\') ||
      relativePath.contains('?') ||
      relativePath.contains('#') ||
      relativePath.contains('@') ||
      relativePath.contains(':')) {
    throw _requestRejected;
  }

  final Uri parsedRel;
  try {
    parsedRel = Uri.parse(relativePath);
  } on FormatException {
    throw _requestRejected;
  }
  if (parsedRel.hasScheme ||
      parsedRel.hasAuthority ||
      parsedRel.hasQuery ||
      parsedRel.hasFragment ||
      parsedRel.isAbsolute) {
    throw _requestRejected;
  }

  final relSegments = relativePath.split('/');
  for (final segment in relSegments) {
    if (segment.isEmpty || segment == '.' || segment == '..') {
      throw _requestRejected;
    }
    final String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } on ArgumentError {
      throw _requestRejected;
    }
    if (decoded.isEmpty ||
        decoded == '.' ||
        decoded == '..' ||
        decoded.contains('/') ||
        decoded.contains('\\') ||
        _controlChars.hasMatch(decoded)) {
      throw _requestRejected;
    }
  }

  final rootSegments = _cleanPrefixSegments(root);
  final joined = root.replace(
    pathSegments: <String>[...rootSegments, ...relSegments],
  );
  if (!isUriUnderRootPrefix(root, joined) ||
      joined.hasQuery ||
      joined.hasFragment) {
    throw _requestRejected;
  }
  return joined;
}

/// Checks that [candidate] shares the exact origin of [root] and stays at or
/// under [root]'s path prefix without userinfo, fragments, or traversal segments.
bool isUriUnderRootPrefix(Uri root, Uri candidate) {
  if (!root.hasAuthority ||
      root.host.isEmpty ||
      !candidate.hasAuthority ||
      candidate.host.isEmpty) {
    return false;
  }
  if (candidate.userInfo.isNotEmpty ||
      candidate.authority.contains('@') ||
      candidate.hasFragment) {
    return false;
  }
  if (candidate.scheme != root.scheme ||
      candidate.host != root.host ||
      candidate.port != root.port) {
    return false;
  }

  for (final segment in candidate.pathSegments) {
    if (segment == '.' || segment == '..') {
      return false;
    }
  }

  final rootSegments = _cleanPrefixSegments(root);
  final candidateSegments =
      candidate.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (candidateSegments.length < rootSegments.length) {
    return false;
  }
  for (var i = 0; i < rootSegments.length; i++) {
    if (candidateSegments[i] != rootSegments[i]) {
      return false;
    }
  }
  return true;
}

void _validateRootUri(Uri root) {
  final rootText = root.toString();
  if (rootText.isEmpty || _controlChars.hasMatch(rootText)) {
    throw _requestRejected;
  }
  if (!root.hasAuthority ||
      root.host.isEmpty ||
      root.userInfo.isNotEmpty ||
      root.authority.contains('@') ||
      root.hasQuery ||
      root.hasFragment) {
    throw _requestRejected;
  }
  final scheme = root.scheme;
  if (scheme != 'https' && scheme != 'http') {
    throw _requestRejected;
  }
  for (final segment in root.pathSegments) {
    if (segment == '.' || segment == '..') {
      throw _requestRejected;
    }
    final String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } on ArgumentError {
      throw _requestRejected;
    }
    if (decoded == '.' ||
        decoded == '..' ||
        decoded.contains('/') ||
        decoded.contains('\\') ||
        _controlChars.hasMatch(decoded)) {
      throw _requestRejected;
    }
  }
}

List<String> _cleanPrefixSegments(Uri uri) =>
    uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);

/// Returns `image/jpeg` or `image/png` by inspecting magic bytes, or throws
/// [SaluAssistantErrorCode.unsupportedImage].
String detectSupportedImageMimeType(Uint8List bytes) {
  if (_startsWith(bytes, const <int>[0xff, 0xd8, 0xff])) {
    return 'image/jpeg';
  }
  if (_startsWith(bytes, const <int>[0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])) {
    return 'image/png';
  }
  throw const SaluAssistantException(SaluAssistantErrorCode.unsupportedImage);
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

/// Returns protocol-specific authentication and version headers for [secret].
Map<String, String> protocolAuthHeaders(
  EndpointProtocol protocol,
  String secret,
) =>
    switch (protocol) {
      EndpointProtocol.openaiChat ||
      EndpointProtocol.openaiResponses =>
        <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $secret',
        },
      EndpointProtocol.anthropicMessages => <String, String>{
          'x-api-key': secret,
          'anthropic-version': anthropicApiVersion,
        },
    };

/// Returns the relative endpoint path for generation on [protocol].
String generationRelativePath(EndpointProtocol protocol) => switch (protocol) {
      EndpointProtocol.openaiChat => 'chat/completions',
      EndpointProtocol.openaiResponses => 'responses',
      EndpointProtocol.anthropicMessages => 'messages',
    };

/// Validates [request] against [profile] and encodes a non-streamed generation
/// request body keeping [InferenceRequest.instructions] strictly separate from
/// untrusted [InferenceRequest.prompt] and [InferenceRequest.images].
Map<String, Object?> encodeGeneration(
  EndpointProfile profile,
  InferenceRequest request,
) {
  final modelId = profile.modelId?.trim();
  if (modelId == null || modelId.isEmpty) {
    throw _requestRejected;
  }

  if (request.instructions.length + request.prompt.length >
          maxGenerationTextCodeUnits ||
      request.images.length > maxGenerationImageCount) {
    throw const SaluAssistantException(SaluAssistantErrorCode.requestTooLarge);
  }

  final hasPrompt = request.prompt.trim().isNotEmpty;
  if (!hasPrompt && request.images.isEmpty) {
    throw const SaluAssistantException(SaluAssistantErrorCode.invalidInput);
  }

  if (request.images.isNotEmpty && profile.imageInput == false) {
    throw _requestRejected;
  }

  var totalImageBytes = 0;
  final encodedImages = <({String mimeType, String base64})>[];
  for (final image in request.images) {
    totalImageBytes += image.bytes.length;
    if (image.bytes.length > maxGenerationImageBytes ||
        totalImageBytes > maxGenerationTotalImageBytes) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.requestTooLarge,
      );
    }
    final detectedMime = detectSupportedImageMimeType(image.bytes);
    if (image.mimeType != detectedMime) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.unsupportedImage,
      );
    }
    encodedImages.add((
      mimeType: detectedMime,
      base64: base64Encode(image.bytes),
    ));
  }

  final trimmedInstructions = request.instructions.trim();
  final systemText = trimmedInstructions.isEmpty
      ? 'Return exactly one JSON object.'
      : 'Return exactly one JSON object.\n\n${request.instructions}';

  return switch (profile.protocol) {
    EndpointProtocol.openaiChat => <String, Object?>{
        'model': modelId,
        'stream': false,
        'max_tokens': maxGenerationTokens,
        'response_format': <String, Object?>{'type': 'json_object'},
        'messages': <Map<String, Object?>>[
          <String, Object?>{
            'role': 'system',
            'content': systemText,
          },
          <String, Object?>{
            'role': 'user',
            'content': <Map<String, Object?>>[
              if (hasPrompt)
                <String, Object?>{'type': 'text', 'text': request.prompt},
              for (final image in encodedImages)
                <String, Object?>{
                  'type': 'image_url',
                  'image_url': <String, Object?>{
                    'url': 'data:${image.mimeType};base64,${image.base64}',
                  },
                },
            ],
          },
        ],
      },
    EndpointProtocol.openaiResponses => <String, Object?>{
        'model': modelId,
        'stream': false,
        'store': false,
        'max_output_tokens': maxGenerationTokens,
        'instructions': systemText,
        'text': <String, Object?>{
          'format': <String, Object?>{'type': 'json_object'},
        },
        'input': <Map<String, Object?>>[
          <String, Object?>{
            'role': 'user',
            'content': <Map<String, Object?>>[
              if (hasPrompt)
                <String, Object?>{'type': 'input_text', 'text': request.prompt},
              for (final image in encodedImages)
                <String, Object?>{
                  'type': 'input_image',
                  'detail': 'auto',
                  'image_url': 'data:${image.mimeType};base64,${image.base64}',
                },
            ],
          },
        ],
      },
    EndpointProtocol.anthropicMessages => <String, Object?>{
        'model': modelId,
        'stream': false,
        'max_tokens': maxGenerationTokens,
        'system': systemText,
        'messages': <Map<String, Object?>>[
          <String, Object?>{
            'role': 'user',
            'content': <Map<String, Object?>>[
              if (hasPrompt)
                <String, Object?>{'type': 'text', 'text': request.prompt},
              for (final image in encodedImages)
                <String, Object?>{
                  'type': 'image',
                  'source': <String, Object?>{
                    'type': 'base64',
                    'media_type': image.mimeType,
                    'data': image.base64,
                  },
                },
            ],
          },
        ],
      },
  };
}

/// Decodes and validates a completed JSON-object generation [envelope] for
/// [protocol], rejecting incomplete replies, refusals, non-object JSON,
/// excessive nesting, non-finite numbers, and credential reflection.
Map<String, dynamic> decodeGeneration(
  EndpointProtocol protocol,
  Map<String, dynamic> envelope, {
  String? secretToScrub,
}) {
  final rawText = switch (protocol) {
    EndpointProtocol.openaiChat => _extractOpenAiChatText(envelope),
    EndpointProtocol.openaiResponses => _extractOpenAiResponsesText(envelope),
    EndpointProtocol.anthropicMessages =>
      _extractAnthropicMessagesText(envelope),
  };

  final Object? decoded;
  try {
    decoded = jsonDecode(rawText);
  } on FormatException {
    throw _invalidResponse;
  }

  if (decoded is! Map<String, dynamic>) {
    throw _invalidResponse;
  }
  final scrubbedSecret =
      (secretToScrub == null || secretToScrub.isEmpty) ? null : secretToScrub;
  if (scrubbedSecret != null && rawText.contains(scrubbedSecret)) {
    throw _invalidResponse;
  }
  _validateDecodedValue(decoded, scrubbedSecret, 0);
  return decoded;
}

String _extractOpenAiChatText(Map<String, dynamic> envelope) {
  if (envelope['error'] != null) {
    throw _invalidResponse;
  }
  final choices = envelope['choices'];
  if (choices is! List<Object?> || choices.isEmpty) {
    throw _invalidResponse;
  }
  final firstChoice = choices.first;
  if (firstChoice is! Map) {
    throw _invalidResponse;
  }

  final finishReason = firstChoice['finish_reason'];
  switch (finishReason) {
    case 'stop':
      break;
    case 'length' || null:
      throw const SaluAssistantException(
        SaluAssistantErrorCode.incompleteResponse,
      );
    case 'content_filter':
      throw const SaluAssistantException(SaluAssistantErrorCode.refused);
    default:
      throw _invalidResponse;
  }

  final message = firstChoice['message'];
  if (message is! Map) {
    throw _invalidResponse;
  }
  final role = message['role'];
  if (role != null && role != 'assistant') {
    throw _invalidResponse;
  }

  final refusal = message['refusal'];
  if (refusal != null && (refusal is! String || refusal.isNotEmpty)) {
    throw const SaluAssistantException(SaluAssistantErrorCode.refused);
  }

  final toolCalls = message['tool_calls'];
  if (toolCalls != null && (toolCalls is! List || toolCalls.isNotEmpty)) {
    throw _invalidResponse;
  }
  if (message['function_call'] != null) {
    throw _invalidResponse;
  }

  final content = message['content'];
  if (content is String) {
    return content;
  }
  if (content is List<Object?>) {
    final buffer = StringBuffer();
    for (final part in content) {
      switch (part) {
        case {'type': 'refusal'}:
          throw const SaluAssistantException(SaluAssistantErrorCode.refused);
        case {'type': 'text', 'text': final String value}:
          buffer.write(value);
        default:
          throw _invalidResponse;
      }
    }
    return buffer.toString();
  }
  throw _invalidResponse;
}

String _extractOpenAiResponsesText(Map<String, dynamic> envelope) {
  if (envelope case {'status': 'incomplete'}) {
    throw const SaluAssistantException(
      SaluAssistantErrorCode.incompleteResponse,
    );
  }
  if (envelope['status'] != 'completed' ||
      envelope['error'] != null ||
      envelope['output'] is! List<Object?>) {
    throw _invalidResponse;
  }

  final text = StringBuffer();
  for (final item in envelope['output'] as List<Object?>) {
    if (item case {'type': 'reasoning'}) continue;
    if (item
        case {
          'type': 'message',
          'role': 'assistant',
          'status': 'completed',
          'content': final List<Object?> content,
        }) {
      for (final part in content) {
        switch (part) {
          case {'type': 'refusal'}:
            throw const SaluAssistantException(SaluAssistantErrorCode.refused);
          case {'type': 'output_text', 'text': final String value}:
            text.write(value);
          default:
            throw _invalidResponse;
        }
      }
    } else {
      throw _invalidResponse;
    }
  }
  return text.toString();
}

String _extractAnthropicMessagesText(Map<String, dynamic> envelope) {
  if (envelope['error'] != null) {
    throw _invalidResponse;
  }
  if (envelope.containsKey('type') && envelope['type'] != 'message') {
    throw _invalidResponse;
  }
  if (envelope.containsKey('role') && envelope['role'] != 'assistant') {
    throw _invalidResponse;
  }

  final stopReason = envelope['stop_reason'];
  switch (stopReason) {
    case 'end_turn' || 'stop_sequence':
      break;
    case 'max_tokens' || 'pause_turn' || null:
      throw const SaluAssistantException(
        SaluAssistantErrorCode.incompleteResponse,
      );
    case 'refusal':
      throw const SaluAssistantException(SaluAssistantErrorCode.refused);
    default:
      throw _invalidResponse;
  }

  final content = envelope['content'];
  if (content is! List<Object?> || content.isEmpty) {
    throw _invalidResponse;
  }

  final text = StringBuffer();
  for (final block in content) {
    switch (block) {
      case {'type': 'refusal'}:
        throw const SaluAssistantException(SaluAssistantErrorCode.refused);
      case {'type': 'text', 'text': final String value}:
        text.write(value);
      default:
        throw _invalidResponse;
    }
  }
  return text.toString();
}

void _validateDecodedValue(Object? value, String? secret, int depth) {
  if (depth > maxGenerationResultDepth) {
    throw _invalidResponse;
  }
  switch (value) {
    case Map<String, dynamic>():
      for (final entry in value.entries) {
        if (secret != null && entry.key.contains(secret)) {
          throw _invalidResponse;
        }
        _validateDecodedValue(entry.value, secret, depth + 1);
      }
    case List<Object?>():
      for (final item in value) {
        _validateDecodedValue(item, secret, depth + 1);
      }
    case String() when secret != null && value.contains(secret):
    case num() when !value.isFinite:
      throw _invalidResponse;
  }
}

/// Explicit [InferenceProvider] implementation for a user-configured
/// [EndpointProfile].
final class EndpointInferenceProvider implements InferenceProvider {
  EndpointInferenceProvider({
    required this.profile,
    required CredentialStore credentials,
    required EndpointTransport transport,
    required OperationFence fence,
    Duration timeout = const Duration(seconds: 45),
  })  : _credentials = credentials,
        _transport = transport,
        _fence = fence,
        _timeout = timeout;

  final EndpointProfile profile;
  final CredentialStore _credentials;
  final EndpointTransport _transport;
  final OperationFence _fence;
  final Duration _timeout;

  @override
  String get providerId => profile.id;

  @override
  Set<InferenceCapability> get capabilities => <InferenceCapability>{
        InferenceCapability.structuredOutput,
        InferenceCapability.cancellation,
        if (profile.imageInput == true) InferenceCapability.imageInput,
      };

  @override
  bool supports(InferenceTask task) => true;

  @override
  Future<InferenceResponse> infer(InferenceRequest request) async {
    final epoch = _fence.capture();
    final stopwatch = Stopwatch()..start();
    Duration remaining() {
      final left = _timeout - stopwatch.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    // Validate and snapshot inputs locally before reading credentials or
    // touching the network.
    final payload = encodeGeneration(profile, request);
    final uri =
        endpointUri(profile.apiRoot, generationRelativePath(profile.protocol));

    final String? secret;
    try {
      secret = await _credentials.read(profile.credentialRef);
    } on Object {
      if (!_fence.isCurrent(epoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      throw const SaluAssistantException(
        SaluAssistantErrorCode.storageUnavailable,
      );
    }

    if (!_fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    if (secret == null || secret.trim().isEmpty) {
      throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
    }
    final normalizedSecret = secret.trim();

    final envelope = await _transport.send(
      uri: uri,
      method: 'POST',
      headers: protocolAuthHeaders(profile.protocol, normalizedSecret),
      body: payload,
      allowInsecureLocal: profile.allowInsecureLocal,
      fence: _fence,
      maxBytes: EndpointTransport.defaultMaxBytes,
      deadline: remaining(),
      epoch: epoch,
    );

    if (!_fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final decoded = decodeGeneration(
      profile.protocol,
      envelope,
      secretToScrub: normalizedSecret,
    );

    if (!_fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    return InferenceResponse(
      requestId: request.requestId,
      text: jsonEncode(decoded),
      structured: decoded,
    );
  }

  @override
  Future<void> disconnect() async {
    _fence.invalidate();
  }
}
