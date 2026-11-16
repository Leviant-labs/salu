import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:salu/src/inference/chatgpt_auth.dart';

import 'support/chatgpt_http_fixture.dart';

Future<http.Response> _getLoopback(Uri callbackUri) async {
  final client = http.Client();
  try {
    return await client.get(callbackUri);
  } finally {
    client.close();
  }
}

/// Drives one full connect() through the real loopback server.
///
/// [nonceExtractor] receives the minted nonce so the test can sign an ID
/// token matching the attempt's verifier/state.
Future<void> _driveConnect(
  ChatGptAuthController auth,
  FakeLauncher launcher,
  FixtureKeys keys, {
  Map<String, Object?>? claimsOverride,
  String? corruptedState,
  String? callbackClientId,
  String? callbackCode,
}) async {
  final future = auth.connect();
  // Wait until launcher captured the authorize URL.
  var attempts = 0;
  while (launcher.launched.isEmpty && attempts++ < 100) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final authorize = launcher.launched.single;
  final state = authorize.queryParameters['state']!;
  final nonce = authorize.queryParameters['nonce']!;
  final redirect = authorize.queryParameters['redirect_uri']!;
  final claims = claimsOverride ??
      <String, Object?>{
        'iss': ChatGptFixture.issuer,
        'aud': ChatGptFixture.clientId,
        'sub': ChatGptFixture.subject,
        'exp': (DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000),
        'nonce': nonce,
        'email': ChatGptFixture.email,
      };
  final idToken = keys.mintIdToken(claims);
  storeTokenBody(idToken);
  final cbQuery = <String, String>{
    'code': callbackCode ?? 'fixture-code',
    'state': corruptedState ?? state,
    if (callbackClientId != null) 'client_id': callbackClientId,
    if (callbackClientId == null) 'client_id': ChatGptFixture.clientId,
    'scope':
        'chatgpt.tokens.use.direct email offline_access openid profile resource.invoke',
  };
  final cb = Uri.parse(redirect).replace(queryParameters: cbQuery);
  await Future.wait<Object?>([_getLoopback(cb), future]);
}

String _pendingIdToken = '';

void storeTokenBody(String idToken) {
  _pendingIdToken = idToken;
}

http.Response _tokenJson(http.Request req) {
  final body = req.bodyFields;
  if (body['grant_type'] == 'refresh_token') {
    return http.Response(
        json.encode({
          'access_token': 'fixture-access-rotated',
          'refresh_token': 'fixture-refresh-rotated',
          'token_type': 'Bearer',
          'expires_in': 3600,
          'scope':
              'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
        }),
        200,
        headers: {'content-type': 'application/json'});
  }
  return http.Response(
      json.encode({
        'id_token': _pendingIdToken,
        'access_token': 'fixture-access',
        'refresh_token': 'fixture-refresh',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope':
            'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
      }),
      200,
      headers: {'content-type': 'application/json'});
}

ChatGptAuthController _controller(FixtureKeys keys, FakeTokenStore store,
    FakeLauncher launcher,
    {Future<http.Response> Function(http.Request)? tokenHandler}) {
  return ChatGptAuthController(
    store: store,
    client: ChatGptFixture.discoveryClient(keys, tokenHandler: tokenHandler),
    launchUrl: launcher.call,
    randomSource: fixtureRandom,
  );
}


