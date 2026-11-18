import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/assistant/chatgpt_session.dart';

const _key = 'sk-proj-test-only-not-a-real-key';
const _prompt = 'Summarize the meal.';
const _instructions = 'Report the estimated item names.';
const _jpegSignature = [0xff, 0xd8, 0xff];
const _pngSignature = [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10];

void main() {
  test('ChatGPT plan requests use streaming and require completion', () async {
    final completed = jsonDecode(_result('{"items":["toast"]}'));
    final client = _FakeHttpClient.reply(_response(
      'data: {"type":"response.output_text.delta","delta":"partial"}\n\n'
      'data: ${jsonEncode({
            'type': 'response.completed',
            'response': completed
          })}\n\n',
    ));
    final assistant = SaluAssistant(
      chatGptSession: _FakeChatGptSession(),
      httpClientFactory: () => client,
    );
    expect(await _ask(assistant), {
      'items': ['toast']
    });
    final body =
        jsonDecode(utf8.decode(client.request.body)) as Map<String, dynamic>;
    expect(body['stream'], isTrue);
    expect(body['store'], isFalse);
    expect(body.containsKey('max_output_tokens'), isFalse);
    expect(body['model'], 'test-chatgpt-model');
    expect(client.request.headers.values['accept'], 'text/event-stream');

    final incomplete = _FakeHttpClient.reply(_response(
      'data: {"type":"response.output_text.delta","delta":"partial"}\n\n',
    ));
    await expectLater(
      _ask(SaluAssistant(
          chatGptSession: _FakeChatGptSession(),
          httpClientFactory: () => incomplete)),
      throwsA(_error(SaluAssistantErrorCode.incompleteResponse)),
    );
    final limited = _FakeHttpClient.reply(_response(
      'data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}\n\n',
    ));
    await expectLater(
      _ask(SaluAssistant(
          chatGptSession: _FakeChatGptSession(),
          httpClientFactory: () => limited)),
      throwsA(_error(SaluAssistantErrorCode.quotaExceeded)),
    );
  });

  test(
    'connection state is local; only ask can create an HTTP client',
    () async {
      final store = _MemoryKeyStore();
      var clientCount = 0;
      final assistant = SaluAssistant(
        keyStore: store,
        httpClientFactory: () {
          clientCount++;
          throw StateError('unexpected network access');
        },
      );

      expect(await assistant.isConnected, isFalse);
      await expectLater(
        _ask(assistant),
        throwsA(_error(SaluAssistantErrorCode.notConnected)),
      );
      await expectLater(
        assistant.connect('sk-invalid\r\nAuthorization: injected'),
        throwsA(_error(SaluAssistantErrorCode.invalidKey)),
      );
      expect(store.key, isNull);

      await assistant.connect('  $_key\n');
      expect(store.key, _key);
      expect(await assistant.isConnected, isTrue);
      expect(await SaluAssistant(keyStore: store).isConnected, isTrue);

      await assistant.disconnect();
      expect(store.key, isNull);
      expect(await assistant.isConnected, isFalse);
      await expectLater(
        _ask(assistant),
        throwsA(_error(SaluAssistantErrorCode.notConnected)),
      );
      expect(clientCount, 0);
    },
  );

  test('a failed key deletion cannot authorize another ask', () async {
    final store = _MemoryKeyStore(_key)
      ..deleteFailure = StateError('credentials: $_key');
    final assistant = SaluAssistant(keyStore: store);
    final error = throwsA(_error(SaluAssistantErrorCode.storageUnavailable));

    await expectLater(assistant.disconnect(), error);
    expect(store.key, _key);
    await expectLater(assistant.isConnected, error);
    await expectLater(_ask(assistant), error);

    store.deleteFailure = null;
    await assistant.disconnect();
    expect(await assistant.isConnected, isFalse);
  });

  test(
    'sends one bounded JSON-mode request to the public Responses API',
    () async {
      final client = _FakeHttpClient.reply(
        _response(_result('{"items":["toast"]}')),
      );
      final result = await _ask(
        _connected(client),
        images: [
          Uint8List.fromList([..._jpegSignature, 0xe0]),
          Uint8List.fromList([..._pngSignature, 0]),
        ],
      );

      expect(result, {
        'items': ['toast'],
      });
      expect(client.postedTo, [
        Uri.parse('https://api.openai.com/v1/responses'),
      ]);
      final request = client.request;
      expect(request.followRedirects, isFalse);
      expect(request.headers.values['authorization'], 'Bearer $_key');
      expect(request.headers.values['accept'], 'application/json');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(request.contentLength, request.body.length);
      expect(utf8.decode(request.body), isNot(contains(_key)));
      final Object? body = jsonDecode(utf8.decode(request.body));
      const model = String.fromEnvironment('SALU_OPENAI_MODEL');
      expect(body, {
        'model': model.trim().isEmpty ? 'gpt-4.1-mini' : model.trim(),
        'store': false,
        'max_output_tokens': 2048,
        'text': {
          'format': {'type': 'json_object'},
        },
        'input': [
          {
            'role': 'developer',
            'content': allOf(contains('JSON'), contains(_instructions)),
          },
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': _prompt},
              {
                'type': 'input_image',
                'detail': 'auto',
                'image_url': 'data:image/jpeg;base64,/9j/4A==',
              },
              {
                'type': 'input_image',
                'detail': 'auto',
                'image_url': 'data:image/png;base64,iVBORw0KGgoA',
              },
            ],
          },
        ],
      });
      expect(client.forcedCloses, 1);
    },
  );

  test('rejects local input problems before transport is created', () async {
    final largeJpeg = Uint8List(4 * 1024 * 1024)..setAll(0, _jpegSignature);
    final store = _MemoryKeyStore(_key);
    var clientCount = 0;
    final assistant = SaluAssistant(
      keyStore: store,
      httpClientFactory: () {
        clientCount++;
        throw StateError('invalid input reached the network');
      },
    );
    final tooLarge = throwsA(_error(SaluAssistantErrorCode.requestTooLarge));
    await expectLater(
      _ask(assistant, prompt: '  '),
      throwsA(_error(SaluAssistantErrorCode.invalidInput)),
    );
    await expectLater(_ask(assistant, prompt: 'x' * (25 * 1024)), tooLarge);
    await expectLater(
      _ask(
        assistant,
        images: [
          Uint8List.fromList([0x47, 0x49, 0x46]),
        ],
      ),
      throwsA(_error(SaluAssistantErrorCode.unsupportedImage)),
    );
    await expectLater(
      _ask(assistant, images: [Uint8List(largeJpeg.length + 1)]),
      tooLarge,
    );
    await expectLater(
      _ask(assistant, images: [largeJpeg, largeJpeg, largeJpeg]),
      tooLarge,
    );
    await expectLater(
      _ask(assistant, images: List.filled(5, largeJpeg)),
      tooLarge,
    );
    expect(clientCount, 0);
  });

  test('an image-only ask snapshots the bytes at invocation', () async {
    final storageRead = Completer<String?>();
    final store = _MemoryKeyStore()..onRead = () => storageRead.future;
    final client = _FakeHttpClient.reply(_response(_result('{}')));
    final assistant = SaluAssistant(
      keyStore: store,
      httpClientFactory: () => client,
    );
    final image = Uint8List.fromList([..._jpegSignature, 0xe0]);

    final result = _ask(assistant, prompt: '', images: [image]);
    image.fillRange(0, image.length, 0);
    storageRead.complete(_key);
    expect(await result, isEmpty);

    final body = utf8.decode(client.request.body);
    expect(body, contains('data:image/jpeg;base64,/9j/4A=='));
    expect(body, isNot(contains('input_text')));
  });

  for (final (status, body, code) in [
    (401, 'Invalid key $_key', SaluAssistantErrorCode.authenticationFailed),
    (403, 'Forbidden $_key', SaluAssistantErrorCode.accessDenied),
    (
      429,
      '{"error":{"code":"insufficient_quota","message":"$_key"}}',
      SaluAssistantErrorCode.quotaExceeded,
    ),
    (429, 'Slow down $_key', SaluAssistantErrorCode.rateLimited),
    (503, 'Unavailable $_key', SaluAssistantErrorCode.serviceUnavailable),
    (307, 'Redirect $_key', SaluAssistantErrorCode.requestRejected),
  ]) {
    test(
      'maps HTTP $status to ${code.name} without leaking or retrying',
      () async {
        final client = _FakeHttpClient.reply(_response(body, status: status));
        await expectLater(_ask(_connected(client)), throwsA(_error(code)));
        expect(client.postedTo, hasLength(1));
        expect(client.request.followRedirects, isFalse);
        expect(client.forcedCloses, 1);
      },
    );
  }

  test(
    'reads completed output_text parts in order, skipping reasoning',
    () async {
      final body = jsonEncode({
        'status': 'completed',
        'output': [
          {'type': 'reasoning', 'summary': <Object>[]},
          _message([
            {'type': 'output_text', 'text': '{"food":"'},
            {'type': 'output_text', 'text': 'avocado 🥑"}'},
          ]),
        ],
      });
      final client = _FakeHttpClient.reply(_response(body));
      expect(await _ask(_connected(client)), {'food': 'avocado 🥑'});
      expect(utf8.decode(client.request.body), isNot(contains('input_image')));
    },
  );

  test(
    'surfaces incomplete replies and refusals without partial data',
    () async {
      final incomplete = _FakeHttpClient.reply(
        _response('{"status":"incomplete","output":[]}'),
      );
      await expectLater(
        _ask(_connected(incomplete)),
        throwsA(_error(SaluAssistantErrorCode.incompleteResponse)),
      );

      final refusal = _FakeHttpClient.reply(
        _response(
          jsonEncode({
            'status': 'completed',
            'output': [
              _message([
                {'type': 'output_text', 'text': '{"ok":true}'},
                {'type': 'refusal', 'refusal': 'Refusal detail: $_key'},
              ]),
            ],
          }),
        ),
      );
      await expectLater(
        _ask(_connected(refusal)),
        throwsA(_error(SaluAssistantErrorCode.refused)),
      );
    },
  );

  for (final (label, body) in [
    ('invalid JSON envelope', '<html>$_key</html>'),
    ('missing Responses output', '{"status":"completed","output_text":"{}"}'),
    (
      'unexpected tool output',
      '{"status":"completed","output":[{"type":"function_call"}]}',
    ),
    ('fenced text', _result('```json\n{"ok":true}\n```')),
    ('array result', _result('[{"ok":true}]')),
    ('trailing data', _result('{"ok":true} other text')),
    ('non-finite number', _result('{"quantity":1e999}')),
    ('deep result', _result('{"items":${'[' * 40}0${']' * 40}}')),
    ('reflected key', _result('{"nested":[{"value":"$_key"}]}')),
  ]) {
    test('rejects $label as untrusted output', () async {
      final client = _FakeHttpClient.reply(_response(body));
      await expectLater(
        _ask(_connected(client)),
        throwsA(_error(SaluAssistantErrorCode.invalidResponse)),
      );
    });
  }

  test('bounds streamed response bytes even without Content-Length', () async {
    final chunk = Uint8List(300 * 1024);
    final client = _FakeHttpClient.reply(
      _FakeResponse(200, Stream<List<int>>.fromIterable([chunk, chunk])),
    );
    await expectLater(
      _ask(_connected(client)),
      throwsA(_error(SaluAssistantErrorCode.invalidResponse)),
    );
    expect(client.forcedCloses, 1);
  });

  test(
    'maps transport failures without exposing the underlying cause',
    () async {
      final client = _FakeHttpClient(() async => throw SocketException(_key));
      await expectLater(
        _ask(_connected(client)),
        throwsA(_error(SaluAssistantErrorCode.networkError)),
      );
      expect(client.forcedCloses, 1);
    },
  );

  test('wall-clock timeout includes reading the response body', () async {
    final chunks = StreamController<List<int>>();
    final client = _FakeHttpClient.reply(
      _FakeResponse(200, chunks.stream),
      onClose: () => unawaited(chunks.close()),
    );
    chunks.add(utf8.encode('{"status":'));
    await expectLater(
      _ask(_connected(client, timeout: const Duration(milliseconds: 50))),
      throwsA(_error(SaluAssistantErrorCode.timeout)),
    );
    expect(client.forcedCloses, 1);
    expect(client.postedTo, hasLength(1));
  });

  test('disconnect while loading a key prevents a stale upload', () async {
    final started = Completer<void>();
    final read = Completer<String?>();
    final store = _MemoryKeyStore(_key)
      ..onRead = () {
        started.complete();
        return read.future;
      };
    final client = _FakeHttpClient.reply(_response(_result('{}')));
    final assistant = SaluAssistant(
      keyStore: store,
      httpClientFactory: () => client,
    );
    final pending = expectLater(
      _ask(assistant),
      throwsA(_error(SaluAssistantErrorCode.connectionChanged)),
    );
    await started.future;
    await assistant.disconnect();
    read.complete(_key);
    await pending;
    expect(client.postedTo, isEmpty);
  });

  test(
    'disconnect aborts an active request and no second ask is queued',
    () async {
      final started = Completer<void>();
      final reply = Completer<HttpClientResponse>();
      final client = _FakeHttpClient(() {
        started.complete();
        return reply.future;
      }, onClose: () => reply.completeError(const SocketException('closed')));
      final assistant = _connected(client);
      final pending = expectLater(
        _ask(assistant),
        throwsA(_error(SaluAssistantErrorCode.connectionChanged)),
      );
      await started.future;
      await expectLater(
        _ask(assistant),
        throwsA(_error(SaluAssistantErrorCode.busy)),
      );
      await assistant.disconnect();
      await pending;
      expect(await assistant.isConnected, isFalse);
      expect(client.forcedCloses, 1);
      expect(client.postedTo, hasLength(1));
    },
  );
  test(
    'a connection completing after disconnect cannot send the body',
    () async {
      final connecting = Completer<void>();
      final request = Completer<HttpClientRequest>();
      final client = _FakeHttpClient.reply(_response(_result('{}')))
        ..onPost = () {
          connecting.complete();
          return request.future;
        };
      final assistant = _connected(client);
      final pending = expectLater(
        _ask(assistant),
        throwsA(_error(SaluAssistantErrorCode.connectionChanged)),
      );
      await connecting.future;
      await assistant.disconnect();
      request.complete(client.request);
      await pending;
      expect(client.request.body, isEmpty);
      expect(client.request.headers.values, isEmpty);
    },
  );
}

