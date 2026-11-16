/// Phone-local ChatGPT subscription sign-in (Sign in with ChatGPT / SIWC).
///
/// Implements the documented open-source token-sharing flow only: dynamic
/// registration with `dynamic_agent_client`, loopback callback on 127.0.0.1,
/// PKCE S256, JWKS-verified ID tokens, rotating refresh tokens, and
/// per-registration secure storage. There is no API-key alternative, no
/// credential WebView, and no codex app-server managed authentication.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Status of the ChatGPT connection from the UI's perspective.
enum ChatGptAuthStatus { disconnected, connecting, connected, needsReconsent, error }

/// Safe diagnostic code; never carries tokens, hints, or URLs.
class ChatGptAuthException implements Exception {
  const ChatGptAuthException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => 'ChatGptAuthException($code${detail == null ? '' : ': $detail'})';
}

/// One saved ChatGPT registration (never carries refresh/id tokens in logs).
final class ChatGptAccount {
  const ChatGptAccount({
    required this.registrationId,
    required this.clientId,
    required this.hostId,
    required this.subject,
    required this.issuer,
    this.email,
    this.displayLabel,
    this.scopes = const <String>{},
    this.accessExpiresAt,
    this.savedAt,
  });
  final String registrationId;
  final String clientId;
  final String hostId;
  final String subject;
  final String issuer;
  final String? email;
  final String? displayLabel;
  final Set<String> scopes;
  final DateTime? accessExpiresAt;
  final DateTime? savedAt;
  bool get planUsageGranted => scopes.contains('chatgpt.tokens.use.direct');
}

/// Snapshot of connection state for UI and gating.
final class ChatGptConnectionState {
  const ChatGptConnectionState({
    required this.status,
    required this.connected,
    required this.planUsageGranted,
    required this.accounts,
    this.activeRegistrationId,
    this.errorCode,
  });
  final ChatGptAuthStatus status;
  final bool connected;
  final bool planUsageGranted;
  final List<ChatGptAccount> accounts;
  final String? activeRegistrationId;
  final String? errorCode;
}

/// Minimal secure-storage seam (injectable for tests/fixtures).
abstract interface class ChatGptTokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> clearAll();
}

/// Production store backed by [FlutterSecureStorage].
final class SecureTokenStore implements ChatGptTokenStore {
  const SecureTokenStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
  @override
  Future<void> clearAll() => _storage.deleteAll();
}

/// Random-value hook: returns 32 random bytes (state/nonce/verifier/host-id).
typedef ChatGptRandomSource = List<int> Function(int byteLength);

/// Browser seam: opens [url] in the system browser (in-app browser view).
typedef ChatGptBrowserLauncher = Future<bool> Function(Uri url);

List<int> _defaultRandom(int n) {
  final r = Random.secure();
  return List<int>.generate(n, (_) => r.nextInt(256));
}

String _b64urlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _pkceChallenge(String verifier) =>
    _b64urlNoPad(sha256.convert(utf8.encode(verifier)).bytes);

