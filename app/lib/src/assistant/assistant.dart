import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'chatgpt_session.dart';
import 'endpoint_transport.dart';
import 'operation_fence.dart';

enum SaluAssistantErrorCode {
  notConnected,
  connectionChanged,
  invalidKey,
  storageUnavailable,
  busy,
  invalidInput,
  requestTooLarge,
  unsupportedImage,
  authenticationFailed,
  accessDenied,
  quotaExceeded,
  rateLimited,
  timeout,
  networkError,
  serviceUnavailable,
  requestRejected,
  invalidResponse,
  incompleteResponse,
  refused,
}

/// Safe to display. Deliberately excludes provider messages and raw causes.
final class SaluAssistantException implements Exception {
  const SaluAssistantException(this.code);

  final SaluAssistantErrorCode code;

  String get message => switch (code) {
        SaluAssistantErrorCode.notConnected =>
          'Continue with ChatGPT in Settings first.',
        SaluAssistantErrorCode.connectionChanged =>
          'The OpenAI connection changed. Please try again.',
        SaluAssistantErrorCode.invalidKey => 'Enter a valid OpenAI API key.',
        SaluAssistantErrorCode.storageUnavailable =>
          'Could not access secure storage for your OpenAI key.',
        SaluAssistantErrorCode.busy =>
          'An assistant request is already running.',
        SaluAssistantErrorCode.invalidInput => 'Enter text or attach an image.',
        SaluAssistantErrorCode.requestTooLarge =>
          'The request is too large. Shorten the text or use fewer or smaller images.',
        SaluAssistantErrorCode.unsupportedImage => 'Use JPEG or PNG images.',
        SaluAssistantErrorCode.authenticationFailed =>
          'Your OpenAI session expired. Reconnect in Settings.',
        SaluAssistantErrorCode.accessDenied =>
          'Your account does not have access to this request.',
        SaluAssistantErrorCode.quotaExceeded =>
          'Check your ChatGPT plan usage and limits.',
        SaluAssistantErrorCode.rateLimited =>
          'OpenAI is rate limiting requests. Wait a moment and try again.',
        SaluAssistantErrorCode.timeout => 'The OpenAI request timed out.',
        SaluAssistantErrorCode.networkError =>
          'Could not reach OpenAI. Check your internet connection.',
        SaluAssistantErrorCode.serviceUnavailable =>
          'OpenAI is temporarily unavailable. Try again later.',
        SaluAssistantErrorCode.requestRejected =>
          'OpenAI rejected the request. Check your input or model access.',
        SaluAssistantErrorCode.invalidResponse =>
          'OpenAI returned an invalid reply.',
        SaluAssistantErrorCode.incompleteResponse =>
          'OpenAI did not finish the reply. Try a shorter request.',
        SaluAssistantErrorCode.refused =>
          'OpenAI declined to answer this request.',
      };

  @override
  String toString() => message;
}

/// Storage port for the single local OpenAI credential.
abstract interface class SaluAssistantKeyStore {
  Future<String?> read();
  Future<void> write(String key);
  Future<void> delete();
}

final class _SecureKeyStore implements SaluAssistantKeyStore {
  const _SecureKeyStore();

  static const _storage = FlutterSecureStorage();
  static const _slot = 'salu.assistant.openai.api_key';

  @override
  Future<String?> read() => _storage.read(key: _slot);

  @override
  Future<void> write(String key) => _storage.write(key: _slot, value: key);

  @override
  Future<void> delete() => _storage.delete(key: _slot);
}

/// Optional native client for the OpenAI API. Only [ask] uses the network.
/// Share one instance between Settings and callers so changing the key can
/// abort its in-flight request. The default transport and storage are lazy.
final class SaluAssistant {
  /// An injected HTTP factory must return a fresh client for each request.
  SaluAssistant({
    SaluAssistantKeyStore? keyStore,
    ChatGptSession? chatGptSession,
    HttpClient Function()? httpClientFactory,
    Duration requestTimeout = const Duration(seconds: 45),
    OperationFence? fence,
    EndpointTransport? transport,
  })  : _keyStore = keyStore ?? const _SecureKeyStore(),
        _fence = fence ?? OperationFence(),
        _requestTimeout = requestTimeout,
        _ownsChatGpt = chatGptSession == null && keyStore == null {
    _transport = transport ??
        EndpointTransport(
          clientFactory: httpClientFactory,
          timeout: requestTimeout,
        );
    _chatgpt = chatGptSession ??
        (keyStore == null
            ? ChatGptSession(
                transport: _transport,
                fence: _fence,
                timeout: requestTimeout,
              )
            : null);
  }

