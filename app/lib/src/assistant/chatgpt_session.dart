import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jose/jose.dart';
import 'package:url_launcher/url_launcher.dart';

/// Sign in with ChatGPT's public-client, dynamic-registration flow.
class ChatGptSession {
  static const _storage = FlutterSecureStorage();
  static const _sessionKey = 'salu.chatgpt.session.v1';
  static const _hostKey = 'salu.chatgpt.host.v1';
  static const _resource = 'https://api.openai.com/v1';
  static final _tokenEndpoint =
      Uri.parse('https://auth.openai.com/api/accounts/oauth/token');
  Future<String>? _refreshing;
  int _revision = 0;

  Future<Map<String, dynamic>?> _read() async {
    final value = await _storage.read(key: _sessionKey);
    if (value == null) return null;
    return jsonDecode(value) as Map<String, dynamic>;
  }

  Future<bool> get isConnected async =>
      (await _read())?['refresh_token'] is String;

  Future<void> signIn() async {
    final revision = ++_revision;
    final old = await _read();
    var host = await _storage.read(key: _hostKey);
    if (host == null) {
      final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      host =
          'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      await _storage.write(key: _hostKey, value: host);
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open your browser.');
      }
      final result = Completer<Uri>();
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
      Uri callback;
      try {
        callback = await result.future.timeout(const Duration(minutes: 5));
      } finally {
        await subscription.cancel();
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
      final tokens = await _postForm(_tokenEndpoint, {
        'grant_type': 'authorization_code',
        'client_id': issued,
        'code': params['code']!,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'resource': _resource,
      });
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
      final keys = JsonWebKeyStore()
        ..addKeySetUrl(
            Uri.parse('https://auth.openai.com/.well-known/jwks.json'));
      final signed = JsonWebSignature.fromCompactSerialization(idToken);
      final payload =
          await signed.getPayload(keys, allowedAlgorithms: ['RS256']);
      final claims = payload.jsonContent as Map<String, dynamic>;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      validateClaims(claims, issued, nonce, now, old?['subject'] as String?);
      if (revision != _revision) throw StateError('The connection changed.');
      await _storage.write(
          key: _sessionKey,
          value: jsonEncode({
            ...tokens,
            'client_id': issued,
            'subject': claims['sub'],
            'email': claims['email'],
            'expires_at': now + (tokens['expires_in'] as num).toInt(),
          }));
    } finally {
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
    final session = await _read();
    if (session == null || session['refresh_token'] is! String) {
      throw StateError('Continue with ChatGPT in Settings first.');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (session['access_token'] is String &&
        session['expires_at'] is num &&
        (session['expires_at'] as num) > now + 60) {
      return session['access_token'] as String;
    }
    final active = _refreshing;
    if (active != null) return active;
    final future = _refresh(session);
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<String> _refresh(Map<String, dynamic> session) async {
    final revision = _revision;
    final tokens = await _postForm(_tokenEndpoint, {
      'grant_type': 'refresh_token',
      'client_id': session['client_id'] as String,
      'refresh_token': session['refresh_token'] as String,
      'resource': _resource,
    });
    if (tokens['access_token'] is! String ||
        tokens['refresh_token'] is! String ||
        tokens['expires_in'] is! num) {
      throw StateError('Could not renew your ChatGPT session.');
    }
    final next = {
      ...session,
      ...tokens,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          (tokens['expires_in'] as num).toInt()
    };
    if (revision != _revision) throw StateError('The connection changed.');
    await _storage.write(key: _sessionKey, value: jsonEncode(next));
    return tokens['access_token'] as String;
  }

  Future<String> model(String token) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$_resource/models'));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('Could not load your ChatGPT models.');
      }
      final json = jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>;
      final models = json['models'] as List;
      for (final model in models) {
        if (model is Map &&
            model['visibility'] == 'list' &&
            model['slug'] is String) {
          return model['slug'] as String;
        }
      }
      throw StateError('No ChatGPT model is available for this account.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> signOut() async {
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
    final session = await _read();
    try {
      if (session != null && session['refresh_token'] is String) {
        await _postForm(
            Uri.parse('https://auth.openai.com/api/accounts/oauth/revoke'),
            {
              'token': session['refresh_token'] as String,
              'token_type_hint': 'refresh_token',
              'client_id': session['client_id'] as String,
            },
            allowEmpty: true);
      }
    } finally {
      if (session == null) {
        await _storage.delete(key: _sessionKey);
      } else {
        await _storage.write(
            key: _sessionKey,
            value: jsonEncode({
              'client_id': session['client_id'],
              'subject': session['subject'],
              'email': session['email'],
            }));
      }
    }
  }

  static Future<Map<String, dynamic>> _postForm(
      Uri uri, Map<String, String> form,
      {bool allowEmpty = false}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(uri);
      request.followRedirects = false;
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(form.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('ChatGPT could not complete the request.');
      }
      if (allowEmpty && body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static String _random([int length = 32]) =>
      _base64(List<int>.generate(length, (_) => Random.secure().nextInt(256)));
  static String _base64(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}
