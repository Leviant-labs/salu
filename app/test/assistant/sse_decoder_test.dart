import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/assistant/sse_decoder.dart';

void main() {
  test('terminal event completes without waiting for EOF', () {
    final decoder = SseDecoder();
    expect(decoder.add('data: {"type":"response.com'), isNull);
    final result =
        decoder.add('pleted","response":{"status":"completed"}}\n\n');
    expect(result!['status'], 'completed');
    decoder.finish();
  });

  test('handles CRLF, CR, and split CRLF across chunk boundaries', () {
    final crlfDecoder = SseDecoder();
    expect(
      crlfDecoder.add('data: {"type":"response.output_text.delta"}\r\n\r'),
      isNull,
    );
    expect(
      crlfDecoder.add('\ndata: {"type":"response.completed","response":'),
      isNull,
    );
    final crlfResult = crlfDecoder.add('{"status":"completed"}}\r\n\r\n');
    expect(crlfResult!['status'], 'completed');
    crlfDecoder.finish();

    final crDecoder = SseDecoder();
    expect(
      crDecoder.add(
        'data: {"type":"response.completed","response":{"status":"completed"}}\r\r',
      ),
      {'status': 'completed'},
    );
    crDecoder.finish();
  });

  test('handles multiline data fields, comments, and ignores [DONE]', () {
    final decoder = SseDecoder();
    expect(decoder.add(': keep-alive\n\n'), isNull);
    expect(decoder.add('event: ping\ndata: [DONE]\n\n'), isNull);
    expect(
      decoder.add(
          'event: response.completed\ndata: {"type":"response.completed",\n'),
      isNull,
    );
    final result = decoder.add(
      'data: "response":{"status":"completed","output":[]}}\n\n',
    );
    expect(result, {'status': 'completed', 'output': <Object?>[]});
    decoder.finish();
  });

  test('finish fails if no terminal event has been observed', () {
    final empty = SseDecoder();
    expect(
      empty.finish,
      throwsA(_assistantError(SaluAssistantErrorCode.incompleteResponse)),
    );

    final partial = SseDecoder()
      ..add('data: {"type":"response.output_text.delta","delta":"hi"}\n\n');
    expect(
      partial.finish,
      throwsA(_assistantError(SaluAssistantErrorCode.incompleteResponse)),
    );

    final unterminated = SseDecoder()
      ..add(
          'data: {"type":"response.completed","response":{"status":"completed"}}');
    expect(
      unterminated.finish,
      throwsA(_assistantError(SaluAssistantErrorCode.incompleteResponse)),
    );
  });

  test('rejects error, failed, incomplete, and malformed SSE events', () {
    expect(
      () => SseDecoder().add(
        'data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}\n\n',
      ),
      throwsA(_assistantError(SaluAssistantErrorCode.quotaExceeded)),
    );
    expect(
      () => SseDecoder().add(
        'data: {"type":"error","error":{"code":"subscription_sharing_usage_unavailable"}}\n\n',
      ),
      throwsA(_assistantError(SaluAssistantErrorCode.quotaExceeded)),
    );
    expect(
      () => SseDecoder().add(
        'data: {"type":"response.failed","response":{"error":{"code":"server_error"}}}\n\n',
      ),
      throwsA(_assistantError(SaluAssistantErrorCode.requestRejected)),
    );
    expect(
      () => SseDecoder().add('data: {"type":"error","error":{}}\n\n'),
      throwsA(_assistantError(SaluAssistantErrorCode.requestRejected)),
    );
    expect(
      () => SseDecoder().add('data: {"type":"response.incomplete"}\n\n'),
      throwsA(_assistantError(SaluAssistantErrorCode.incompleteResponse)),
    );
    expect(
      () => SseDecoder().add('data: {not-json\n\n'),
      throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
    );
    expect(
      () => SseDecoder().add('data: {"type":"response.completed"}\n\n'),
      throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
    );
  });

  test('bounds total UTF-8 event bytes using byte length', () {
    // 🥑 is 4 UTF-8 bytes (2 UTF-16 code units).
    const payload =
        'data: {"type":"response.completed","response":{"status":"completed","icon":"🥑"}}\n\n';
    final decoderExact = SseDecoder(maxBytes: payload.length + 2);
    final result = decoderExact.add(payload);
    expect(result!['status'], 'completed');

    // Limit below actual UTF-8 byte count (even if above UTF-16 length).
    final decoderTooSmall = SseDecoder(maxBytes: payload.length);
    expect(
      () => decoderTooSmall.add(payload),
      throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
    );

    // Default 512 KiB bound triggers across multiple delta chunks.
    final huge = SseDecoder();
    final delta =
        'data: {"type":"response.output_text.delta","delta":"${'a' * 1000}"}\n\n';
    expect(
      () {
        for (var i = 0; i < 600; i++) {
          huge.add(delta);
        }
      },
      throwsA(_assistantError(SaluAssistantErrorCode.invalidResponse)),
    );
  });
}

Matcher _assistantError(SaluAssistantErrorCode code) =>
    isA<SaluAssistantException>().having((e) => e.code, 'code', code);