/// Length-prefixed SHA-256 hex for `(issuer, sub, issuedClientId)`.
String _registrationKey(String issuer, String subject, String clientId) {
  final parts = <String>[issuer, subject, clientId];
  final buffer = StringBuffer();
  for (final p in parts) {
    buffer.writeln('${utf8.encode(p).length}:$p');
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString().replaceAll('-', '');
}

final class _Credential {
  const _Credential({
    required this.clientId,
    required this.hostId,
    required this.subject,
    required this.issuer,
    this.email,
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.scopes,
    required this.expiresAt,
  });
  final String clientId, hostId, subject, issuer;
  final String? email;
  final String idToken, accessToken, refreshToken;
  final Set<String> scopes;
  final DateTime expiresAt;
  bool get planUsageGranted => scopes.contains('chatgpt.tokens.use.direct');

  Map<String, Object?> toJson() => <String, Object?>{
        'client_id': clientId,
        'host_id': hostId,
        'subject': subject,
        'issuer': issuer,
        'email': email,
        'id_token': idToken,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'scopes': scopes.toList()..sort(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };
  factory _Credential.fromJson(Map<String, Object?> j) => _Credential(
        clientId: j['client_id'] as String,
        hostId: j['host_id'] as String,
        subject: j['subject'] as String,
        issuer: j['issuer'] as String,
        email: j['email'] as String?,
        idToken: j['id_token'] as String,
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        scopes: ((j['scopes'] as List?) ?? [])
            .map((e) => e.toString())
            .toSet(),
        expiresAt: DateTime.parse(j['expires_at'] as String),
      );
}

final class _Attempt {
  const _Attempt({
    required this.state,
    required this.nonce,
    required this.verifier,
    required this.redirectUri,
    required this.issuedClientId,
    required this.registrationId,
    required this.createdAt,
  });
  final String state, nonce, verifier, redirectUri, issuedClientId;
  final String? registrationId;
  final DateTime createdAt;
  DateTime get expiresAt => createdAt.add(const Duration(minutes: 10));
  bool get expired => DateTime.now().isAfter(expiresAt);
  Map<String, Object?> toJson() => <String, Object?>{
        'state': state,
        'nonce': nonce,
        'verifier': verifier,
        'redirectUri': redirectUri,
        'issuedClientId': issuedClientId,
        'registrationId': registrationId,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

class ChatGptAuthController extends ChangeNotifier {
  ChatGptAuthController({
    required ChatGptTokenStore store,
    http.Client? client,
    ChatGptBrowserLauncher? launchUrl,
    ChatGptRandomSource? randomSource,
    Uri? authorizeUri,
    Uri? tokenUri,
    Uri? discoveryUri,
    String agentNameHint = 'Salu',
    Duration refreshSkew = const Duration(seconds: 60),
  })  : _store = store,
        _client = client ?? http.Client(),
        _launchUrl = launchUrl ??
            ((u) => url_launcher.launchUrl(
                u,
                mode: url_launcher.LaunchMode.inAppBrowserView,
                browserConfiguration: const url_launcher.BrowserConfiguration(
                    showTitle: false))),
        _random = randomSource ?? _defaultRandom,
        _authorizeUri =
            authorizeUri ?? Uri.parse('https://auth.openai.com/api/accounts/authorize'),
        _tokenUri = tokenUri ??
            Uri.parse('https://auth.openai.com/api/accounts/oauth/token'),
        _discoveryUri = discoveryUri ??
            Uri.parse('https://auth.openai.com/.well-known/openid-configuration'),
        _agentNameHint = agentNameHint,
        _refreshSkew = refreshSkew;

  final ChatGptTokenStore _store;
  final http.Client _client;
  final ChatGptBrowserLauncher _launchUrl;
  final ChatGptRandomSource _random;
  final Uri _authorizeUri, _tokenUri, _discoveryUri;
  final String _agentNameHint;
  final Duration _refreshSkew;

  static const String hostIdKey = 'chatgpt:host-id';
  static const String indexKey = 'chatgpt:registrations';
  static const String activeKey = 'chatgpt:active';
  static const String attemptKey = 'chatgpt:attempt';
  static String _credKey(String registrationId) => 'chatgpt:cred:$registrationId';
  static const String _resource = 'https://api.openai.com/v1';
  static const List<String> _scopes = [
    'openid',
    'profile',
    'email',
    'offline_access',
    'resource.invoke',
    'chatgpt.tokens.use.direct',
  ];

  HttpServer? _server;
  _Attempt? _attempt;
  Completer<Uri>? _callbackCompleter;
  final Map<String, Future<_Credential>> _refreshLocks = {};
  int _requestGeneration = 0;
  Future<void>? _disconnecting;
  ChatGptConnectionState _state = const ChatGptConnectionState(
    status: ChatGptAuthStatus.disconnected,
    connected: false,
    planUsageGranted: false,
    accounts: [],
  );

  ChatGptConnectionState get connectionState => _state;
  List<ChatGptAccount> get accounts => _state.accounts;
  bool get isConnected => _state.connected;
  bool get planUsageGranted => _state.planUsageGranted;
  String? get activeRegistrationId => _state.activeRegistrationId;

  /// Current request generation; providers check it to drop late results.
  int get requestGeneration => _requestGeneration;
  void _checkGeneration(int generation) {
    if (generation != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
  }


  Uri? get _callbackUri => _server == null
      ? null
      : Uri.parse('http://127.0.0.1:${_server!.port}/auth/callback');

  Future<void> _ensureHostId() async {
    final existing = await _store.read(hostIdKey);
    if (existing != null && existing.isNotEmpty) return;
    final id = 'urn:uuid:${_newUuid()}';
    await _store.write(hostIdKey, id);
  }

  String _newUuid() {
    final bytes = _random(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}';
  }

  String _newToken() => _b64urlNoPad(_random(32));

  Future<Set<String>> _readIndex() async {
    final raw = await _store.read(indexKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
    } catch (_) {}
    return <String>{};
  }


  Future<String?> _hostId() async {
    final v = await _store.read(hostIdKey);
    if (v == null || v.isEmpty) throw const ChatGptAuthException('HOST_ID_MISSING');
    return v;
  }

  Future<_Credential?> _readCredential(String registrationId) async {
    final raw = await _store.read(_credKey(registrationId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return _Credential.fromJson(
          Map<String, Object?>.from(json.decode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCredential(String registrationId, _Credential c, {int? expectedGeneration}) async {
    if (expectedGeneration != null && expectedGeneration != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
    await _store.write(_credKey(registrationId), json.encode(c.toJson()));
    if (expectedGeneration != null && expectedGeneration != _requestGeneration) {
      await _store.delete(_credKey(registrationId));
      throw const ChatGptAuthException('CANCELLED');
    }
  }

  Future<void> _writeIndexGuarded(Set<String> ids, {int? expectedGeneration}) async {
    if (expectedGeneration != null && expectedGeneration != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
    await _store.write(indexKey, json.encode(ids.toList()..sort()));
  }

  Future<void> _refreshState() async {
    final index = await _readIndex();
    final active = await _store.read(activeKey);
    final accounts = <ChatGptAccount>[];
    bool planGranted = false;
    for (final id in index) {
      final cred = await _readCredential(id);
      if (cred == null) continue;
      accounts.add(ChatGptAccount(
        registrationId: id,
        clientId: cred.clientId,
        hostId: cred.hostId,
        subject: cred.subject,
        issuer: cred.issuer,
        email: cred.email,
        displayLabel: cred.email ?? id.substring(0, 8),
        scopes: cred.scopes,
        accessExpiresAt: cred.expiresAt,
      ));
      if (id == active) planGranted = cred.planUsageGranted;
    }
    final activeCred = active == null ? null : await _readCredential(active);
    final usableActive = active != null &&
        activeCred != null &&
        activeCred.accessToken.isNotEmpty &&
        activeCred.refreshToken.isNotEmpty;
    _state = ChatGptConnectionState(
      status: usableActive
          ? (planGranted
              ? ChatGptAuthStatus.connected
              : ChatGptAuthStatus.needsReconsent)
          : ChatGptAuthStatus.disconnected,
      connected: usableActive,
      planUsageGranted: usableActive && planGranted,
      accounts: accounts,
      activeRegistrationId: usableActive ? active : null,
    );
    notifyListeners();
  }

  /// A process restart cannot recover the old loopback listener.
  Future<void> initialize() async {
    final interrupted = await _store.read(attemptKey) != null;
    if (interrupted) await _store.delete(attemptKey);
    await _ensureHostId();
    await _refreshState();
    if (interrupted) {
      _state = ChatGptConnectionState(
        status: ChatGptAuthStatus.needsReconsent,
        connected: _state.connected,
        planUsageGranted: _state.planUsageGranted,
        accounts: _state.accounts,
        activeRegistrationId: _state.activeRegistrationId,
        errorCode: 'ATTEMPT_INTERRUPTED',
      );
      notifyListeners();
    }
  }

  /// Starts a fresh OAuth attempt (new registration or re-auth of [registrationId]).
  Future<void> connect({String? registrationId}) async {
    final disconnecting = _disconnecting;
    if (disconnecting != null) await disconnecting;
    _invalidatePending();
    final generation = _requestGeneration;
    await _ensureHostId();
    final hostId = await _hostId();
    final priorCred =
        registrationId == null ? null : await _readCredential(registrationId);
    _checkGeneration(generation);
    if (registrationId != null && priorCred == null) {
      throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    }
    await _closeServer();
    _checkGeneration(generation);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (generation != _requestGeneration) {
      await server.close(force: true);
      throw const ChatGptAuthException('CANCELLED');
    }
    _server = server;
    final redirectUri = _callbackUri!.toString();
    final state = _newToken();
    final nonce = _newToken();
    final verifier = _newToken();
    _attempt = _Attempt(
      state: state,
      nonce: nonce,
      verifier: verifier,
      redirectUri: redirectUri,
      issuedClientId: priorCred?.clientId ?? 'dynamic_agent_client',
      registrationId: registrationId,
      createdAt: DateTime.now(),
    );
    await _store.write(attemptKey, json.encode(_attempt!.toJson()));
    _checkGeneration(generation);
    _callbackCompleter = Completer<Uri>();
    _callbackCompleter!.future.ignore();
    final callback = _callbackCompleter!.future;
    final clientId = priorCred?.clientId ?? 'dynamic_agent_client';
    final params = <String, String>{
      'client_id': clientId,
      'ext_agent_host_id': hostId!,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': _scopes.join(' '),
      'resource': _resource,
      'state': state,
      'nonce': nonce,
      'code_challenge_method': 'S256',
      'code_challenge': _pkceChallenge(verifier),
    };
    if (priorCred == null) {
      params['agent_name_hint'] = _agentNameHint;
    } else {
      if (priorCred.idToken.isNotEmpty) params['id_token_hint'] = priorCred.idToken;
      if (priorCred.email != null && priorCred.email!.isNotEmpty) {
        params['login_hint'] = priorCred.email!;
      }
    }
    _state = ChatGptConnectionState(
      status: ChatGptAuthStatus.connecting,
      connected: _state.connected,
      planUsageGranted: _state.planUsageGranted,
      accounts: _state.accounts,
      activeRegistrationId: _state.activeRegistrationId,
    );
    notifyListeners();
    _listenForCallback();
    try {
      final ok = await _launchUrl(_authorizeUri.replace(queryParameters: params));
      _checkGeneration(generation);
      if (!ok) throw const ChatGptAuthException('BROWSER_LAUNCH_FAILED');
    } catch (e) {
      _checkGeneration(generation);
      await _closeServer();
      await _clearAttempt();
      if (e is ChatGptAuthException) rethrow;
      throw ChatGptAuthException('BROWSER_LAUNCH_FAILED', e.toString());
    }
    try {
      final cb = await callback
          .timeout(const Duration(minutes: 10), onTimeout: () {
        throw const ChatGptAuthException('ATTEMPT_EXPIRED');
      });
      _checkGeneration(generation);
      await _handleCallback(cb, generation);
    } finally {
      if (generation == _requestGeneration) {
        await _closeServer();
        await _clearAttempt();
        _attempt = null;
        await _refreshState();
      }
    }
  }

  /// A received callback may still be exchanging or validating tokens after
  /// the listener has closed; resuming then must not discard that attempt.
  void handleAppResumed() {
    final attempt = _attempt;
    if (attempt == null) return;
    final callback = _callbackCompleter;
    if (callback != null && callback.isCompleted) return;
    if (!attempt.expired && _server != null) return;

    _requestGeneration++;
    if (callback != null && !callback.isCompleted) {
      callback.completeError(const ChatGptAuthException('ATTEMPT_EXPIRED'));
    }
    unawaited(_closeServer());
    unawaited(_clearAttempt());
    _attempt = null;
    _state = ChatGptConnectionState(
      status: ChatGptAuthStatus.needsReconsent,
      connected: _state.connected,
      planUsageGranted: _state.planUsageGranted,
      accounts: _state.accounts,
      activeRegistrationId: _state.activeRegistrationId,
      errorCode: 'ATTEMPT_EXPIRED',
    );
    notifyListeners();
  }

  void _listenForCallback() {
    _server!.listen((request) async {
      final completer = _callbackCompleter;
      if (request.uri.path != '/auth/callback' || completer == null || completer.isCompleted) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('content-type', 'text/plain; charset=utf-8');
      request.response.write('Salu sign-in received. You can return to the app.');
      await request.response.close();
      if (!completer.isCompleted) completer.complete(request.uri);
    });
  }

  Future<void> _handleCallback(Uri cb, int generation) async {
    final attempt = _attempt;
    if (attempt == null) throw const ChatGptAuthException('ATTEMPT_EXPIRED');
    if (attempt.expired) {
      await _closeServer();
      await _clearAttempt();
      throw const ChatGptAuthException('ATTEMPT_EXPIRED');
    }
    final qs = cb.queryParameters;
    final returnedState = qs['state'];
    if (returnedState != attempt.state) {
      await _closeServer();
      await _clearAttempt();
      throw const ChatGptAuthException('STATE_MISMATCH');
    }
    final error = qs['error'];
    if (error != null && error.isNotEmpty) {
      await _closeServer();
      await _clearAttempt();
      if (error == 'access_denied') {
        throw const ChatGptAuthException('OAUTH_ACCESS_DENIED');
      }
      throw ChatGptAuthException('OAUTH_ERROR', error);
    }
    final code = qs['code'];
    if (code == null || code.isEmpty) {
      await _closeServer();
      await _clearAttempt();
      throw const ChatGptAuthException('OAUTH_ERROR', 'missing_code');
    }
    final returnedClient = qs['client_id'];
    final issued =
        attempt.issuedClientId == 'dynamic_agent_client'
            ? returnedClient
            : attempt.issuedClientId;
    if (attempt.issuedClientId == 'dynamic_agent_client') {
      if (returnedClient == null || returnedClient.isEmpty) {
        await _closeServer();
        await _clearAttempt();
        throw const ChatGptAuthException('ISSUED_CLIENT_MISSING');
      }
    } else if (returnedClient != null &&
        returnedClient.isNotEmpty &&
        returnedClient != attempt.issuedClientId) {
      await _closeServer();
      await _clearAttempt();
      throw const ChatGptAuthException('CLIENT_ID_MISMATCH');
    }
    await _closeServer();
    final token = await _exchangeCode(
      code: code,
      clientId: issued!,
      verifier: attempt.verifier,
      redirectUri: attempt.redirectUri,
    );
    _checkGeneration(generation);
    final validated = await _validateIdToken(
      idToken: token.idToken,
      expectedAudience: issued,
      expectedNonce: attempt.nonce,
    );
    _checkGeneration(generation);
    if (attempt.registrationId != null) {
      final prior = await _readCredential(attempt.registrationId!);
      if (prior != null && prior.subject != validated.subject) {
        throw const ChatGptAuthException('ACCOUNT_MISMATCH');
      }
    }
    final hostId = await _hostId();
    final registrationId = _registrationKey(
        validated.issuer, validated.subject, issued);
    final scopes = token.scopes;
    final cred = _Credential(
      clientId: issued,
      hostId: hostId!,
      subject: validated.subject,
      issuer: validated.issuer,
      email: validated.email,
      idToken: token.idToken,
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      scopes: scopes,
      expiresAt: DateTime.now().add(Duration(seconds: token.expiresIn)),
    );
    _checkGeneration(generation);
    if (!identical(_attempt, attempt)) {
      throw const ChatGptAuthException('CANCELLED');
    }
    await _saveCredential(registrationId, cred, expectedGeneration: generation);
    final index = await _readIndex();
    index.add(registrationId);
    await _writeIndexGuarded(index, expectedGeneration: generation);
    _checkGeneration(generation);
    await _store.write(activeKey, registrationId);
    _checkGeneration(generation);
    await _clearAttempt();
    if (_attempt == attempt) _attempt = null;
    await _refreshState();
  }

  /// Re-authorizes [registrationId] and makes it active only after validation.
  Future<void> selectAccount(String registrationId) async {
    final cred = await _readCredential(registrationId);
    if (cred == null) throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    await connect(registrationId: registrationId);
  }

  /// Returns a valid access token, refreshing (serialized) when near expiry.
  Future<String> accessToken() async {
    final gen = _requestGeneration;
    final active = await _store.read(activeKey);
    if (active == null || active.isEmpty) {
      throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    }
    final cred = await _readCredential(active);
    _checkGeneration(gen);
    if (cred == null) throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    if (cred.accessToken.isEmpty) {
      throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    }
    if (!cred.planUsageGranted) {
      throw const ChatGptAuthException('PROVIDER_SCOPE_REQUIRED');
    }
    if (cred.expiresAt.isAfter(DateTime.now().add(_refreshSkew))) {
      return cred.accessToken;
    }
    final token = await _refreshSerialized(active, expectedGeneration: gen);
    _checkGeneration(gen);
    final refreshed = await _readCredential(active);
    _checkGeneration(gen);
    if (refreshed == null || !refreshed.planUsageGranted) {
      throw const ChatGptAuthException('PROVIDER_SCOPE_REQUIRED');
    }
    return token;
  }

  Future<String> _refreshSerialized(String registrationId,
      {required int expectedGeneration}) {
    final existing = _refreshLocks[registrationId];
    if (existing != null) return existing.then((c) => c.accessToken);
    final future = _doRefresh(registrationId,
        expectedGeneration: expectedGeneration);
    _refreshLocks[registrationId] = future;
    // Cleanup without creating an unhandled error future.
    future.then((_) {
      _refreshLocks.remove(registrationId);
    }, onError: (_) {
      _refreshLocks.remove(registrationId);
    });
    return future.then((c) => c.accessToken);
  }

  Future<_Credential> _doRefresh(String registrationId,
      {required int expectedGeneration}) async {
    if (expectedGeneration != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
    final cred = await _readCredential(registrationId);
    if (cred == null) throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    if (cred.refreshToken.isEmpty) {
      throw const ChatGptAuthException('NO_ACTIVE_ACCOUNT');
    }
    final resp = await _client.post(
      _tokenUri,
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': cred.clientId,
        'refresh_token': cred.refreshToken,
        'resource': _resource,
      },
    );
    if (expectedGeneration != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
    if (resp.statusCode == 400) {
      final code = _errorCode(resp.body);
      const unusable = {
        'invalid_grant',
        'invalid_refresh_token',
        'token_expired',
        'refresh_token_expired',
        'refresh_token_invalidated',
        'refresh_token_reused',
      };
      if (code != null && unusable.contains(code)) {
        await _saveCredential(registrationId, _Credential(
          clientId: cred.clientId, hostId: cred.hostId,
          subject: cred.subject, issuer: cred.issuer, email: cred.email,
          idToken: '', accessToken: '', refreshToken: '',
          scopes: const {}, expiresAt: cred.expiresAt,
        ), expectedGeneration: expectedGeneration);
        await _refreshState();
        throw const ChatGptAuthException('REFRESH_UNUSABLE');
      }
      throw ChatGptAuthException('REFRESH_FAILED', code ?? 'http_${resp.statusCode}');
    }
    if (resp.statusCode != 200) {
      throw const ChatGptAuthException('REFRESH_FAILED');
    }
    final jsonBody = json.decode(resp.body) as Map<String, Object?>;
    final newRefresh = jsonBody['refresh_token'] as String?;
    final newAccess = jsonBody['access_token'] as String?;
    final expiresIn = (jsonBody['expires_in'] as num?)?.toInt() ?? 3600;
    if (newAccess == null || newAccess.isEmpty) {
      throw const ChatGptAuthException('REFRESH_FAILED');
    }
    if (expectedGeneration != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
    final scopeRaw = jsonBody['scope'] as String?;
    final updated = _Credential(
      clientId: cred.clientId,
      hostId: cred.hostId,
      subject: cred.subject,
      issuer: cred.issuer,
      email: cred.email,
      idToken: (jsonBody['id_token'] as String?) ?? cred.idToken,
      accessToken: newAccess,
      refreshToken: (newRefresh != null && newRefresh.isNotEmpty)
          ? newRefresh
          : cred.refreshToken,
      scopes: scopeRaw == null
          ? cred.scopes
          : scopeRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toSet(),
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
    await _saveCredential(registrationId, updated,
        expectedGeneration: expectedGeneration);
    if (expectedGeneration != _requestGeneration) {
      throw const ChatGptAuthException('CANCELLED');
    }
    await _refreshState();
    return updated;
  }

  String? _errorCode(String body) {
    try {
      final decoded = json.decode(body);
      if (decoded is Map) {
        final e = decoded['error'];
        if (e is Map && e['code'] is String) return e['code'] as String;
        if (decoded['error'] is String) return decoded['error'] as String;
      }
    } catch (_) {}
    return null;
  }

  Future<_TokenResponse> _exchangeCode({
    required String code,
    required String clientId,
    required String verifier,
    required String redirectUri,
  }) async {
    final resp = await _client.post(
      _tokenUri,
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirectUri,
        'resource': _resource,
      },
    );
    if (resp.statusCode == 400) {
      throw const ChatGptAuthException('TOKEN_EXCHANGE_FAILED');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ChatGptAuthException('TOKEN_EXCHANGE_FAILED', 'http_${resp.statusCode}');
    }
    final j = json.decode(resp.body) as Map<String, Object?>;
    final idToken = j['id_token'] as String?;
    final access = j['access_token'] as String?;
    final refresh = j['refresh_token'] as String?;
    if (idToken == null || access == null || refresh == null) {
      throw const ChatGptAuthException('TOKEN_EXCHANGE_FAILED');
    }
    final scopeRaw = j['scope'] as String?;
    return _TokenResponse(
      idToken: idToken,
      accessToken: access,
      refreshToken: refresh,
      expiresIn: (j['expires_in'] as num?)?.toInt() ?? 3600,
      scopes: scopeRaw == null
          ? <String>{}
          : scopeRaw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toSet(),
    );
  }

  Future<_ValidatedIdentity> _validateIdToken({
    required String idToken,
    required String expectedAudience,
    required String expectedNonce,
  }) async {
    final discoveryResp = await _client.get(_discoveryUri);
    if (discoveryResp.statusCode != 200) {
      throw const ChatGptAuthException('DISCOVERY_MISSING');
    }
    final disc = json.decode(discoveryResp.body) as Map<String, Object?>;
    final issuer = disc['issuer'] as String?;
    final jwksUri = disc['jwks_uri'] as String?;
    final revocation = disc['revocation_endpoint'] as String?;
    final jwksAddress = jwksUri == null ? null : Uri.tryParse(jwksUri);
    if (issuer != 'https://auth.openai.com' || jwksAddress?.scheme != 'https') {
      throw const ChatGptAuthException('DISCOVERY_MISSING');
    }
    final jws = JsonWebSignature.fromCompactSerialization(idToken);
    final header = jws.unverifiedPayload.protectedHeader;
    if (header == null) throw const ChatGptAuthException('SIGNATURE_INVALID');
    final alg = header['alg']?.toString();
    if (alg != 'RS256') throw const ChatGptAuthException('SIGNATURE_INVALID');
    final kid = header['kid']?.toString();
    final jwksResp = await _client.get(jwksAddress!);
    if (jwksResp.statusCode != 200) {
      throw const ChatGptAuthException('SIGNATURE_INVALID');
    }
    final jwksJson = json.decode(jwksResp.body) as Map<String, dynamic>;
    final keySet = JsonWebKeySet.fromJson(jwksJson);
    JsonWebKey? matched;
    for (final k in keySet.keys) {
      if (k.keyId == null || (kid != null && k.keyId == kid)) {
        matched = k;
        break;
      }
    }
    if (kid == null && matched == null && keySet.keys.length == 1) {
      matched = keySet.keys.first;
    }
    if (matched == null) throw const ChatGptAuthException('SIGNATURE_INVALID');
    if (revocation != null) _revocationEndpoint = revocation;
    final store = JsonWebKeyStore()..addKey(matched);
    final JsonWebToken verified;
    try {
      verified = await JsonWebToken.decodeAndVerify(idToken, store,
          allowedArguments: const ['RS256']);
    } catch (_) {
      throw const ChatGptAuthException('SIGNATURE_INVALID');
    }
    if (verified.isVerified != true) {
      throw const ChatGptAuthException('SIGNATURE_INVALID');
    }
    final claims = verified.claims.toJson();
    final iss = claims['iss']?.toString();
    if (iss != 'https://auth.openai.com') {
      throw const ChatGptAuthException('ISSUER_MISMATCH');
    }
    final aud = claims['aud'];
    final audList = aud is List ? aud.map((e) => e.toString()).toList() : [aud?.toString()];
    if (!audList.contains(expectedAudience)) {
      throw const ChatGptAuthException('AUDIENCE_MISMATCH');
    }
    final expRaw = claims['exp'];
    if (expRaw is! num ||
        DateTime.fromMillisecondsSinceEpoch(expRaw.toInt() * 1000)
            .isBefore(DateTime.now().subtract(const Duration(seconds: 30)))) {
      throw const ChatGptAuthException('TOKEN_EXPIRED');
    }
    if (claims['nonce']?.toString() != expectedNonce) {
      throw const ChatGptAuthException('NONCE_MISMATCH');
    }
    final sub = claims['sub']?.toString();
    if (sub == null || sub.isEmpty) {
      throw const ChatGptAuthException('SIGNATURE_INVALID');
    }
    return _ValidatedIdentity(
      subject: sub,
      issuer: 'https://auth.openai.com',
      email: claims['email']?.toString(),
    );
  }

  String? _revocationEndpoint;

  Future<void> disconnect() {
    final existing = _disconnecting;
    if (existing != null) return existing;
    final future = _disconnect();
    _disconnecting = future;
    future.whenComplete(() {
      if (identical(_disconnecting, future)) _disconnecting = null;
    }).ignore();
    return future;
  }

  Future<void> _disconnect() async {
    _invalidatePending();
    await _closeServer();
    _attempt = null;
    await _clearAttempt();
    final active = await _store.read(activeKey);
    if (active != null && active.isNotEmpty) {
      final cred = await _readCredential(active);
      if (cred != null && cred.refreshToken.isNotEmpty) {
        _revocationUnconfirmed = !(await _attemptRevocation(cred));
      }
      // Generation may have advanced during the revocation await; still
      // clear the active index and blank tokens so nothing usable remains.
      final raw = await _store.read(_credKey(active));
      if (raw != null) {
        try {
          final j = Map<String, Object?>.from(json.decode(raw) as Map);
          j['access_token'] = '';
          j['refresh_token'] = '';
          j['id_token'] = '';
          await _store.write(_credKey(active), json.encode(j));
        } catch (_) {}
      }
    }
    await _store.delete(activeKey);
    await _refreshState();
  }

  /// Returns true only on a confirmed HTTPS 200 revocation.
  Future<bool> _attemptRevocation(_Credential cred) async {
    try {
      final discResp = await _client.get(_discoveryUri);
      if (discResp.statusCode != 200) return false;
      final disc = json.decode(discResp.body) as Map<String, Object?>;
      final revRaw = disc['revocation_endpoint'] as String?;
      if (revRaw == null) return false;
      final revUri = Uri.tryParse(revRaw);
      if (revUri == null || revUri.scheme != 'https') return false;
      final resp = await _client.post(
        revUri,
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'token': cred.refreshToken,
          'token_type_hint': 'refresh_token',
          'client_id': cred.clientId,
        },
      ).timeout(const Duration(seconds: 10));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  bool _revocationUnconfirmed = false;
  bool get revocationUnconfirmed => _revocationUnconfirmed;

  void _invalidatePending() {
    _requestGeneration++;
    if (_callbackCompleter != null && !_callbackCompleter!.isCompleted) {
      _callbackCompleter!.completeError(
          const ChatGptAuthException('CANCELLED'));
    }
  }

  /// Cancels a pending OAuth attempt without touching the active account.
  Future<void> cancelPendingAttempt() async {
    _invalidatePending();
    await _closeServer();
    await _clearAttempt();
    _attempt = null;
  }

  /// Called on local-data deletion / restore lifecycle.
  Future<void> clearAllSecrets() async {
    _invalidatePending();
    await _closeServer();
    _attempt = null;
    // Best-effort revocation of the active refresh token BEFORE wiping.
    try {
      final active = await _store.read(activeKey);
      if (active != null && active.isNotEmpty) {
        final cred = await _readCredential(active);
        if (cred != null && cred.refreshToken.isNotEmpty) {
          _revocationUnconfirmed = !(await _attemptRevocation(cred));
        }
      }
    } catch (_) {}
    _refreshLocks.clear();
    await _store.clearAll();
    _state = const ChatGptConnectionState(
      status: ChatGptAuthStatus.disconnected,
      connected: false,
      planUsageGranted: false,
      accounts: [],
    );
    notifyListeners();
  }

  Future<void> _closeServer() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _clearAttempt() async {
    await _store.delete(attemptKey);
  }

  /// Exposes the stored discovery revocation endpoint when known (diagnostics).
  Uri? get revocationEndpoint =>
      _revocationEndpoint == null ? null : Uri.tryParse(_revocationEndpoint!);

  @override
  void dispose() {
    unawaited(_closeServer());
    _client.close();
    super.dispose();
  }
}

final class _TokenResponse {
  const _TokenResponse({
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.scopes,
  });
  final String idToken, accessToken, refreshToken;
  final int expiresIn;
  final Set<String> scopes;
}

final class _ValidatedIdentity {
  const _ValidatedIdentity({
    required this.subject,
    required this.issuer,
    this.email,
  });
  final String subject, issuer;
  final String? email;
}
