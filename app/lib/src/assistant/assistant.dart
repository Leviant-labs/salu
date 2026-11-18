import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
          'Connect an OpenAI API key in Settings first.',
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
          'OpenAI did not accept your API key. Check it in Settings.',
        SaluAssistantErrorCode.accessDenied =>
          'Your OpenAI project does not have access to this request.',
        SaluAssistantErrorCode.quotaExceeded =>
          'Check your API credits or spending limits in the OpenAI platform.',
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
    HttpClient Function()? httpClientFactory,
    Duration requestTimeout = const Duration(seconds: 45),
  })  : _keyStore = keyStore ?? const _SecureKeyStore(),
        _newClient = httpClientFactory ?? _createHttpClient,
        _requestTimeout = requestTimeout;

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
  static const _maxResponseBytes = 512 * 1024;
  static const _maxResultDepth = 32;

  final SaluAssistantKeyStore _keyStore;
  final HttpClient Function() _newClient;
  final Duration _requestTimeout;
  Future<void>? _keyChange;
  int _keyRevision = 0;
  bool _asking = false;
  HttpClient? _activeClient;

  /// Indicates a saved key, not verified API access or billing status.
  Future<bool> get isConnected async => await _readKey(_keyRevision) != null;

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
  Future<void> disconnect() => _changeKey(_keyStore.delete);

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
    final revision = _keyRevision;
    try {
      // Encode before waiting on storage, so a caller cannot accidentally
      // change the submitted bytes by reusing a mutable image buffer.
      final body = _makeBody(instructions, prompt, images);
      final key = await _readKey(revision);
      _checkRevision(revision);
      if (key == null) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }
      try {
        final client = _activeClient = _newClient();
        final result = await _post(client, key, body).timeout(_requestTimeout);
        _checkRevision(revision);
        return result;
      } on SaluAssistantException {
        _checkRevision(revision);
        rethrow;
      } on TimeoutException {
        _checkRevision(revision);
        throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
      } on Object {
        _checkRevision(revision);
        throw const SaluAssistantException(SaluAssistantErrorCode.networkError);
      }
    } finally {
      _closeRequest();
      _asking = false;
    }
  }

  static bool _isValidKey(String key) =>
      key.length <= 512 && _keyPattern.stringMatch(key) == key;

  static HttpClient _createHttpClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  void _checkRevision(int revision) {
    if (_keyRevision != revision) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
  }

  void _closeRequest() {
    final client = _activeClient;
    _activeClient = null;
    client?.close(force: true);
  }

  Future<void> _changeKey(Future<void> Function() change) {
    _keyRevision++;
    _closeRequest();
    final previous = _keyChange;
    final next = () async {
      try {
        await previous;
      } on SaluAssistantException {
        // Allow Settings to retry or replace a failed mutation.
      }
      await _withStorage(change);
    }();
    _keyChange = next;
    return next;
  }

  Future<String?> _readKey(int revision) async {
    // Fail closed if a prior key mutation failed (especially a failed delete).
    await _keyChange;
    final key = await _withStorage(_keyStore.read);
    if (_keyRevision != revision || key == null || !_isValidKey(key)) {
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

  static List<int> _makeBody(
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

    return utf8.encode(
      jsonEncode({
        'model': _configuredModel.trim().isEmpty
            ? _defaultModel
            : _configuredModel.trim(),
        'store': false,
        'max_output_tokens': 2048,
        'text': {
          'format': {'type': 'json_object'},
        },
        'input': [
          {
            'role': 'developer',
            'content': 'Return exactly one JSON object.\n\n$instructions',
          },
          {
            'role': 'user',
            'content': [
              if (hasPrompt) {'type': 'input_text', 'text': prompt},
              for (var i = 0; i < images.length; i++)
                {
                  'type': 'input_image',
                  'detail': 'auto',
                  'image_url':
                      'data:${mimeTypes[i]};base64,${base64Encode(images[i])}',
                },
            ],
          },
        ],
      }),
    );
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

  Future<Map<String, dynamic>> _post(
    HttpClient client,
    String key,
    List<int> body,
  ) async {
    final request = await client.postUrl(_endpoint);
    // A transport completing late must not upload after disconnect or timeout.
    if (!identical(_activeClient, client)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    request.followRedirects = false;
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final status = response.statusCode;
    if (status == HttpStatus.tooManyRequests) {
      // Inspect only the machine-readable quota code. Never surface the body.
      final error = await _readQuotaError(response);
      throw SaluAssistantException(error);
    }
    if (status != HttpStatus.ok) {
      throw SaluAssistantException(switch (status) {
        HttpStatus.unauthorized => SaluAssistantErrorCode.authenticationFailed,
        HttpStatus.forbidden => SaluAssistantErrorCode.accessDenied,
        HttpStatus.requestTimeout ||
        HttpStatus.gatewayTimeout =>
          SaluAssistantErrorCode.timeout,
        >= 500 && < 600 => SaluAssistantErrorCode.serviceUnavailable,
        _ => SaluAssistantErrorCode.requestRejected,
      });
    }
    return _parseResult(await _readBody(response), key);
  }

  static Future<SaluAssistantErrorCode> _readQuotaError(
    HttpClientResponse response,
  ) async {
    try {
      final Object? body = jsonDecode(await _readBody(response));
      if (body case {'error': {'code': 'insufficient_quota'}}) {
        return SaluAssistantErrorCode.quotaExceeded;
      }
    } on FormatException {
      // An unreadable body does not change the meaning of HTTP 429.
    } on SaluAssistantException {
      // An oversized body does not change the meaning of HTTP 429 either.
    }
    return SaluAssistantErrorCode.rateLimited;
  }

  static Future<String> _readBody(HttpClientResponse response) async {
    if (response.contentLength > _maxResponseBytes) throw _invalidResponse;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (chunk.length > _maxResponseBytes - bytes.length) {
        throw _invalidResponse;
      }
      bytes.add(chunk);
    }
    try {
      return utf8.decode(bytes.takeBytes());
    } on FormatException {
      throw _invalidResponse;
    }
  }

  static const _invalidResponse = SaluAssistantException(
    SaluAssistantErrorCode.invalidResponse,
  );

  static Map<String, dynamic> _parseResult(String body, String key) {
    try {
      final Object? envelope = jsonDecode(body);
      if (envelope case {'status': 'incomplete'}) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.incompleteResponse,
        );
      }
      if (envelope is! Map<String, dynamic> ||
          envelope['status'] != 'completed' ||
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
