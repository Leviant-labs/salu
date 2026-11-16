import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:salu/src/inference/chatgpt_auth.dart';
import 'package:salu/src/inference/chatgpt_plan_provider.dart';
import 'package:salu/src/inference/provider_connection.dart';
import 'package:salu_core/salu_core.dart';

import 'support/chatgpt_http_fixture.dart';

void main() {
  Map<String, Object?> explainJson() => <String, Object?>{
        'schemaVersion': 1,
        'action': 'explain',
        'message': 'Quick and cheap.',
        'question': null,
        'recipeRanks': <Object?>[],
        'changes': null,
      };

  ChatGptPlanProvider streamingProvider(List<String> sseEvents) {
    const token = 'fixture-access';
    return ChatGptPlanProvider(
      accessToken: () async => token,
      listModels: () async => [
        const ChatGptModel(slug: 'gpt-test', displayName: 'GPT Test'),
        const ChatGptModel(slug: 'gpt-second', displayName: 'GPT Second'),
      ],
      clientFactory: () => ChatGptFixture.modelsClient(
          models: const [
            ChatGptModel(slug: 'gpt-test', displayName: 'GPT Test'),
          ],
          sseEvents: sseEvents),
    );
  }

  test('completed SSE returns structured output', () async {
    final provider = streamingProvider([
      json.encode({'type': 'response.output_text.delta', 'delta': json.encode(explainJson()).substring(0, 20)}),
      json.encode({'type': 'response.output_text.delta', 'delta': json.encode(explainJson()).substring(20)}),
      json.encode({'type': 'response.completed'}),
    ]);
    final resp = await provider.infer(const InferenceRequest(
      requestId: 'r1',
      task: InferenceTask.planAssistance,
      prompt: 'why this meal?',
      expectedSchema: null,
    ));
    expect(resp.requestId, 'r1');
    expect(resp.structured!['action'], 'explain');
    expect(resp.structured!['message'], 'Quick and cheap.');
    expect(provider.takeCompletedModel('r1'), 'gpt-test');
    expect(provider.takeCompletedModel('r1'), isNull);
  });

  test('truncated stream discards partial output', () async {
    final provider = streamingProvider([
      json.encode({'type': 'response.output_text.delta', 'delta': '{"schemaVer'}),
    ]);
    await expectLater(
      provider.infer(const InferenceRequest(
        requestId: 'r2',
        task: InferenceTask.planAssistance,
        prompt: 'x',
      )),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('INCOMPLETE_STREAM'))),
    );
  });

  test('response.failed discards partial output', () async {
    final provider = streamingProvider([
      json.encode({'type': 'response.output_text.delta', 'delta': 'partial'}),
      json.encode({
        'type': 'response.failed',
        'response': {
          'id': 'resp-1',
          'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
        },
      }),
    ]);
    await expectLater(
      provider.infer(const InferenceRequest(
        requestId: 'r3',
        task: InferenceTask.planAssistance,
        prompt: 'x',
      )),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('subscription_sharing_usage_limit_exceeded'))),
    );
  });

  test('malformed JSON maps to INVALID_SUGGESTION', () async {
    final provider = streamingProvider([
      json.encode({'type': 'response.output_text.delta', 'delta': 'not json {{{'}),
      json.encode({'type': 'response.completed'}),
    ]);
    await expectLater(
      provider.infer(const InferenceRequest(
        requestId: 'r4',
        task: InferenceTask.planAssistance,
        prompt: 'x',
      )),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('INVALID_SUGGESTION'))),
    );
  });

  test('cancellation while awaiting token never starts inference', () async {
    final token = Completer<String>();
    var sent = false;
    final provider = ChatGptPlanProvider(
      accessToken: () => token.future,
      listModels: () async => [const ChatGptModel(slug: 'gpt-test', displayName: 'Test')],
      onRequest: (_) => sent = true,
    );
    final future = provider.infer(const InferenceRequest(
      requestId: 'r5', task: InferenceTask.planAssistance, prompt: 'x',
    ));
    final expectation = expectLater(future, throwsA(isA<StateError>().having(
        (e) => e.message, 'message', contains('CANCELLED'))));
    provider.cancelActive('r5');
    token.complete('fixture-access');
    await expectation;
    expect(sent, isFalse);
  });

  test('request body uses documented route + no extra fields', () async {
    final captured = <http.Request>[];
    final provider = ChatGptPlanProvider(
      accessToken: () async => 'fixture-access',
      listModels: () async => [
        const ChatGptModel(slug: 'gpt-test', displayName: 'GPT Test'),
      ],
      onRequest: captured.add,
      clientFactory: () => ChatGptFixture.modelsClient(
        models: const [
          ChatGptModel(slug: 'gpt-test', displayName: 'GPT Test'),
        ],
        sseEvents: [
          json.encode({'type': 'response.output_text.delta', 'delta': json.encode(explainJson())}),
          json.encode({'type': 'response.completed'}),
        ],
      ),
    );
    await provider.infer(InferenceRequest(
      requestId: 'r7',
      task: InferenceTask.planAssistance,
      prompt: 'hello',
      expectedSchema: ChatGptPlanProvider.planAssistanceSchemaJson,
    ));
    expect(captured, hasLength(1));
    final body = json.decode(captured.first.body) as Map<String, Object?>;
    expect(body['store'], isFalse);
    expect(body['stream'], isTrue);
    expect(body.containsKey('previous_response_id'), isFalse);
    expect(body.containsKey('temperature'), isFalse);
    expect(body.containsKey('max_output_tokens'), isFalse);
    expect(body.containsKey('tools'), isFalse);
    final text = body['text'] as Map<String, Object?>;
    final format = text['format'] as Map<String, Object?>;
    expect(format['type'], 'json_schema');
    expect(format['name'], 'salu-plan-assistance-v1');
    expect(body['input'], isA<List<Object?>>());
    expect(captured.first.headers['authorization'], 'Bearer fixture-access');
  });

  test('unsupported task rejected', () async {
    final provider = ChatGptPlanProvider(
      accessToken: () async => 'token',
      listModels: () async => const <ChatGptModel>[],
    );
    await expectLater(
      provider.infer(const InferenceRequest(
        requestId: 'r8',
        task: InferenceTask.labelOcr,
        prompt: 'x',
      )),
      throwsA(isA<StateError>()),
    );
  });

  test('provider connection mapping reflects auth state', () async {
    final auth = ChatGptAuthController(
      store: FakeTokenStore(),
      client: http.Client(),
      launchUrl: FakeLauncher().call,
    );
    final source = AuthProviderConnectionSource(auth);
    expect(source.current()!.connected, isFalse);
    expect(source.current()!.toAuthorization().connected, isFalse);
    auth.dispose();
    source.dispose();
  });
}
