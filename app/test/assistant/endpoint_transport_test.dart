import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/assistant/chatgpt_session.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/assistant/endpoint_transport.dart';
import 'package:salu/src/assistant/operation_fence.dart';

void main() {
  group('OperationFence', () {
    test('invalidate increments epoch before invoking subscribers', () {
      final fence = OperationFence();
      final epoch = fence.capture();
      expect(fence.isCurrent(epoch), isTrue);

      var sawInvalidatedInsideCallback = false;
      fence.onInvalidate(() {
        sawInvalidatedInsideCallback = !fence.isCurrent(epoch);
      });

      fence.invalidate();
      expect(sawInvalidatedInsideCallback, isTrue);
      expect(fence.isCurrent(epoch), isFalse);
      final nextEpoch = fence.capture();
      expect(nextEpoch, greaterThan(epoch));
      expect(fence.isCurrent(nextEpoch), isTrue);
    });

    test('isolates subscriber failures and supports unregister', () {
      final fence = OperationFence();
      final calls = <String>[];

      final unregisterRemoved = fence.onInvalidate(() => calls.add('removed'));
      fence.onInvalidate(() {
        calls.add('throws');
        throw StateError('boom');
      });
      fence.onInvalidate(() => calls.add('second'));

      unregisterRemoved();
      unregisterRemoved();
      fence.invalidate();

      expect(calls, ['throws', 'second']);

      // Invalidate again: already-fired subscribers do not re-fire.
      calls.clear();
      fence.invalidate();
      expect(calls, isEmpty);
    });
  });

  group('EndpointTransport', () {
    test('rejects CRLF headers locally before opening a socket', () async {
      var clientsCreated = 0;
      final transport = EndpointTransport(
        clientFactory: () {
          clientsCreated++;
          return HttpClient();
        },
      );
      final fence = OperationFence();

      for (final badHeaders in [
        {'Authorization': 'Bearer ok\r\nX-Injected: 1'},
        {'Authorization': 'Bearer ok\nX-Injected: 1'},
        {'X-Bad\r\nName': 'value'},
        {'X-Null': 'val\x00ue'},
      ]) {
        await expectLater(
          transport.send(
            uri: Uri.parse('https://api.openai.com/v1/responses'),
            method: 'POST',
            headers: badHeaders,
            body: const {'ok': true},
            allowInsecureLocal: false,
            fence: fence,
          ),
          throwsA(_assistantError(SaluAssistantErrorCode.requestRejected)),
        );
      }
      expect(clientsCreated, 0);
    });

    test(
        'enforces HTTPS unless allowInsecureLocal and validates IPv4/IPv6 local addresses',
        () async {
      var clientsCreated = 0;
      String? capturedProxyResult;
      final transport = EndpointTransport(
        clientFactory: () {
          clientsCreated++;
          return _TrackingHttpClient(
            onFindProxy: (uri) => capturedProxyResult = uri.toString(),
          );
        },
        dnsLookup: (host) async => switch (host) {
          'ok.local' => [InternetAddress('192.168.1.50')],
          'public.local' => [InternetAddress('93.184.216.34')],
          'mixed.local' => [
              InternetAddress('127.0.0.1'),
              InternetAddress('8.8.8.8'),
            ],
          _ => [InternetAddress('127.0.0.1')],
        },
      );
      final fence = OperationFence();

      // Plain HTTP without opt-in is rejected.
      await expectLater(
        transport.send(
          uri: Uri.parse('http://127.0.0.1:8080/v1/responses'),
          method: 'POST',
          headers: const {},
          allowInsecureLocal: false,
          fence: fence,
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.requestRejected)),
      );

      // Disallowed IP literals and hostnames resolving to public IPs are rejected.
      for (final badUrl in [
        'http://8.8.8.8:8080/v1/responses',
        'http://172.15.255.255:8080/v1/responses',
        'http://172.32.0.1:8080/v1/responses',
        'http://169.254.169.254/latest/meta-data',
        'http://100.64.0.1:8080/v1/responses',
        'http://0.0.0.0:8080/v1/responses',
        'http://[2001:4860:4860::8888]:8080/v1/responses',
        'http://[::ffff:8.8.8.8]:8080/v1/responses',
        'http://[::]:8080/v1/responses',
        'http://public.local:8080/v1/responses',
        'http://mixed.local:8080/v1/responses',
      ]) {
        await expectLater(
          transport.send(
            uri: Uri.parse(badUrl),
            method: 'POST',
            headers: const {},
            allowInsecureLocal: true,
            fence: fence,
          ),
          throwsA(_assistantError(SaluAssistantErrorCode.requestRejected)),
          reason: 'Should reject $badUrl',
        );
      }
      expect(clientsCreated, 0);

      // Allowed IPv4/IPv6 local targets pass validation and disable proxy.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        req.response.statusCode = 200;
        req.response.write('{"ok":true}');
        await req.response.close();
      }));

      final trackingClients = <_TrackingHttpClient>[];
      final directTransport = EndpointTransport(
        clientFactory: () {
          final client = _TrackingHttpClient();
          trackingClients.add(client);
          return client;
        },
        dnsLookup: (host) async => [InternetAddress.loopbackIPv4],
      );
      final response = await directTransport.send(
        uri: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
        method: 'POST',
        headers: const {'Authorization': 'Bearer local-secret'},
        body: const {'hello': 'world'},
        allowInsecureLocal: true,
        fence: fence,
      );
      expect(response, {'ok': true});
      expect(trackingClients.single.findProxyResultForTest, 'DIRECT');
      expect(trackingClients.single.forcedCloses, 1);
      expect(capturedProxyResult, isNull);

      // Verify all allowed private/loopback/link-local IPv4 & IPv6 classes pass validation.
      for (final allowedUrl in [
        'http://10.0.0.5:8080/v1/responses',
        'http://172.16.0.1:8080/v1/responses',
        'http://172.31.255.254:8080/v1/responses',
        'http://192.168.1.50:8080/v1/responses',
        'http://[::1]:8080/v1/responses',
        'http://[fc00::1]:8080/v1/responses',
        'http://[fd12:3456::1]:8080/v1/responses',
        'http://[fe80::1]:8080/v1/responses',
        'http://[::ffff:192.168.1.1]:8080/v1/responses',
        'http://ok.local:8080/v1/responses',
      ]) {
        expect(
          EndpointTransport.isAllowedLocalUriForTesting(
            Uri.parse(allowedUrl),
            await switch (Uri.parse(allowedUrl).host) {
              'ok.local' => Future.value([InternetAddress('192.168.1.50')]),
              final host => Future.value([InternetAddress(host)]),
            },
          ),
          isTrue,
          reason: 'Should allow $allowedUrl',
        );
      }
    });

    test('307 redirect does not contact second server and closes client',
        () async {
      final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await serverA.close(force: true);
        await serverB.close(force: true);
      });

      var serverBRequests = 0;
      unawaited(serverB.forEach((req) async {
        serverBRequests++;
        req.response.statusCode = 200;
        req.response.write('{"leaked":true}');
        await req.response.close();
      }));

      unawaited(serverA.forEach((req) async {
        req.response.statusCode = HttpStatus.temporaryRedirect;
        req.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${serverB.port}/steal-key',
        );
        req.response.write('redirect-secret-body');
        await req.response.close();
      }));

      final clients = <_TrackingHttpClient>[];
      final transport = EndpointTransport(
        clientFactory: () {
          final client = _TrackingHttpClient();
          clients.add(client);
          return client;
        },
      );

      await expectLater(
        transport.send(
          uri: Uri.parse('https://example.invalid/').replace(
            scheme: 'http',
            host: '127.0.0.1',
            port: serverA.port,
            path: '/v1/responses',
          ),
          method: 'POST',
          headers: const {'Authorization': 'Bearer top-secret-key'},
          body: const {'a': 1},
          allowInsecureLocal: true,
          fence: OperationFence(),
        ),
        throwsA(
          isA<SaluAssistantException>()
              .having(
                  (e) => e.code, 'code', SaluAssistantErrorCode.requestRejected)
              .having((e) => e.toString(), 'msg',
                  isNot(contains('redirect-secret-body')))
              .having((e) => e.toString(), 'msg',
                  isNot(contains('top-secret-key'))),
        ),
      );

      expect(serverBRequests, 0);
      expect(clients, hasLength(1));
      expect(clients.single.forcedCloses, 1);
    });

    test(
        'handles stalled connect, stalled headers, and stalled body within deadline',
        () async {
      // 1. Stalled connect (via client factory stalling open/postUrl).
      final stalledClients = <_StallingConnectClient>[];
      final connectTransport = EndpointTransport(
        timeout: const Duration(milliseconds: 60),
        clientFactory: () {
          final client = _StallingConnectClient();
          stalledClients.add(client);
          return client;
        },
      );
      await expectLater(
        connectTransport.send(
          uri: Uri.parse('https://api.openai.com/v1/responses'),
          method: 'POST',
          headers: const {},
          body: const {'x': 1},
          allowInsecureLocal: false,
          fence: OperationFence(),
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.timeout)),
      );
      expect(stalledClients.single.forcedCloses, 1);

      // 2. Stalled headers on loopback HttpServer.
      final headerServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => headerServer.close(force: true));
      final heldResponses = <HttpResponse>[];
      unawaited(headerServer.forEach((req) async {
        await req.drain<void>();
        // Never write or close headers.
        heldResponses.add(req.response);
      }));

      final headerClients = <_TrackingHttpClient>[];
      final headerTransport = EndpointTransport(
        timeout: const Duration(milliseconds: 60),
        clientFactory: () {
          final client = _TrackingHttpClient();
          headerClients.add(client);
          return client;
        },
      );
      await expectLater(
        headerTransport.send(
          uri: Uri.parse('http://127.0.0.1:${headerServer.port}/v1/responses'),
          method: 'POST',
          headers: const {},
          body: const {'x': 1},
          allowInsecureLocal: true,
          fence: OperationFence(),
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.timeout)),
      );
      expect(headerClients.single.forcedCloses, 1);

      // 3. Stalled body after headers + first partial chunk.
      final bodyServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => bodyServer.close(force: true));
      unawaited(bodyServer.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = 200;
        req.response.write('{"partial":');
        await req.response.flush();
        heldResponses.add(req.response);
      }));

      final bodyClients = <_TrackingHttpClient>[];
      final bodyTransport = EndpointTransport(
        timeout: const Duration(milliseconds: 60),
        clientFactory: () {
          final client = _TrackingHttpClient();
          bodyClients.add(client);
          return client;
        },
      );
      await expectLater(
        bodyTransport.send(
          uri: Uri.parse('http://127.0.0.1:${bodyServer.port}/v1/responses'),
          method: 'POST',
          headers: const {},
          body: const {'x': 1},
          allowInsecureLocal: true,
          fence: OperationFence(),
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.timeout)),
      );
      expect(bodyClients.single.forcedCloses, 1);

      for (final res in heldResponses) {
        try {
          await res.close();
        } on Object {
          // Socket already closed by client.
        }
      }
    });

    test('rejects chunked over-limit bodies promptly and closes client',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = 200;
        // Chunked transfer encoding (no Content-Length).
        req.response.headers.chunkedTransferEncoding = true;
        for (var i = 0; i < 6; i++) {
          req.response.add(utf8.encode('x' * 64));
          await req.response.flush();
        }
        try {
          await req.response.close();
        } on Object {
          // Client already forced closed.
        }
      }));

      final clients = <_TrackingHttpClient>[];
      final transport = EndpointTransport(
        timeout: const Duration(seconds: 2),
        clientFactory: () {
          final client = _TrackingHttpClient();
          clients.add(client);
          return client;
        },
      );

      await expectLater(
        transport.send(
          uri: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
          method: 'POST',
          headers: const {},
          body: const {},
          allowInsecureLocal: true,
          fence: OperationFence(),
          maxBytes: 128,
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
      );
      expect(clients.single.forcedCloses, 1);
    });

    test('decodes UTF-8 multi-byte characters split across TCP chunks',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = 200;
        req.response.bufferOutput = false;
        final full = utf8.encode('{"food":"avocado 🥑"}');
        final emojiIndex = full.indexOf(0xF0);
        // Split right inside the 4-byte UTF-8 emoji sequence.
        req.response.add(full.sublist(0, emojiIndex + 2));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        req.response.add(full.sublist(emojiIndex + 2));
        await req.response.close();
      }));

      final transport = EndpointTransport(timeout: const Duration(seconds: 2));
      final result = await transport.send(
        uri: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
        method: 'POST',
        headers: const {},
        body: const {},
        allowInsecureLocal: true,
        fence: OperationFence(),
      );
      expect(result, {'food': 'avocado 🥑'});
    });

    test('cancellation during credential wait and during stream read',
        () async {
      // 1. Cancellation during credential wait prevents any HttpClient creation.
      var clientsCreated = 0;
      final transport = EndpointTransport(
        timeout: const Duration(seconds: 2),
        clientFactory: () {
          clientsCreated++;
          return _TrackingHttpClient();
        },
      );
      final fence = OperationFence();
      final epoch = fence.capture();
      final keyLoad = Completer<String>();
      unawaited(Future<void>.delayed(const Duration(milliseconds: 10), () {
        fence.invalidate();
        keyLoad.complete('late-secret');
      }));

      await keyLoad.future;
      await expectLater(
        transport.send(
          uri: Uri.parse('https://api.openai.com/v1/responses'),
          method: 'POST',
          headers: const {'Authorization': 'Bearer late-secret'},
          body: const {},
          allowInsecureLocal: false,
          fence: fence,
          epoch: epoch,
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.connectionChanged)),
      );
      expect(clientsCreated, 0);

      // 2. Cancellation during active stream read closes client promptly.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final firstChunkSent = Completer<void>();
      HttpResponse? activeResponse;
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = 200;
        req.response.bufferOutput = false;
        req.response.add(utf8.encode('{"partial":'));
        await req.response.flush();
        activeResponse = req.response;
        if (!firstChunkSent.isCompleted) firstChunkSent.complete();
      }));

      final streamFence = OperationFence();
      final clients = <_TrackingHttpClient>[];
      final streamTransport = EndpointTransport(
        timeout: const Duration(seconds: 5),
        clientFactory: () {
          final client = _TrackingHttpClient();
          clients.add(client);
          return client;
        },
      );

      final pending = expectLater(
        streamTransport.send(
          uri: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
          method: 'POST',
          headers: const {},
          body: const {},
          allowInsecureLocal: true,
          fence: streamFence,
        ),
        throwsA(_assistantError(SaluAssistantErrorCode.connectionChanged)),
      );

      await firstChunkSent.future;
      streamFence.invalidate();
      await pending;
      expect(clients.single.forcedCloses, 1);

      try {
        await activeResponse?.close();
      } on Object {
        // Already closed.
      }
    });

    test(
        'held-open SSE terminal stream completes promptly without waiting for EOF',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      HttpResponse? heldResponse;
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.bufferOutput = false;
        final event = utf8.encode(
          'data: {"type":"response.output_text.delta","delta":"🥑"}\n\n'
          'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n',
        );
        final split = event.indexOf(0xF0) + 2;
        req.response.add(event.sublist(0, split));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        req.response.add(event.sublist(split));
        await req.response.flush();
        // Deliberately keep socket open!
        heldResponse = req.response;
      }));

      final clients = <_TrackingHttpClient>[];
      final transport = EndpointTransport(
        timeout: const Duration(seconds: 5),
        clientFactory: () {
          final client = _TrackingHttpClient();
          clients.add(client);
          return client;
        },
      );

      final stopwatch = Stopwatch()..start();
      final result = await transport.sendSse(
        uri: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
        method: 'POST',
        headers: const {},
        body: const {'stream': true},
        allowInsecureLocal: true,
        fence: OperationFence(),
      );
      stopwatch.stop();

      expect(result, {'status': 'completed', 'output': <Object?>[]});
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(clients.single.forcedCloses, 1);

      try {
        await heldResponse?.close();
      } on Object {
        // Socket closed.
      }
    });

    test('never leaks raw provider error bodies or secrets in thrown errors',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const secret = 'sk-super-secret-token-value';
      const rawBody = 'provider-internal-stacktrace-$secret';

      var nextStatus = 401;
      unawaited(server.forEach((req) async {
        await req.drain<void>();
        req.response.statusCode = nextStatus;
        req.response.write(rawBody);
        await req.response.close();
      }));

      final clients = <_TrackingHttpClient>[];
      final transport = EndpointTransport(
        timeout: const Duration(seconds: 2),
        clientFactory: () {
          final client = _TrackingHttpClient();
          clients.add(client);
          return client;
        },
      );

      for (final (status, expectedCode) in [
        (401, SaluAssistantErrorCode.authenticationFailed),
        (403, SaluAssistantErrorCode.accessDenied),
        (429, SaluAssistantErrorCode.rateLimited),
        (500, SaluAssistantErrorCode.serviceUnavailable),
      ]) {
        nextStatus = status;
        await expectLater(
          transport.send(
            uri: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
            method: 'POST',
            headers: const {'Authorization': 'Bearer $secret'},
            body: const {},
            allowInsecureLocal: true,
            fence: OperationFence(),
          ),
          throwsA(
            isA<SaluAssistantException>()
                .having((e) => e.code, 'code', expectedCode)
                .having((e) => e.toString(), 'msg', isNot(contains(secret)))
                .having((e) => e.toString(), 'msg', isNot(contains(rawBody))),
          ),
        );
      }
      expect(clients, hasLength(4));
      expect(clients.every((c) => c.forcedCloses == 1), isTrue);
    });
  });

  group('ChatGptSession', () {
    test('caches discovered model per session and clears on invalidate',
        () async {
      final storage = _InMemoryKeyValueStorage({
        'salu.chatgpt.session.v1': jsonEncode({
          'access_token': 'tok-1',
          'refresh_token': 'ref-1',
          'client_id': 'cid-1',
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        }),
      });
      var getCount = 0;
      var postCount = 0;
      final fence = OperationFence();
      final transport = EndpointTransport(
        clientFactory: () => _MockDispatchHttpClient((method, uri, _) async {
          if (method == 'GET' && uri.path == '/v1/models') {
            getCount++;
            return _MockHttpResponse(
              200,
              utf8.encode(jsonEncode({
                'models': [
                  {'visibility': 'list', 'slug': 'gpt-cached-model'},
                ],
              })),
            );
          }
          if (method == 'POST' && uri.path == '/v1/responses') {
            postCount++;
            final completed = {
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'status': 'completed',
                  'content': [
                    {'type': 'output_text', 'text': '{"ok":true}'},
                  ],
                },
              ],
            };
            return _MockHttpResponse(
              200,
              utf8.encode(
                'data: ${jsonEncode({
                      'type': 'response.completed',
                      'response': completed
                    })}\n\n',
              ),
            );
          }
          throw StateError('Unexpected $method $uri');
        }),
      );

      final session = ChatGptSession(
        transport: transport,
        fence: fence,
        storage: storage,
      );
      final assistant = SaluAssistant(
        chatGptSession: session,
        transport: transport,
        fence: fence,
      );

      expect(
          await assistant.ask(instructions: 'i', prompt: 'p1'), {'ok': true});
      expect(
          await assistant.ask(instructions: 'i', prompt: 'p2'), {'ok': true});
      expect(getCount, 1);
      expect(postCount, 2);

      session.invalidate();
      expect(
          await assistant.ask(instructions: 'i', prompt: 'p3'), {'ok': true});
      expect(getCount, 2);
    });

    test('preserves networkError and timeout instead of authenticationFailed',
        () async {
      final expiredSession = jsonEncode({
        'access_token': 'tok-old',
        'refresh_token': 'ref-1',
        'client_id': 'cid-1',
        'expires_at': 0,
      });

      final netFence = OperationFence();
      final netTransport = EndpointTransport(
        clientFactory: () => _MockDispatchHttpClient((method, uri, _) async {
          throw const SocketException('offline');
        }),
      );
      final netAssistant = SaluAssistant(
        chatGptSession: ChatGptSession(
          transport: netTransport,
          fence: netFence,
          storage: _InMemoryKeyValueStorage({
            'salu.chatgpt.session.v1': expiredSession,
          }),
        ),
        transport: netTransport,
        fence: netFence,
      );
      await expectLater(
        netAssistant.ask(instructions: 'i', prompt: 'p'),
        throwsA(_assistantError(SaluAssistantErrorCode.networkError)),
      );

      final timeoutFence = OperationFence();
      final timeoutTransport = EndpointTransport(
        timeout: const Duration(milliseconds: 60),
        clientFactory: () => _MockDispatchHttpClient((method, uri, _) async {
          if (uri.path.endsWith('/oauth/token')) {
            await Future<void>.delayed(const Duration(milliseconds: 45));
            return _MockHttpResponse(
              200,
              utf8.encode(jsonEncode({
                'access_token': 'tok-new',
                'refresh_token': 'ref-2',
                'expires_in': 3600,
              })),
            );
          }
          // Model lookup eats the remaining ~15ms and breaches the 60ms shared budget.
          await Future<void>.delayed(const Duration(milliseconds: 45));
          return _MockHttpResponse(
            200,
            utf8.encode(jsonEncode({
              'models': [
                {'visibility': 'list', 'slug': 'gpt-m'},
              ],
            })),
          );
        }),
      );
      final timeoutAssistant = SaluAssistant(
        chatGptSession: ChatGptSession(
          transport: timeoutTransport,
          fence: timeoutFence,
          storage: _InMemoryKeyValueStorage({
            'salu.chatgpt.session.v1': expiredSession,
          }),
          timeout: const Duration(milliseconds: 60),
        ),
        transport: timeoutTransport,
        fence: timeoutFence,
        requestTimeout: const Duration(milliseconds: 60),
      );
      await expectLater(
        timeoutAssistant.ask(instructions: 'i', prompt: 'p'),
        throwsA(_assistantError(SaluAssistantErrorCode.timeout)),
      );
    });
  });
}