void main() {
  test('resuming during token exchange preserves the received callback', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final exchangeStarted = Completer<void>();
    final exchange = Completer<http.Response>();
    final auth = _controller(keys, store, launcher, tokenHandler: (req) {
      exchangeStarted.complete();
      return exchange.future;
    });
    final future = _driveConnect(auth, launcher, keys);
    await exchangeStarted.future;
    auth.handleAppResumed();
    exchange.complete(_tokenJson(http.Request(
        'POST', Uri.parse('https://example.test'))
      ..headers['content-type'] = 'application/x-www-form-urlencoded'
      ..bodyFields = {'grant_type': 'authorization_code'}));
    await future;
    expect(auth.connectionState.connected, isTrue);
    expect(store.data[ChatGptAuthController.activeKey], isNotNull);
    auth.dispose();
  });

  test('disconnect during code exchange cannot commit a late callback', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final exchangeStarted = Completer<void>();
    final exchange = Completer<http.Response>();
    final auth = _controller(keys, store, launcher, tokenHandler: (req) {
      exchangeStarted.complete();
      return exchange.future;
    });
    final future = _driveConnect(auth, launcher, keys);
    final expectation = expectLater(future, throwsA(isA<ChatGptAuthException>()
        .having((e) => e.code, 'code', 'CANCELLED')));
    await exchangeStarted.future;
    await auth.disconnect();
    exchange.complete(_tokenJson(http.Request('POST', Uri.parse('https://example.test'))
      ..headers['content-type'] = 'application/x-www-form-urlencoded'
      ..bodyFields = {'grant_type': 'authorization_code'}));
    await expectation;
    expect(store.data[ChatGptAuthController.activeKey], isNull);
    expect(store.data.keys.where((k) => k.startsWith('chatgpt:cred:')), isEmpty);
    auth.dispose();
  });

  test('restart invalidates the unrecoverable pending attempt', () async {
    final store = FakeTokenStore();
    store.data[ChatGptAuthController.attemptKey] = '{"state":"old"}';
    final auth = _controller(FixtureKeys.generate(), store, FakeLauncher());
    await auth.initialize();
    expect(store.data[ChatGptAuthController.attemptKey], isNull);
    expect(auth.connectionState.errorCode, 'ATTEMPT_INTERRUPTED');
    auth.dispose();
  });

  test('successful loopback registration persists active account', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    await _driveConnect(auth, launcher, keys);
    expect(auth.connectionState.connected, isTrue);
    expect(auth.connectionState.planUsageGranted, isTrue);
    expect(store.data[ChatGptAuthController.activeKey], isNotNull);
    expect(store.data[ChatGptAuthController.hostIdKey], startsWith('urn:uuid:'));
    expect(await auth.accessToken(), 'fixture-access');
    auth.dispose();
  });

  test('state mismatch rejects before exchange', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    var tokenCalls = 0;
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async {
          tokenCalls++;
          return _tokenJson(req);
        });
    await expectLater(
        _driveConnect(auth, launcher, keys, corruptedState: 'wrong-state'),
        throwsA(isA<ChatGptAuthException>().having(
            (e) => e.code, 'code', 'STATE_MISMATCH')));
    expect(tokenCalls, 0);
    auth.dispose();
  });

  test('nonce mismatch rejects with NONCE_MISMATCH', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    final claims = ChatGptFixture.validClaims('different-nonce');
    await expectLater(
        _driveConnect(auth, launcher, keys, claimsOverride: claims),
        throwsA(isA<ChatGptAuthException>().having(
            (e) => e.code, 'code', 'NONCE_MISMATCH')));
    auth.dispose();
  });

  test('wrong audience rejects with AUDIENCE_MISMATCH', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    // nonce must match attempt; drive extracts it, so pass aud override
    final future = auth.connect();
    var waits = 0;
    while (launcher.launched.isEmpty && waits++ < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final authorize = launcher.launched.single;
    final nonce = authorize.queryParameters['nonce']!;
    final state = authorize.queryParameters['state']!;
    final redirect = authorize.queryParameters['redirect_uri']!;
    storeTokenBody(keys.mintIdToken(
        <String, Object?>{...ChatGptFixture.validClaims(nonce), 'aud': 'other'}));
    final cb = Uri.parse(redirect).replace(queryParameters: {
      'code': 'c',
      'state': state,
      'client_id': ChatGptFixture.clientId,
    });
    await _getLoopback(cb);
    await expectLater(
        future,
        throwsA(isA<ChatGptAuthException>().having(
            (e) => e.code, 'code', 'AUDIENCE_MISMATCH')));
    auth.dispose();
  });

  test('wrong issuer rejects with ISSUER_MISMATCH', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    final future = auth.connect();
    var waits = 0;
    while (launcher.launched.isEmpty && waits++ < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final authorize = launcher.launched.single;
    final nonce = authorize.queryParameters['nonce']!;
    final state = authorize.queryParameters['state']!;
    final redirect = authorize.queryParameters['redirect_uri']!;
    storeTokenBody(keys.mintIdToken(
        <String, Object?>{...ChatGptFixture.validClaims(nonce), 'iss': 'https://evil.example'}));
    final cb = Uri.parse(redirect).replace(queryParameters: {
      'code': 'c',
      'state': state,
      'client_id': ChatGptFixture.clientId,
    });
    await _getLoopback(cb);
    await expectLater(
        future,
        throwsA(isA<ChatGptAuthException>().having(
            (e) => e.code, 'code', 'ISSUER_MISMATCH')));
    auth.dispose();
  });

  test('tampered signature rejects', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    final future = auth.connect();
    var waits = 0;
    while (launcher.launched.isEmpty && waits++ < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final authorize = launcher.launched.single;
    final nonce = authorize.queryParameters['nonce']!;
    final state = authorize.queryParameters['state']!;
    final redirect = authorize.queryParameters['redirect_uri']!;
    final otherKeys = FixtureKeys.generate(keyId: 'other');
    storeTokenBody(otherKeys.mintIdToken(ChatGptFixture.validClaims(nonce)));
    final cb = Uri.parse(redirect).replace(queryParameters: {
      'code': 'c',
      'state': state,
      'client_id': ChatGptFixture.clientId,
    });
    await _getLoopback(cb);
    await expectLater(future, throwsA(isA<ChatGptAuthException>()));
    auth.dispose();
  });

  test('missing issued client id rejects new registration', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    final future = auth.connect();
    var waits = 0;
    while (launcher.launched.isEmpty && waits++ < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final authorize = launcher.launched.single;
    final state = authorize.queryParameters['state']!;
    final redirect = authorize.queryParameters['redirect_uri']!;
    final cb = Uri.parse(redirect).replace(queryParameters: {
      'code': 'c',
      'state': state,
    });
    await _getLoopback(cb);
    await expectLater(
        future,
        throwsA(isA<ChatGptAuthException>().having(
            (e) => e.code, 'code', 'ISSUED_CLIENT_MISSING')));
    auth.dispose();
  });

  test('access denied before code exchange', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    final future = auth.connect();
    var waits = 0;
    while (launcher.launched.isEmpty && waits++ < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final authorize = launcher.launched.single;
    final state = authorize.queryParameters['state']!;
    final redirect = authorize.queryParameters['redirect_uri']!;
    final cb = Uri.parse(redirect).replace(queryParameters: {
      'error': 'access_denied',
      'state': state,
    });
    await _getLoopback(cb);
    await expectLater(
        future,
        throwsA(isA<ChatGptAuthException>().having(
            (e) => e.code, 'code', 'OAUTH_ACCESS_DENIED')));
    auth.dispose();
  });

  test('serialized rotating refresh saves replacement tokens', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    var refreshCalls = 0;
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async {
          if (req.bodyFields['grant_type'] == 'refresh_token') {
            refreshCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          return _tokenJson(req);
        });
    await _driveConnect(auth, launcher, keys);
    // Force expiry by rewriting credential expiry to the past.
    final active = store.data[ChatGptAuthController.activeKey]!;
    final raw = json.decode(store.data['chatgpt:cred:$active']!) as Map<String, Object?>;
    raw['expires_at'] = DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();
    store.data['chatgpt:cred:$active'] = json.encode(raw);
    final results = await Future.wait([auth.accessToken(), auth.accessToken(), auth.accessToken()]);
    expect(results.toSet(), {'fixture-access-rotated'});
    expect(refreshCalls, 1);
    final updated = json.decode(store.data['chatgpt:cred:$active']!) as Map<String, Object?>;
    expect(updated['refresh_token'], 'fixture-refresh-rotated');
    auth.dispose();
  });

  test('unusable refresh clears credentials', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async {
          if (req.bodyFields['grant_type'] == 'refresh_token') {
            return http.Response(
                json.encode({
                  'error': {'code': 'invalid_grant', 'message': 'dead'},
                }),
                400);
          }
          return _tokenJson(req);
        });
    await _driveConnect(auth, launcher, keys);
    final active = store.data[ChatGptAuthController.activeKey]!;
    final raw = json.decode(store.data['chatgpt:cred:$active']!) as Map<String, Object?>;
    raw['expires_at'] = DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();
    store.data['chatgpt:cred:$active'] = json.encode(raw);
    Object? captured;
    try {
      await auth.accessToken();
    } on ChatGptAuthException catch (e) {
      captured = e;
    }
    expect(captured, isA<ChatGptAuthException>().having(
        (e) => e.code, 'code', 'REFRESH_UNUSABLE'));
    final saved = json.decode(store.data['chatgpt:cred:$active']!) as Map;
    expect(saved['access_token'], isEmpty);
    expect(saved['refresh_token'], isEmpty);
    expect(auth.connectionState.connected, isFalse);
    auth.dispose();
  });

  test('disconnect retains registration mapping, clears tokens', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    await _driveConnect(auth, launcher, keys);
    final indexBefore = store.data[ChatGptAuthController.indexKey]!;
    await auth.disconnect();
    expect(store.data[ChatGptAuthController.indexKey], indexBefore);
    expect(store.data[ChatGptAuthController.activeKey], isNull);
    for (final entry in store.data.entries) {
      if (entry.key.startsWith('chatgpt:cred:')) {
        final cred = json.decode(entry.value) as Map;
        expect(cred['access_token'], isEmpty);
        expect(cred['refresh_token'], isEmpty);
      }
    }
    auth.dispose();
  });

  test('clearAllSecrets wipes store and in-memory state', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    await _driveConnect(auth, launcher, keys);
    await auth.clearAllSecrets();
    expect(store.data, isEmpty);
    expect(auth.connectionState.connected, isFalse);
    expect(auth.connectionState.accounts, isEmpty);
    await expectLater(auth.accessToken(), throwsA(isA<ChatGptAuthException>()));
    auth.dispose();
  });

  test('registry isolation: same email different subject stays separate', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcherA = FakeLauncher();
    final authA = _controller(keys, store, launcherA,
        tokenHandler: (req) async => _tokenJson(req));
    await _driveConnect(authA, launcherA, keys);
    final regA = store.data[ChatGptAuthController.activeKey]!;
    authA.dispose();
    // Second subject with same email gets distinct registration key.
    final launcherB = FakeLauncher();
    final authB = _controller(keys, store, launcherB,
        tokenHandler: (req) async => _tokenJson(req));
    // Drive with different subject
    final future = authB.connect();
    var waits = 0;
    while (launcherB.launched.isEmpty && waits++ < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final authorize = launcherB.launched.single;
    final nonce = authorize.queryParameters['nonce']!;
    final state = authorize.queryParameters['state']!;
    final redirect = authorize.queryParameters['redirect_uri']!;
    storeTokenBody(keys.mintIdToken(
        <String, Object?>{...ChatGptFixture.validClaims(nonce), 'sub': 'other-subject'}));
    final cb = Uri.parse(redirect).replace(queryParameters: {
      'code': 'c',
      'state': state,
      'client_id': ChatGptFixture.clientId,
    });
    await _getLoopback(cb);
    await future;
    final regB = store.data[ChatGptAuthController.activeKey]!;
    expect(regA, isNot(regB));
    final index = json.decode(store.data[ChatGptAuthController.indexKey]!) as List;
    expect(index, hasLength(2));
    authB.dispose();
  });

  test('delayed refresh after delete does not resurrect secrets', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async {
          if (req.bodyFields['grant_type'] == 'refresh_token') {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return _tokenJson(req);
        });
    await _driveConnect(auth, launcher, keys);
    final active = store.data[ChatGptAuthController.activeKey]!;
    final raw = json.decode(store.data['chatgpt:cred:$active']!) as Map<String, Object?>;
    raw['expires_at'] = DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();
    store.data['chatgpt:cred:$active'] = json.encode(raw);
    final pending = auth.accessToken();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await auth.clearAllSecrets();
    Object? late;
    try {
      await pending;
    } on ChatGptAuthException catch (e) {
      late = e;
    }
    expect(late, isA<ChatGptAuthException>().having(
        (e) => e.code, 'code', anyOf('CANCELLED', 'NO_ACTIVE_ACCOUNT')));
    expect(store.data, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(store.data, isEmpty);
    auth.dispose();
  });

  test('delayed refresh after disconnect does not resurrect tokens', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async {
          if (req.bodyFields['grant_type'] == 'refresh_token') {
            await Future<void>.delayed(const Duration(milliseconds: 120));
          }
          return _tokenJson(req);
        });
    await _driveConnect(auth, launcher, keys);
    final active = store.data[ChatGptAuthController.activeKey]!;
    final raw = json.decode(store.data['chatgpt:cred:$active']!) as Map<String, Object?>;
    raw['expires_at'] = DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();
    store.data['chatgpt:cred:$active'] = json.encode(raw);
    final pending = auth.accessToken();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await auth.disconnect();
    Object? late;
    try {
      await pending;
    } on ChatGptAuthException catch (e) {
      late = e;
    }
    expect(late, isA<ChatGptAuthException>().having(
        (e) => e.code, 'code', anyOf('CANCELLED', 'NO_ACTIVE_ACCOUNT')));
    final credRaw = store.data['chatgpt:cred:$active'];
    if (credRaw != null) {
      final cred = json.decode(credRaw) as Map;
      expect(cred['access_token'], isEmpty);
      expect(cred['refresh_token'], isEmpty);
    }
    auth.dispose();
  });

  test('initialize restores disconnected state for blank tokens', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final regId = 'reg-blank';
    store.data['chatgpt:cred:$regId'] = json.encode({
      'client_id': ChatGptFixture.clientId,
      'host_id': 'urn:uuid:fixture',
      'subject': ChatGptFixture.subject,
      'issuer': ChatGptFixture.issuer,
      'access_token': '',
      'refresh_token': '',
      'id_token': '',
      'scopes': ['openid', 'chatgpt.tokens.use.direct'],
      'expires_at': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    });
    store.data[ChatGptAuthController.indexKey] = json.encode([regId]);
    store.data[ChatGptAuthController.activeKey] = regId;
    final auth = _controller(keys, store, FakeLauncher());
    await auth.initialize();
    expect(auth.connectionState.connected, isFalse);
    expect(auth.connectionState.accounts.single.registrationId, regId);
    auth.dispose();
  });

  test('initialize restores connected state for usable tokens', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final regId = 'reg-usable';
    store.data['chatgpt:cred:$regId'] = json.encode({
      'client_id': ChatGptFixture.clientId,
      'host_id': 'urn:uuid:fixture',
      'subject': ChatGptFixture.subject,
      'issuer': ChatGptFixture.issuer,
      'email': ChatGptFixture.email,
      'access_token': 'fixture-access',
      'refresh_token': 'fixture-refresh',
      'id_token': keys.mintIdToken(ChatGptFixture.validClaims('n')),
      'scopes': ['openid', 'chatgpt.tokens.use.direct'],
      'expires_at': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    });
    store.data[ChatGptAuthController.indexKey] = json.encode([regId]);
    store.data[ChatGptAuthController.activeKey] = regId;
    final auth = _controller(keys, store, FakeLauncher());
    await auth.initialize();
    expect(auth.connectionState.connected, isTrue);
    expect(auth.connectionState.planUsageGranted, isTrue);
    expect(await auth.accessToken(), 'fixture-access');
    auth.dispose();
  });

  test('selectAccount keeps late callback from earlier attempt', () async {
    final keys = FixtureKeys.generate();
    final store = FakeTokenStore();
    final launcher = FakeLauncher();
    final auth = _controller(keys, store, launcher,
        tokenHandler: (req) async => _tokenJson(req));
    await _driveConnect(auth, launcher, keys);
    final reg = store.data[ChatGptAuthController.activeKey]!;
    final future = auth.selectAccount(reg);
    late ChatGptAuthException error;
    final done = future.then((_) {}).catchError((Object e) {
      error = e as ChatGptAuthException;
    });
    var waits = 0;
    while (waits++ < 100 && launcher.launched.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await auth.cancelPendingAttempt();
    await done;
    expect(error.code, 'CANCELLED');
    expect(store.data[ChatGptAuthController.activeKey], reg);
    expect(await auth.accessToken(), 'fixture-access');
    auth.dispose();
  });
}
