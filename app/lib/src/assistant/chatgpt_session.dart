import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jose/jose.dart';
import 'package:url_launcher/url_launcher.dart';

import 'assistant.dart';
import 'credential_store.dart';
import 'endpoint_transport.dart';
import 'operation_fence.dart';

/// Sign in with ChatGPT's public-client, dynamic-registration flow.
class ChatGptSession {
  ChatGptSession({
    EndpointTransport? transport,
    OperationFence? fence,
    SecureKeyValueStorage? storage,
    Duration timeout = const Duration(seconds: 45),
  })  : _transport = transport ?? EndpointTransport(timeout: timeout),
        _fence = fence ?? OperationFence(),
        _storage = storage ?? const FlutterSecureStorageAdapter(),
        _timeout = timeout;

  static const _sessionKey = 'salu.chatgpt.session.v1';
  static const _hostKey = 'salu.chatgpt.host.v1';
  static const _resource = 'https://api.openai.com/v1';
  static final _tokenEndpoint =
      Uri.parse('https://auth.openai.com/api/accounts/oauth/token');
  static final _revokeEndpoint =
      Uri.parse('https://auth.openai.com/api/accounts/oauth/revoke');
  static final _jwksEndpoint =
      Uri.parse('https://auth.openai.com/.well-known/jwks.json');
  static final _budgetZoneKey = Object();

  final EndpointTransport _transport;
  final OperationFence _fence;
  final SecureKeyValueStorage _storage;
  final Duration _timeout;

  Future<String>? _refreshing;
  int _revision = 0;
  String? _cachedModel;
  int? _cachedModelRevision;
  int? _cachedModelEpoch;

  /// Invalidates in-flight ChatGPT session operations and clears cached state.
  void invalidate() {
    _revision++;
    _clearModelCache();
    _fence.invalidate();
  }

  /// Runs [action] with a shared deadline and [OperationFence] budget.
  Future<T> runWithBudget<T>({
    required Duration deadline,
    required OperationFence fence,
    required int epoch,
    required Future<T> Function() action,
  }) {
    final budget = _ChatGptRequestBudget(
      stopwatch: Stopwatch()..start(),
      totalDeadline: deadline,
      fence: fence,
      epoch: epoch,
    );
    return runZoned(
      action,
      zoneValues: <Object, Object>{_budgetZoneKey: budget},
    );
  }

  void _clearModelCache() {
    _cachedModel = null;
    _cachedModelRevision = null;
    _cachedModelEpoch = null;
  }