Matcher _assistantError(SaluAssistantErrorCode code) =>
    isA<SaluAssistantException>().having((e) => e.code, 'code', code);

final class _InMemoryKeyValueStorage implements SecureKeyValueStorage {
  _InMemoryKeyValueStorage([Map<String, String>? initial])
      : _data = Map<String, String>.from(initial ?? const {});

  final Map<String, String> _data;

  @override
  Future<String?> read({required String key}) async => _data[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _data[key] = value;

  @override
  Future<void> delete({required String key}) async => _data.remove(key);

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.from(_data);
}

final class _MockDispatchHttpClient implements HttpClient {
  _MockDispatchHttpClient(this._handler);

  final Future<HttpClientResponse> Function(
    String method,
    Uri uri,
    List<int> body,
  ) _handler;
  int forcedCloses = 0;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _MockDispatchRequest('GET', url, _handler);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _MockDispatchRequest('POST', url, _handler);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _MockDispatchRequest(method, url, _handler);

  @override
  void close({bool force = false}) {
    if (force) forcedCloses++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MockDispatchRequest implements HttpClientRequest {
  _MockDispatchRequest(this._method, this._uri, this._handler);

  final String _method;
  final Uri _uri;
  final Future<HttpClientResponse> Function(
    String method,
    Uri uri,
    List<int> body,
  ) _handler;
  final _body = <int>[];

  @override
  final HttpHeaders headers = _MockHeaders();

  @override
  int contentLength = -1;

  @override
  bool followRedirects = true;

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  Future<HttpClientResponse> close() => _handler(_method, _uri, _body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MockHeaders implements HttpHeaders {
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MockHttpResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _MockHttpResponse(this.statusCode, List<int> body)
      : contentLength = body.length,
        super(Stream<List<int>>.value(body));

  @override
  final int statusCode;

  @override
  final int contentLength;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TrackingHttpClient implements HttpClient {
  _TrackingHttpClient({this.onFindProxy});

  final HttpClient _inner = HttpClient();
  final void Function(Uri url)? onFindProxy;
  String? findProxyResultForTest;
  int forcedCloses = 0;

  @override
  set findProxy(String Function(Uri url)? f) {
    if (f != null) {
      findProxyResultForTest = f(Uri.parse('http://127.0.0.1/'));
    }
    _inner.findProxy = f;
  }

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _inner.openUrl(method, url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _inner.postUrl(url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _inner.getUrl(url);

  @override
  void close({bool force = false}) {
    if (force) forcedCloses++;
    _inner.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StallingConnectClient implements HttpClient {
  int forcedCloses = 0;
  final Completer<HttpClientRequest> _pending = Completer<HttpClientRequest>();

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _pending.future;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => _pending.future;

  @override
  void close({bool force = false}) {
    if (force) forcedCloses++;
    if (!_pending.isCompleted) {
      _pending.completeError(const SocketException('aborted'));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
