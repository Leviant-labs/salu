import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/assistant/endpoint_transport.dart';
import 'package:salu/src/assistant/model_discovery.dart';
import 'package:salu/src/assistant/operation_fence.dart';
import 'package:salu_core/salu_core.dart';

const _fakeOpenAiKey = 'sk-test-only-discovery-00000000';
const _fakeAnthropicKey = 'sk-ant-test-only-discovery-0000';

void main() {
  group('discoverModels', () {
    test('uses GET only, preserves API root prefix, and sets protocol headers',
        () async {
      final seenRequests = <({
        String method,
        String path,
        Map<String, List<String>> headers,
      })>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        final headers = <String, List<String>>{};
        req.headers.forEach((name, values) => headers[name] = values);
        seenRequests.add((
          method: req.method,
          path: req.uri.path,
          headers: headers,
        ));
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'model-a', 'display_name': 'Model A'},
            {'id': 'model-b'},
          ],
        }));
        await req.response.close();
      }));

      final creds = _MemoryCredentialStore()
        ..slots['salu.ep.oa'] = _fakeOpenAiKey
        ..slots['salu.ep.ant'] = _fakeAnthropicKey;
      final transport = EndpointTransport();
      final fence = OperationFence();
      final root = Uri.parse('http://127.0.0.1:${server.port}/team/v1');

      final oaProfile = EndpointProfile(
        id: 'oa',
        name: 'OpenAI',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: root,
        credentialRef: 'salu.ep.oa',
        discovery: ModelDiscoveryMode.models,
        allowInsecureLocal: true,
      );
      final oaModels = await discoverModels(oaProfile, creds, transport, fence);
      expect(oaModels, const <DiscoveredModel>[
        DiscoveredModel(id: 'model-a', name: 'Model A'),
        DiscoveredModel(id: 'model-b', name: 'model-b'),
      ]);
      expect(oaProfile.imageInput, isNull);
      expect(seenRequests.last.method, 'GET');
      expect(seenRequests.last.path, '/team/v1/models');
      expect(
        seenRequests.last.headers['authorization'],
        ['Bearer $_fakeOpenAiKey'],
      );

      final antProfile = EndpointProfile(
        id: 'ant',
        name: 'Anthropic',
        protocol: EndpointProtocol.anthropicMessages,
        apiRoot: root,
        credentialRef: 'salu.ep.ant',
        discovery: ModelDiscoveryMode.models,
        allowInsecureLocal: true,
      );
      await discoverModels(antProfile, creds, transport, fence);
      expect(seenRequests.last.method, 'GET');
      expect(seenRequests.last.path, '/team/v1/models');
      expect(seenRequests.last.headers['x-api-key'], [_fakeAnthropicKey]);
      expect(seenRequests.last.headers['anthropic-version'], ['2023-06-01']);
      expect(seenRequests.every((r) => r.method == 'GET'), isTrue);
    });

    test('manual mode rejects locally without contacting network', () async {
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        requests++;
        await req.drain<void>();
        await req.response.close();
      }));

      final profile = EndpointProfile(
        id: 'man',
        name: 'Manual',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        credentialRef: 'salu.ep.oa',
        discovery: ModelDiscoveryMode.manual,
        allowInsecureLocal: true,
      );

      await expectLater(
        discoverModels(
          profile,
          _MemoryCredentialStore()..slots['salu.ep.oa'] = _fakeOpenAiKey,
          EndpointTransport(),
          OperationFence(),
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.requestRejected)),
      );
      expect(requests, 0);
    });

    for (final (status, body, expectedCode)
        in <(int, String, SaluAssistantErrorCode)>[
      (
        401,
        'bad key $_fakeOpenAiKey',
        SaluAssistantErrorCode.authenticationFailed
      ),
      (403, 'forbidden $_fakeOpenAiKey', SaluAssistantErrorCode.accessDenied),
      (
        404,
        'not found $_fakeOpenAiKey',
        SaluAssistantErrorCode.requestRejected
      ),
      (
        405,
        'method not allowed $_fakeOpenAiKey',
        SaluAssistantErrorCode.requestRejected
      ),
      (429, 'slow down $_fakeOpenAiKey', SaluAssistantErrorCode.rateLimited),
      (
        429,
        '{"error":{"code":"insufficient_quota","message":"$_fakeOpenAiKey"}}',
        SaluAssistantErrorCode.quotaExceeded,
      ),
    ]) {
      test('maps HTTP $status to ${expectedCode.name} without guessing paths',
          () async {
        final paths = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        unawaited(server.forEach((req) async {
          await req.drain<void>();
          paths.add('${req.method} ${req.uri.path}');
          req.response.statusCode = status;
          req.response.write(body);
          await req.response.close();
        }));

        final profile = EndpointProfile(
          id: 'err',
          name: 'Err',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('http://127.0.0.1:${server.port}/v1'),
          credentialRef: 'salu.ep.oa',
          discovery: ModelDiscoveryMode.models,
          allowInsecureLocal: true,
        );

        await expectLater(
          discoverModels(
            profile,
            _MemoryCredentialStore()..slots['salu.ep.oa'] = _fakeOpenAiKey,
            EndpointTransport(),
            OperationFence(),
          ),
          throwsA(
            _assistantError(expectedCode, forbiddenSecret: _fakeOpenAiKey),
          ),
        );
        expect(paths, ['GET /v1/models']);
      });
    }

    test(
        'supports both catalogue shapes and rejects ambiguous/malformed shapes',
        () async {
      var replyPayload = <String, Object?>{};
      final paths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        paths.add(req.uri.path);
        req.response.statusCode = 200;
        req.response.write(jsonEncode(replyPayload));
        await req.response.close();
      }));

      final creds = _MemoryCredentialStore()
        ..slots['salu.ep.cat'] = _fakeOpenAiKey;
      final profile = EndpointProfile(
        id: 'cat',
        name: 'Catalogue',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/gw/v1'),
        credentialRef: 'salu.ep.cat',
        discovery: ModelDiscoveryMode.catalogue,
        allowInsecureLocal: true,
      );

      // Shape 1: data: [{id, display_name?}]
      replyPayload = {
        'data': [
          {'id': 'cat-1', 'display_name': 'Cat One'},
          {'id': 'cat-2'},
        ],
      };
      expect(
        await discoverModels(
            profile, creds, EndpointTransport(), OperationFence()),
        const <DiscoveredModel>[
          DiscoveredModel(id: 'cat-1', name: 'Cat One'),
          DiscoveredModel(id: 'cat-2', name: 'cat-2'),
        ],
      );
      expect(paths.last, '/gw/v1/catalogue');

      // Shape 2: models: [{id, name?}]
      replyPayload = {
        'models': [
          {'id': 'mod-1', 'name': 'Mod One'},
          {'id': 'mod-2', 'name': '   '},
        ],
      };
      expect(
        await discoverModels(
            profile, creds, EndpointTransport(), OperationFence()),
        const <DiscoveredModel>[
          DiscoveredModel(id: 'mod-1', name: 'Mod One'),
          DiscoveredModel(id: 'mod-2', name: 'mod-2'),
        ],
      );

      // Reject ambiguous/invalid shapes & invalid IDs
      for (final bad in <Map<String, Object?>>[
        {
          'data': [
            {'id': 'a'},
          ],
          'models': [
            {'id': 'b'},
          ],
        },
        {'items': <Object?>[]},
        {
          'data': [
            {'id': ' leading-space'},
          ],
        },
        {
          'data': [
            {'id': ''},
          ],
        },
        {
          'data': [
            {'id': 'bad\nid'},
          ],
        },
        {
          'data': [
            {'id': 'x' * 257},
          ],
        },
        {
          'data': [
            {'id': _fakeOpenAiKey},
          ],
        },
      ]) {
        replyPayload = bad;
        await expectLater(
          discoverModels(profile, creds, EndpointTransport(), OperationFence()),
          throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
          reason: 'Should reject malformed catalogue payload $bad',
        );
      }
    });

    test('deduplicates IDs keeping first occurrence display name', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        final page = req.uri.queryParameters['page'];
        req.response.statusCode = 200;
        if (page == null) {
          req.response.write(jsonEncode({
            'data': [
              {'id': 'm1', 'display_name': 'First Name'},
              {'id': 'm1', 'display_name': 'Duplicate Same Page'},
            ],
            'next': 'http://127.0.0.1:${server.port}/v1/models?page=2',
          }));
        } else {
          req.response.write(jsonEncode({
            'data': [
              {'id': 'm1', 'display_name': 'Duplicate Next Page'},
              {'id': 'm2', 'display_name': 'Second Model'},
            ],
          }));
        }
        await req.response.close();
      }));

      final profile = EndpointProfile(
        id: 'dup',
        name: 'Dup',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        credentialRef: 'salu.ep.oa',
        discovery: ModelDiscoveryMode.models,
        allowInsecureLocal: true,
      );
      final models = await discoverModels(
        profile,
        _MemoryCredentialStore()..slots['salu.ep.oa'] = _fakeOpenAiKey,
        EndpointTransport(),
        OperationFence(),
      );
      expect(models, const <DiscoveredModel>[
        DiscoveredModel(id: 'm1', name: 'First Name'),
        DiscoveredModel(id: 'm2', name: 'Second Model'),
      ]);
    });

    test('supports Anthropic after_id pagination', () async {
      final seenQueries = <Map<String, String>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        seenQueries.add(req.uri.queryParameters);
        final afterId = req.uri.queryParameters['after_id'];
        req.response.statusCode = 200;
        if (afterId == null) {
          req.response.write(jsonEncode({
            'data': [
              {'id': 'claude-1', 'display_name': 'Claude 1'},
            ],
            'has_more': true,
            'last_id': 'claude-1',
          }));
        } else {
          req.response.write(jsonEncode({
            'data': [
              {'id': 'claude-2', 'display_name': 'Claude 2'},
            ],
            'has_more': false,
            'last_id': 'claude-2',
          }));
        }
        await req.response.close();
      }));

      final profile = EndpointProfile(
        id: 'ant',
        name: 'Anthropic',
        protocol: EndpointProtocol.anthropicMessages,
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        credentialRef: 'salu.ep.ant',
        discovery: ModelDiscoveryMode.models,
        allowInsecureLocal: true,
      );
      final models = await discoverModels(
        profile,
        _MemoryCredentialStore()..slots['salu.ep.ant'] = _fakeAnthropicKey,
        EndpointTransport(),
        OperationFence(),
      );
      expect(models, const <DiscoveredModel>[
        DiscoveredModel(id: 'claude-1', name: 'Claude 1'),
        DiscoveredModel(id: 'claude-2', name: 'Claude 2'),
      ]);
      expect(seenQueries, [
        <String, String>{},
        <String, String>{'after_id': 'claude-1'},
      ]);
    });

    test(
        'rejects wrong-origin, escaped-prefix, and credentialed next URLs with ZERO requests',
        () async {
      final evilServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => evilServer.close(force: true));
      var evilRequests = 0;
      unawaited(evilServer.forEach((req) async {
        evilRequests++;
        await req.drain<void>();
        req.response.statusCode = 200;
        req.response.write('{"data":[{"id":"evil"}]}');
        await req.response.close();
      }));

      final primaryServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => primaryServer.close(force: true));
      final primaryPaths = <String>[];
      var nextToReturn = '';
      unawaited(primaryServer.forEach((req) async {
        await req.drain<void>();
        primaryPaths.add(req.uri.toString());
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'ok-1'},
          ],
          'next': nextToReturn,
        }));
        await req.response.close();
      }));

      final creds = _MemoryCredentialStore()
        ..slots['salu.ep.oa'] = _fakeOpenAiKey;
      final profile = EndpointProfile(
        id: 'sec',
        name: 'Security',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('http://127.0.0.1:${primaryServer.port}/team/v1'),
        credentialRef: 'salu.ep.oa',
        discovery: ModelDiscoveryMode.models,
        allowInsecureLocal: true,
      );

      for (final badNext in <String>[
        'http://127.0.0.1:${evilServer.port}/team/v1/models?page=2',
        'https://evil.example/team/v1/models?page=2',
        '//127.0.0.1:${evilServer.port}/team/v1/models',
        '/other/models?page=2',
        '/team/v10/models?page=2',
        'http://127.0.0.1:${primaryServer.port}/team/v10/models?page=2',
        '../other/models',
        '%2e%2e/other/models',
        'http://user:pass@127.0.0.1:${primaryServer.port}/team/v1/models?page=2',
        'http://user%40a@127.0.0.1:${primaryServer.port}/team/v1/models?page=2',
        'http://127.0.0.1:${primaryServer.port}/team/v1/models?page=2#frag',
      ]) {
        primaryPaths.clear();
        nextToReturn = badNext;
        await expectLater(
          discoverModels(profile, creds, EndpointTransport(), OperationFence()),
          throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
          reason: 'Should reject unsafe next URL "$badNext"',
        );
        expect(primaryPaths, ['/team/v1/models']);
      }
      expect(evilRequests, 0);
    });

    test('detects pagination loops and unknown pagination shapes', () async {
      var reply = <String, Object?>{};
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        requests++;
        req.response.statusCode = 200;
        req.response.write(jsonEncode(reply));
        await req.response.close();
      }));

      final creds = _MemoryCredentialStore()
        ..slots['salu.ep.oa'] = _fakeOpenAiKey;
      final profile = EndpointProfile(
        id: 'loop',
        name: 'Loop',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        credentialRef: 'salu.ep.oa',
        discovery: ModelDiscoveryMode.models,
        allowInsecureLocal: true,
      );

      // URL loop back to self
      requests = 0;
      reply = {
        'data': [
          {'id': 'm1'},
        ],
        'next': 'http://127.0.0.1:${server.port}/v1/models',
      };
      await expectLater(
        discoverModels(profile, creds, EndpointTransport(), OperationFence()),
        throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
      );
      expect(requests, 1);

      // Unknown pagination shapes
      for (final unknown in <Map<String, Object?>>[
        {
          'data': [
            {'id': 'm1'},
          ],
          'has_more': true,
        },
        {
          'data': [
            {'id': 'm1'},
          ],
          'next_cursor': 'abc',
        },
        {
          'data': [
            {'id': 'm1'},
          ],
          'links': {'next': 'http://127.0.0.1:${server.port}/v1/models?p=2'},
        },
      ]) {
        reply = unknown;
        await expectLater(
          discoverModels(profile, creds, EndpointTransport(), OperationFence()),
          throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
          reason: 'Should reject unknown pagination shape $unknown',
        );
      }
    });

    test('enforces 10-page, 2000-ID, 1 MiB, and overall deadline limits',
        () async {
      // 1. 10-page limit (server offers 15 pages)
      var pagesServed = 0;
      final pageServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => pageServer.close(force: true));
      unawaited(pageServer.forEach((req) async {
        await req.drain<void>();
        pagesServed++;
        final page = int.tryParse(req.uri.queryParameters['page'] ?? '1') ?? 1;
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'p-$page'},
          ],
          if (page < 15)
            'next':
                'http://127.0.0.1:${pageServer.port}/v1/models?page=${page + 1}',
        }));
        await req.response.close();
      }));

      final creds = _MemoryCredentialStore()
        ..slots['salu.ep.oa'] = _fakeOpenAiKey;
      final pageModels = await discoverModels(
        EndpointProfile(
          id: 'pages',
          name: 'Pages',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('http://127.0.0.1:${pageServer.port}/v1'),
          credentialRef: 'salu.ep.oa',
          discovery: ModelDiscoveryMode.models,
          allowInsecureLocal: true,
        ),
        creds,
        EndpointTransport(),
        OperationFence(),
      );
      expect(pagesServed, 10);
      expect(pageModels, hasLength(10));

      // 2. 2,000-ID limit (server has 3 pages of 1,000 each -> stops after 2,000 without fetching page 3)
      var idPagesServed = 0;
      final idServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => idServer.close(force: true));
      unawaited(idServer.forEach((req) async {
        await req.drain<void>();
        idPagesServed++;
        final page = int.tryParse(req.uri.queryParameters['page'] ?? '1') ?? 1;
        final start = (page - 1) * 1000;
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': [
            for (var i = 0; i < 1000; i++) {'id': 'm-${start + i}'},
          ],
          'next':
              'http://127.0.0.1:${idServer.port}/v1/models?page=${page + 1}',
        }));
        await req.response.close();
      }));

      final cappedModels = await discoverModels(
        EndpointProfile(
          id: 'ids',
          name: 'IDs',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('http://127.0.0.1:${idServer.port}/v1'),
          credentialRef: 'salu.ep.oa',
          discovery: ModelDiscoveryMode.models,
          allowInsecureLocal: true,
        ),
        creds,
        EndpointTransport(),
        OperationFence(),
      );
      expect(cappedModels, hasLength(2000));
      expect(idPagesServed, 2);

      // 3. 1 MiB per response limit
      final bigServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => bigServer.close(force: true));
      unawaited(bigServer.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = 200;
        req.response.write('{"data":[{"id":"a","display_name":"');
        req.response.write('x' * (1024 * 1024));
        req.response.write('"}]}');
        try {
          await req.response.close();
        } on Object {
          // Client closes socket on cap breach.
        }
      }));

      await expectLater(
        discoverModels(
          EndpointProfile(
            id: 'big',
            name: 'Big',
            protocol: EndpointProtocol.openaiChat,
            apiRoot: Uri.parse('http://127.0.0.1:${bigServer.port}/v1'),
            credentialRef: 'salu.ep.oa',
            discovery: ModelDiscoveryMode.models,
            allowInsecureLocal: true,
          ),
          creds,
          EndpointTransport(),
          OperationFence(),
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
      );

      // 4. Overall deadline across pages
      final slowServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slowServer.close(force: true));
      unawaited(slowServer.forEach((req) async {
        await req.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        req.response.statusCode = 200;
        req.response.write(jsonEncode({
          'data': [
            {'id': 'slow-1'},
          ],
          'next': 'http://127.0.0.1:${slowServer.port}/v1/models?page=2',
        }));
        try {
          await req.response.close();
        } on Object {
          // Closed on timeout.
        }
      }));

      await expectLater(
        discoverModels(
          EndpointProfile(
            id: 'slow',
            name: 'Slow',
            protocol: EndpointProtocol.openaiChat,
            apiRoot: Uri.parse('http://127.0.0.1:${slowServer.port}/v1'),
            credentialRef: 'salu.ep.oa',
            discovery: ModelDiscoveryMode.models,
            allowInsecureLocal: true,
          ),
          creds,
          EndpointTransport(),
          OperationFence(),
          timeout: const Duration(milliseconds: 60),
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.timeout)),
      );
    });
  });
}

Matcher _assistantError(
  SaluAssistantErrorCode code, {
  String? forbiddenSecret,
}) {
  var matcher = isA<SaluAssistantException>().having(
    (error) => error.code,
    'code',
    code,
  );
  if (forbiddenSecret != null) {
    matcher = matcher.having(
      (error) => error.toString(),
      'display message',
      isNot(contains(forbiddenSecret)),
    );
  }
  return matcher;
}

final class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> slots = <String, String>{};

  @override
  Future<String?> read(String ref) async => slots[ref];

  @override
  Future<void> write(String ref, String secret) async => slots[ref] = secret;

  @override
  Future<void> delete(String ref) async => slots.remove(ref);

  @override
  Future<void> clearSaluCredentials() async => slots.clear();
}