class _FakeChatGptSession extends ChatGptSession {
  @override
  Future<bool> get isConnected async => true;
  @override
  Future<String> accessToken() async => 'test-oauth-access-token';
  @override
  Future<String> model(String token) async => 'test-chatgpt-model';
}

Matcher _error(SaluAssistantErrorCode code) => isA<SaluAssistantException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.toString(), 'display text', isNot(contains(_key)));

Future<Map<String, dynamic>> _ask(
  SaluAssistant assistant, {
  String prompt = _prompt,
  List<Uint8List> images = const [],
}) =>
    assistant.ask(instructions: _instructions, prompt: prompt, images: images);

SaluAssistant _connected(
  _FakeHttpClient client, {
  Duration timeout = const Duration(seconds: 2),
}) =>
    SaluAssistant(
      keyStore: _MemoryKeyStore(_key),
      httpClientFactory: () => client,
      requestTimeout: timeout,
    );

Map<String, Object> _message(List<Map<String, String>> content) => {
      'type': 'message',
      'role': 'assistant',
      'status': 'completed',
      'content': content,
    };

String _result(String text) => jsonEncode({
      'status': 'completed',
      'output': [
        _message([
          {'type': 'output_text', 'text': text},
        ]),
      ],
    });

_FakeResponse _response(String body, {int status = 200}) =>
    _FakeResponse(status, Stream<List<int>>.value(utf8.encode(body)));

