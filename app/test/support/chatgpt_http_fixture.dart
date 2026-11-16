/// Deterministic fixtures for ChatGPT auth/transport tests.
///
/// Uses `package:http/testing.dart` MockClient for discovery/JWKS/OAuth/
/// models/Responses/SSE and a deterministic in-memory token store. RSA
/// signing uses fixed test key material generated in-memory (never copied
/// live credentials). The loopback HttpServer in the controller is exercised
/// via real localhost HTTP in `chatgpt_auth_test.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';

import 'package:salu/src/inference/chatgpt_auth.dart';
import 'package:salu/src/inference/provider_connection.dart';

/// In-memory [ChatGptTokenStore].
final class FakeTokenStore implements ChatGptTokenStore {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<void> clearAll() async => data.clear();
}

/// Deterministic "random" bytes for state/nonce/verifier/host-id.
List<int> fixtureRandom(int n) {
  final seed = List<int>.generate(n, (i) => (i * 31 + 7) & 0xff);
  return seed;
}

/// Self-signed fixture RSA keypair + JWKS + token minter (RS256).
final class FixtureKeys {
  FixtureKeys._(this.jwk, this.jwksJson, this.keyId);
  final JsonWebKey jwk;
  final Map<String, Object?> jwksJson;
  final String keyId;

  factory FixtureKeys.generate({String keyId = 'fixture-key-1'}) {
    final jwk = JsonWebKey.generate('RS256', keyBitLength: 2048);
    final publicKey = JsonWebKey.fromCryptoKeys(
      publicKey: jwk.cryptoKeyPair.publicKey,
      keyId: keyId,
    );
    final map = Map<String, Object?>.from(publicKey.toJson());
    map['kid'] = keyId;
    map['use'] = 'sig';
    map['alg'] = 'RS256';
    return FixtureKeys._(
      jwk,
      <String, Object?>{
        'keys': [map],
      },
      keyId,
    );
  }

  /// Mints an RS256 ID token with the given claims.
  String mintIdToken(Map<String, Object?> claims) {
    final builder = JsonWebSignatureBuilder();
    builder.jsonContent = claims;
    builder.setProtectedHeader('alg', 'RS256');
    builder.setProtectedHeader('kid', keyId);
    builder.setProtectedHeader('typ', 'JWT');
    builder.addRecipient(jwk, algorithm: 'RS256');
    return builder.build().toCompactSerialization();
  }
}

/// Valid-looking fixture object graph for auth tests.
final class ChatGptFixture {
  ChatGptFixture({
    required this.keys,
    required this.client,
    required this.store,
    required this.launch,
  });
  final FixtureKeys keys;
  final MockClient client;
  final FakeTokenStore store;
  final FakeLauncher launch;

  static const String issuer = 'https://auth.openai.com';
  static const String clientId = 'oaiapp_fixture_client';
  static const String subject = 'fixture-subject-1';
  static const String email = 'fixture@example.com';

  static Map<String, Object?> validClaims(String nonce,
          {String? aud = clientId, String? sub = subject, int? exp}) =>
      <String, Object?>{
        'iss': issuer,
        'aud': aud,
        'sub': sub,
        'exp': exp ?? (DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000),
        'nonce': nonce,
        'email': email,
      };

  static http.Response _json(Map<String, Object?> body, [int status = 200]) =>
      http.Response(json.encode(body), status,
          headers: {'content-type': 'application/json'});

  /// Builds a MockClient serving discovery/JWKS/token.
  static MockClient discoveryClient(FixtureKeys keys,
      {Uri? discovery, Map<String, Object?>? discoveryBody,
      Map<String, Object?>? jwksBody,
      Future<http.Response> Function(http.Request)? tokenHandler}) {
    final disc = discoveryBody ??
        <String, Object?>{
          'issuer': issuer,
          'jwks_uri': 'https://auth.openai.com/.well-known/jwks.json',
          'revocation_endpoint':
              'https://auth.openai.com/api/accounts/oauth/revoke',
          'authorization_endpoint':
              'https://auth.openai.com/api/accounts/authorize',
          'token_endpoint': 'https://auth.openai.com/api/accounts/oauth/token',
        };
    return MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('openid-configuration')) {
        return _json(disc);
      }
      if (path.endsWith('jwks.json')) {
        return _json(jwksBody ?? keys.jwksJson);
      }
      if (path.endsWith('/oauth/token')) {
        if (tokenHandler != null) return tokenHandler(request);
        final body = request.bodyFields;
        if (body['grant_type'] == 'refresh_token') {
          return _json(<String, Object?>{
            'access_token': 'fixture-access-rotated',
            'refresh_token': 'fixture-refresh-rotated',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'scope': 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
          });
        }
        return _json(<String, Object?>{
          'error': {'code': 'invalid_grant', 'message': 'fixture'},
        }, 400);
      }
      if (path.endsWith('/oauth/revoke')) {
        return http.Response('', 200);
      }
      return http.Response('not found', 404);
    });
  }

  /// Builds a MockClient for Models + Responses SSE.
  static MockClient modelsClient(
      {required List<ChatGptModel> models,
      required List<String> sseEvents}) {
    return MockClient.streaming((request, _) async {
      final path = request.url.path;
      if (path.endsWith('/cancel')) {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (path.endsWith('/models')) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(json.encode({
            'models': [
              for (final m in models)
                {'slug': m.slug, 'display_name': m.displayName, 'visibility': 'list'}
            ],
          }))),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/responses')) {
        final body = sseEvents.map((e) => 'data: $e\n\n').join();
        return http.StreamedResponse(
          Stream.fromIterable(body.split('').map(utf8.encode)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.StreamedResponse(Stream.value(utf8.encode('not found')), 404);
    });
  }
}

/// Fake browser launcher: captures authorize URLs without opening a browser.
final class FakeLauncher {
  final List<Uri> launched = [];
  Future<bool> call(Uri url) async {
    launched.add(url);
    return true;
  }
}

/// Helper to assert no token/secret leakage into exported maps.
bool containsSecret(Object? value, List<String> secrets) {
  final text = value is String ? value : json.encode(value);
  return secrets.any(text.contains);
}