  static final _endpoint = Uri.https('api.openai.com', '/v1/responses');
  static const _defaultModel = 'gpt-4.1-mini';
  static const _configuredModel = String.fromEnvironment(
    'SALU_OPENAI_MODEL',
    defaultValue: _defaultModel,
  );
  static final _keyPattern = RegExp(r'^[a-zA-Z0-9_-]{1,512}$');
  static const _maxTextCodeUnits = 24 * 1024;
  static const _maxImageCount = 4;
  static const _maxImageBytes = 4 * 1024 * 1024;
  static const _maxTotalImageBytes = 8 * 1024 * 1024;
  static const _maxResponseBytes = EndpointTransport.defaultMaxBytes;
  static const _maxResultDepth = 32;

  final SaluAssistantKeyStore _keyStore;
  final OperationFence _fence;
  late final EndpointTransport _transport;
  late final ChatGptSession? _chatgpt;
  final bool _ownsChatGpt;
  final Duration _requestTimeout;
  Future<void>? _keyChange;
  bool _asking = false;

  /// Indicates a saved key, not verified API access or billing status.
  Future<bool> get isConnected async => _chatgpt != null
      ? _chatgpt.isConnected
      : await _readKey(_fence.capture()) != null;

  Future<void> signInWithChatGpt() async {
    await _changeKey(() => _chatgpt!.signIn(), storageOnly: false);
  }

  /// Save a key locally. Its authorization is first checked by an explicit ask.
  Future<void> connect(String key) async {
    final normalized = key.trim();
    if (!_isValidKey(normalized)) {
      throw const SaluAssistantException(SaluAssistantErrorCode.invalidKey);
    }
    await _changeKey(() => _keyStore.write(normalized));
  }

  /// Forget the local key and abort any local in-flight request. This cannot
  /// undo a submission that OpenAI has already received or revoke the API key.
  Future<void> disconnect() => _changeKey(
        _chatgpt == null ? _keyStore.delete : _chatgpt.signOut,
        storageOnly: _chatgpt == null,
      );