final class _MemoryKeyStore implements SaluAssistantKeyStore {
  _MemoryKeyStore([this.key]);

  String? key;
  Object? deleteFailure;
  Future<String?> Function()? onRead;

  @override
  Future<String?> read() async {
    final callback = onRead;
    if (callback != null) return callback();
    return key;
  }

  @override
  Future<void> write(String key) async => this.key = key;

  @override
  Future<void> delete() async {
    final failure = deleteFailure;
    if (failure != null) throw failure;
    key = null;
  }
}

final class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(Future<HttpClientResponse> Function() reply, {this.onClose})
      : request = _FakeRequest(reply);

  _FakeHttpClient.reply(HttpClientResponse response, {void Function()? onClose})
      : this(() async => response, onClose: onClose);

  final _FakeRequest request;
  final void Function()? onClose;
  final postedTo = <Uri>[];
  Future<HttpClientRequest> Function()? onPost;
  int forcedCloses = 0;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    postedTo.add(url);
    final callback = onPost;
    if (callback != null) return callback();
    return request;
  }

  @override
  void close({bool force = false}) {
    if (force) forcedCloses++;
    onClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._reply);

  final Future<HttpClientResponse> Function() _reply;
  final body = <int>[];

  @override
  final _FakeHeaders headers = _FakeHeaders();

  @override
  int contentLength = -1;

  @override
  bool followRedirects = true;

  @override
  void add(List<int> data) => body.addAll(data);

  @override
  Future<HttpClientResponse> close() => _reply();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHeaders implements HttpHeaders {
  final values = <String, Object>{};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._chunks);

  final Stream<List<int>> _chunks;

  @override
  final int statusCode;

  @override
  int get contentLength => -1;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _chunks.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