  Future<Map<String, dynamic>?> _read() async {
    final String? value;
    try {
      value = await _storage.read(key: _sessionKey);
    } on Object {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.storageUnavailable,
      );
    }
    if (value == null) return null;
    return jsonDecode(value) as Map<String, dynamic>;
  }

  Future<void> _writeSession(String value) async {
    try {
      await _storage.write(key: _sessionKey, value: value);
    } on Object {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.storageUnavailable,
      );
    }
  }

  Future<bool> get isConnected async =>
      (await _read())?['refresh_token'] is String;

  Future<void> signIn() async {
    final revision = ++_revision;
    final epoch = _fence.capture();
    _clearModelCache();

    final old = await _read();
    if (!_fence.isCurrent(epoch) || revision != _revision) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    String? host;
    try {
      host = await _storage.read(key: _hostKey);
    } on Object {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.storageUnavailable,
      );
    }
    if (!_fence.isCurrent(epoch) || revision != _revision) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    if (host == null) {
      final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      host =
          'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      try {
        await _storage.write(key: _hostKey, value: host);
      } on Object {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.storageUnavailable,
        );
      }
      if (!_fence.isCurrent(epoch) || revision != _revision) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = Completer<Uri>();
    final unregisterFence = _fence.onInvalidate(() {
      if (!result.isCompleted) {
        result.completeError(
          const SaluAssistantException(
            SaluAssistantErrorCode.connectionChanged,
          ),
        );
      }
      unawaited(server.close(force: true));
    });

    final redirect = 'http://127.0.0.1:${server.port}/auth/callback';
    final state = _random();
    final nonce = _random();
    final verifier = _random(64);
    final clientId = old?['client_id'] as String?;
    final url = Uri.https('auth.openai.com', '/api/accounts/authorize', {
      'client_id': clientId ?? 'dynamic_agent_client',
      if (clientId == null) 'agent_name_hint': 'Salu',
      'ext_agent_host_id': host,
      if (old?['id_token'] is String)
        'id_token_hint': old!['id_token'] as String,
      'response_type': 'code',
      'redirect_uri': redirect,
      'scope':
          'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
      'resource': _resource,
      'state': state,
      'nonce': nonce,
      'code_challenge_method': 'S256',
      'code_challenge': _base64(sha256.convert(ascii.encode(verifier)).bytes),
    });

    try {
      if (!_fence.isCurrent(epoch) || revision != _revision) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open your browser.');
      }
      if (!_fence.isCurrent(epoch) || revision != _revision) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      final subscription = server.listen((request) async {
        if (request.uri.path != '/auth/callback') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final valid = request.uri.queryParameters['state'] == state;
        request.response.headers.contentType = ContentType.html;
        request.response.write(valid
            ? '<html><body><h2>Return to Salu</h2><p>You can close this tab.</p></body></html>'
            : '<html><body><h2>Sign-in could not be verified.</h2></body></html>');
        await request.response.close();
        if (valid && !result.isCompleted) result.complete(request.uri);
      });
      final Uri callback;
      try {
        callback = await result.future.timeout(const Duration(minutes: 5));
      } finally {
        await subscription.cancel();
      }
      if (!_fence.isCurrent(epoch) || revision != _revision) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }

      final params = callback.queryParameters;
      if (params.containsKey('error')) {
        throw StateError('Sign-in was cancelled or permission was declined.');
      }
      final issued = params['client_id'] ?? clientId;
      if (issued == null ||
          issued == 'dynamic_agent_client' ||
          (clientId != null && issued != clientId) ||
          params['code'] == null) {
        throw StateError('Sign-in could not be verified.');
      }

      final stopwatch = Stopwatch()..start();
      Duration remaining() {
        final left = _timeout - stopwatch.elapsed;
        return left.isNegative ? Duration.zero : left;
      }

      final tokens = await _postForm(
        _tokenEndpoint,
        {
          'grant_type': 'authorization_code',
          'client_id': issued,
          'code': params['code']!,
          'code_verifier': verifier,
          'redirect_uri': redirect,
          'resource': _resource,
        },
        fence: _fence,
        epoch: epoch,
        deadline: remaining(),
      );
      final idToken = tokens['id_token'];
      final scope = tokens['scope'];
      if (idToken is! String ||
          scope is! String ||
          !scope.split(' ').contains('chatgpt.tokens.use.direct') ||
          tokens['access_token'] is! String ||
          tokens['refresh_token'] is! String ||
          tokens['expires_in'] is! num) {
        throw StateError('ChatGPT plan permission was not granted.');
      }

      final jwksJson = await _transport.send(
        uri: _jwksEndpoint,
        method: 'GET',
        headers: const <String, String>{},
        allowInsecureLocal: false,
        fence: _fence,
        epoch: epoch,
        deadline: remaining(),
      );
      final keys = JsonWebKeyStore()
        ..addKeySet(JsonWebKeySet.fromJson(jwksJson));
      final signed = JsonWebSignature.fromCompactSerialization(idToken);
      final payload =
          await signed.getPayload(keys, allowedAlgorithms: ['RS256']);
      final claims = payload.jsonContent as Map<String, dynamic>;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      validateClaims(claims, issued, nonce, now, old?['subject'] as String?);
      if (!_fence.isCurrent(epoch) || revision != _revision) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      await _writeSession(
        jsonEncode({
          ...tokens,
          'client_id': issued,
          'subject': claims['sub'],
          'email': claims['email'],
          'expires_at': now + (tokens['expires_in'] as num).toInt(),
        }),
      );
    } finally {
      unregisterFence();
      await server.close(force: true);
    }
  }

  /// Validate claims only after the token's signature has been verified.
  static void validateClaims(Map<String, dynamic> claims, String clientId,
      String nonce, int now, String? previousSubject) {
    final audience = claims['aud'];
    if (claims['iss'] != 'https://auth.openai.com' ||
        !(audience == clientId ||
            (audience is List && audience.contains(clientId))) ||
        claims['nonce'] != nonce ||
        claims['sub'] is! String ||
        (claims['sub'] as String).isEmpty ||
        claims['exp'] is! num ||
        (claims['exp'] as num) <= now ||
        claims['iat'] is! num ||
        (claims['iat'] as num) > now + 60 ||
        (previousSubject != null && previousSubject != claims['sub'])) {
      throw StateError('Your ChatGPT identity could not be verified.');
    }
  }

  Future<String> accessToken() async {
    final budget = Zone.current[_budgetZoneKey] as _ChatGptRequestBudget?;
    final fence = budget?.fence ?? _fence;
    final epoch = budget?.epoch ?? fence.capture();
    if (!fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final session = await _read();
    if (!fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    if (session == null || session['refresh_token'] is! String) {
      throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (session['access_token'] is String &&
        session['expires_at'] is num &&
        (session['expires_at'] as num) > now + 60) {
      return session['access_token'] as String;
    }

    final active = _refreshing;
    if (active != null) return active;
    final future = _refresh(
      session,
      fence: fence,
      epoch: epoch,
      deadline: budget?.remaining() ?? _timeout,
    );
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<String> _refresh(
    Map<String, dynamic> session, {
    required OperationFence fence,
    required int epoch,
    required Duration deadline,
  }) async {
    final revision = _revision;
    final Map<String, dynamic> tokens;
    try {
      tokens = await _postForm(
        _tokenEndpoint,
        {
          'grant_type': 'refresh_token',
          'client_id': session['client_id'] as String,
          'refresh_token': session['refresh_token'] as String,
          'resource': _resource,
        },
        fence: fence,
        epoch: epoch,
        deadline: deadline,
      );
    } on SaluAssistantException catch (e) {
      if (e.code == SaluAssistantErrorCode.requestRejected) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.authenticationFailed,
        );
      }
      rethrow;
    }

    if (tokens['access_token'] is! String ||
        tokens['refresh_token'] is! String ||
        tokens['expires_in'] is! num) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.authenticationFailed,
      );
    }
    final next = {
      ...session,
      ...tokens,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          (tokens['expires_in'] as num).toInt(),
    };
    if (!fence.isCurrent(epoch) || revision != _revision) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    await _writeSession(jsonEncode(next));
    return tokens['access_token'] as String;
  }

  Future<String> model(String token) async {
    final budget = Zone.current[_budgetZoneKey] as _ChatGptRequestBudget?;
    final fence = budget?.fence ?? _fence;
    final epoch = budget?.epoch ?? fence.capture();
    if (!fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final cacheEpoch = _fence.capture();
    if (_cachedModel != null &&
        _cachedModelRevision == _revision &&
        _cachedModelEpoch == cacheEpoch) {
      return _cachedModel!;
    }

    final revision = _revision;
    final json = await _transport.send(
      uri: Uri.parse('$_resource/models'),
      method: 'GET',
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
      allowInsecureLocal: false,
      fence: fence,
      epoch: epoch,
      deadline: budget?.remaining() ?? _timeout,
    );

    if (!fence.isCurrent(epoch) || revision != _revision) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final models = json['models'];
    if (models is! List) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.invalidResponse,
      );
    }
    for (final model in models) {
      if (model is Map &&
          model['visibility'] == 'list' &&
          model['slug'] is String) {
        final slug = model['slug'] as String;
        _cachedModel = slug;
        _cachedModelRevision = revision;
        _cachedModelEpoch = cacheEpoch;
        return slug;
      }
    }
    throw const SaluAssistantException(
      SaluAssistantErrorCode.requestRejected,
    );
  }

  Future<void> signOut() async {
    _clearModelCache();
    // A refresh token can rotate while sign-out is starting. Let that write
    // finish so we revoke and clear the latest token, not the stale one.
    final refresh = _refreshing;
    if (refresh != null) {
      try {
        await refresh;
      } on Object {
        // Clear the local session even if renewal failed.
      }
    }
    _revision++;
    _fence.invalidate();
    final revokeEpoch = _fence.capture();
    final session = await _read();
    try {
      if (session != null && session['refresh_token'] is String) {
        await _postForm(
          _revokeEndpoint,
          {
            'token': session['refresh_token'] as String,
            'token_type_hint': 'refresh_token',
            'client_id': session['client_id'] as String,
          },
          allowEmpty: true,
          fence: _fence,
          epoch: revokeEpoch,
          deadline: const Duration(seconds: 20),
        );
      }
    } finally {
      _clearModelCache();
      if (session == null) {
        try {
          await _storage.delete(key: _sessionKey);
        } on Object {
          throw const SaluAssistantException(
            SaluAssistantErrorCode.storageUnavailable,
          );
        }
      } else {
        await _writeSession(
          jsonEncode({
            'client_id': session['client_id'],
            'subject': session['subject'],
            'email': session['email'],
          }),
        );
      }
    }
  }

  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> form, {
    required OperationFence fence,
    required int epoch,
    required Duration deadline,
    bool allowEmpty = false,
  }) =>
      _transport.postForm(
        uri: uri,
        form: form,
        fence: fence,
        epoch: epoch,
        deadline: deadline,
        allowEmptyResponse: allowEmpty,
      );

  static String _random([int length = 32]) =>
      _base64(List<int>.generate(length, (_) => Random.secure().nextInt(256)));
  static String _base64(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}

final class _ChatGptRequestBudget {
  _ChatGptRequestBudget({
    required this.stopwatch,
    required this.totalDeadline,
    required this.fence,
    required this.epoch,
  });

  final Stopwatch stopwatch;
  final Duration totalDeadline;
  final OperationFence fence;
  final int epoch;

  Duration remaining() {
    final left = totalDeadline - stopwatch.elapsed;
    return left.isNegative ? Duration.zero : left;
  }
}