  /// Send only the supplied inputs. Returns an untrusted JSON object whose
  /// task-specific fields must still be validated by the caller.
  Future<Map<String, dynamic>> ask({
    required String instructions,
    required String prompt,
    List<Uint8List> images = const [],
  }) async {
    if (_asking) {
      throw const SaluAssistantException(SaluAssistantErrorCode.busy);
    }
    _asking = true;
    final epoch = _fence.capture();
    final stopwatch = Stopwatch()..start();
    Duration remaining() {
      final left = _requestTimeout - stopwatch.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    try {
      // Encode before waiting on storage, so a caller cannot accidentally
      // change the submitted bytes by reusing a mutable image buffer.
      final payload = _makePayload(instructions, prompt, images);
      String? key;
      if (_chatgpt != null) {
        try {
          await _keyChange;
        } on Object {
          // A failed sign-in leaves the previous session intact; a failed
          // sign-out clears its local credentials in ChatGptSession.
        }
        if (!await _chatgpt.isConnected) {
          _checkFence(epoch);
          throw const SaluAssistantException(
            SaluAssistantErrorCode.notConnected,
          );
        }
        try {
          await _chatgpt.runWithBudget(
            deadline: remaining(),
            fence: _fence,
            epoch: epoch,
            action: () async {
              key = await _chatgpt.accessToken();
              final model = await _chatgpt.model(key!);
              payload['model'] = model;
              payload['stream'] = true;
              payload.remove('max_output_tokens');
            },
          );
        } on SaluAssistantException {
          _checkFence(epoch);
          rethrow;
        } on TimeoutException {
          _checkFence(epoch);
          throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
        } on SocketException {
          _checkFence(epoch);
          throw const SaluAssistantException(
            SaluAssistantErrorCode.networkError,
          );
        } on HttpException {
          _checkFence(epoch);
          throw const SaluAssistantException(
            SaluAssistantErrorCode.networkError,
          );
        } on Object {
          _checkFence(epoch);
          throw const SaluAssistantException(
            SaluAssistantErrorCode.authenticationFailed,
          );
        }
      } else {
        key = await _readKey(epoch);
      }

      _checkFence(epoch);
      if (key == null) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }

      final headers = <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $key',
      };
      final envelope = _chatgpt != null
          ? await _transport.sendSse(
              uri: _endpoint,
              method: 'POST',
              headers: headers,
              body: payload,
              allowInsecureLocal: false,
              fence: _fence,
              maxBytes: _maxResponseBytes,
              deadline: remaining(),
              epoch: epoch,
            )
          : await _transport.send(
              uri: _endpoint,
              method: 'POST',
              headers: headers,
              body: payload,
              allowInsecureLocal: false,
              fence: _fence,
              maxBytes: _maxResponseBytes,
              deadline: remaining(),
              epoch: epoch,
            );
      _checkFence(epoch);
      final result = _parseEnvelope(envelope, key!);
      _checkFence(epoch);
      return result;
    } finally {
      _asking = false;
    }
  }

  static bool _isValidKey(String key) =>
      key.length <= 512 && _keyPattern.stringMatch(key) == key;

  void _checkFence(int epoch) {
    if (!_fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
  }

  Future<void> _changeKey(Future<void> Function() change,
      {bool storageOnly = true}) {
    _fence.invalidate();
    if (_chatgpt != null && !_ownsChatGpt) {
      _chatgpt.invalidate();
    }
    final previous = _keyChange;
    final next = () async {
      try {
        await previous;
      } on Object {
        // Allow Settings to retry or replace a failed mutation.
      }
      if (storageOnly) {
        await _withStorage(change);
      } else {
        await change();
      }
    }();
    _keyChange = next;
    return next;
  }

  Future<String?> _readKey(int epoch) async {
    // Fail closed if a prior key mutation failed (especially a failed delete).
    await _keyChange;
    final key = await _withStorage(_keyStore.read);
    if (!_fence.isCurrent(epoch) || key == null || !_isValidKey(key)) {
      return null;
    }
    return key;
  }

  static Future<T> _withStorage<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on Object {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.storageUnavailable,
      );
    }
  }

  static Map<String, Object?> _makePayload(
    String instructions,
    String prompt,
    List<Uint8List> images,
  ) {
    if (instructions.length + prompt.length > _maxTextCodeUnits ||
        images.length > _maxImageCount) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.requestTooLarge,
      );
    }
    final hasPrompt = prompt.trim().isNotEmpty;
    if (!hasPrompt && images.isEmpty) {
      throw const SaluAssistantException(SaluAssistantErrorCode.invalidInput);
    }
    var totalImageBytes = 0;
    final mimeTypes = <String>[];
    for (final image in images) {
      totalImageBytes += image.length;
      if (image.length > _maxImageBytes ||
          totalImageBytes > _maxTotalImageBytes) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.requestTooLarge,
        );
      }
      mimeTypes.add(_imageMimeType(image));
    }

    return <String, Object?>{
      'model': _configuredModel.trim().isEmpty
          ? _defaultModel
          : _configuredModel.trim(),
      'store': false,
      'max_output_tokens': 2048,
      'text': <String, Object?>{
        'format': <String, Object?>{'type': 'json_object'},
      },
      'input': <Map<String, Object?>>[
        <String, Object?>{
          'role': 'developer',
          'content': 'Return exactly one JSON object.\n\n$instructions',
        },
        <String, Object?>{
          'role': 'user',
          'content': <Map<String, Object?>>[
            if (hasPrompt)
              <String, Object?>{'type': 'input_text', 'text': prompt},
            for (var i = 0; i < images.length; i++)
              <String, Object?>{
                'type': 'input_image',
                'detail': 'auto',
                'image_url':
                    'data:${mimeTypes[i]};base64,${base64Encode(images[i])}',
              },
          ],
        },
      ],
    };
  }

  static String _imageMimeType(Uint8List bytes) {
    if (_startsWith(bytes, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
    if (_startsWith(bytes, const [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])) {
      return 'image/png';
    }
    throw const SaluAssistantException(SaluAssistantErrorCode.unsupportedImage);
  }

  static bool _startsWith(Uint8List bytes, List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  static const _invalidResponse = SaluAssistantException(
    SaluAssistantErrorCode.invalidResponse,
  );

  static Map<String, dynamic> _parseEnvelope(
    Map<String, dynamic> envelope,
    String key,
  ) {
    try {
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
                throw const SaluAssistantException(
                  SaluAssistantErrorCode.refused,
                );
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
      final Object? result = jsonDecode(text.toString());
      if (result is! Map<String, dynamic>) throw _invalidResponse;
      _validateValue(result, key, 0);
      return result;
    } on FormatException {
      throw _invalidResponse;
    }
  }

  static void _validateValue(Object? value, String key, int depth) {
    if (depth > _maxResultDepth) throw _invalidResponse;
    switch (value) {
      case Map<String, dynamic>():
        for (final entry in value.entries) {
          if (entry.key.contains(key)) throw _invalidResponse;
          _validateValue(entry.value, key, depth + 1);
        }
      case List<Object?>():
        for (final item in value) {
          _validateValue(item, key, depth + 1);
        }
      case String() when value.contains(key):
      case num() when !value.isFinite:
        throw _invalidResponse;
    }
  }
}
