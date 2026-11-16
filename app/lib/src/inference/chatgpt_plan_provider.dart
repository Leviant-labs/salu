/// ChatGPT-plan Responses transport: planAssistance via streaming SSE.
///
/// Endpoints (documented public route only): `GET /v1/models`,
/// `POST /v1/responses` on `https://api.openai.com/v1`. Every request sends
/// `store:false, stream:true` and the minimal local context; no
/// `previous_response_id`, conversation, metadata, temperature, or hosted
/// tools. A response counts only after `response.completed`; partial output
/// on failure/incomplete/cancel is discarded, never reviewed.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:salu_core/salu_core.dart';

import 'provider_connection.dart';


class ChatGptPlanProvider implements InferenceProvider {
  ChatGptPlanProvider({
    required Future<String> Function() accessToken,
    required Future<List<ChatGptModel>> Function() listModels,
    String? Function()? modelSlug,
    http.Client Function()? clientFactory,
    void Function(http.Request)? onRequest,
    Duration timeout = const Duration(seconds: 120),
    String? developerInstructions,
    Uri? baseUri,
  })  : _accessToken = accessToken,
        _listModels = listModels,
        _modelSlug = modelSlug,
        _clientFactory = clientFactory ?? (() => http.Client()),
        _onRequest = onRequest,
        _timeout = timeout,
        _developerInstructions = developerInstructions ??
            'You are Salu plan assistance. Reply with one strict '
            'salu-plan-assistance-v1 JSON object and nothing else.',
        _base = baseUri ?? Uri.parse('https://api.openai.com/v1');

  final Future<String> Function() _accessToken;
  final Future<List<ChatGptModel>> Function() _listModels;
  final String? Function()? _modelSlug;
  final http.Client Function() _clientFactory;
  final void Function(http.Request)? _onRequest;
  final Duration _timeout;
  final String _developerInstructions;
  final Uri _base;

  final Map<String, _ActiveCall> _active = {};
  final Set<String> _pendingCancelled = <String>{};
  int _generation = 0;
  final Map<String, String> _completedModels = {};

  /// Returns and removes the actual model used by a successful request.
  String? takeCompletedModel(String requestId) => _completedModels.remove(requestId);

  @override
  String get providerId => 'chatgpt-plan';

  @override
  Set<InferenceCapability> get capabilities => const {
        InferenceCapability.structuredOutput,
        InferenceCapability.streaming,
        InferenceCapability.cancellation,
      };

  @override
  bool supports(InferenceTask task) => task == InferenceTask.planAssistance;

  void cancelActive(String requestId) {
    _pendingCancelled.add(requestId);
    final call = _active.remove(requestId);
    if (call != null) {
      call.cancelled = true;
      try {
        call.client.close();
      } catch (_) {}
      final c = call.completerRef;
      if (c != null && !c.isCompleted) {
        c.completeError(StateError('CANCELLED:$requestId'));
      }
    }
  }

  @override
  Future<void> disconnect() async {
    _generation++;
    _completedModels.clear();
    for (final id in _active.keys.toList()) {
      cancelActive(id);
    }
  }

  static Map<String, Object?> get planAssistanceResponseSchema =>
      <String, Object?>{
        'type': 'object',
        'additionalProperties': false,
        'required': [
          'action',
          'changes',
          'message',
          'question',
          'recipeRanks',
          'schemaVersion',
        ],
        'properties': {
          'schemaVersion': const {'type': 'integer', 'const': 1},
          'action': const {
            'type': 'string',
            'enum': ['explain', 'clarify', 'proposePlanChange'],
          },
          'message': const {'type': 'string'},
          'question': const {'type': ['string', 'null']},
          'recipeRanks': {
            'type': 'array',
            'items': {
              'type': 'object',
              'additionalProperties': false,
              'required': ['rank', 'recipeId'],
              'properties': {
                'recipeId': const {'type': 'string'},
                'rank': const {'type': 'integer', 'minimum': 0, 'maximum': 100},
              },
            },
          },
          'changes': {
            'anyOf': [
              {
                    'type': 'object',
                    'required': [
                      'avoidFoodIds',
                      'budget',
                      'coldLunches',
                      'dislikedRecipeIds',
                      'likedRecipeIds',
                      'maximumCookingMinutes',
                      'scope',
                      'slotIds',
                    ],
                    'properties': {
                      'scope': const {
                        'type': 'string',
                        'enum': ['selectedMeal', 'remainingWeek', 'nextWeek'],
                      },
                      'slotIds': {
                        'type': 'array',
                        'items': const {'type': 'string'},
                      },
                      'coldLunches': const {'type': ['boolean', 'null']},
                      'maximumCookingMinutes': const {
                        'type': ['integer', 'null'],
                        'minimum': 1,
                      },
                      'budget': const {
                        'type': ['string', 'null'],
                        'enum': ['lowerCost', 'standard', 'flexible', null],
                      },
                      'avoidFoodIds': {
                        'type': 'array',
                        'items': const {'type': 'string'},
                      },
                      'likedRecipeIds': {
                        'type': 'array',
                        'items': const {'type': 'string'},
                      },
                      'dislikedRecipeIds': {
                        'type': 'array',
                        'items': const {'type': 'string'},
                      },
                    },
                    'additionalProperties': false,
              },
              {'type': 'null'},
            ],
          },
        },
      };

  static String get planAssistanceSchemaJson =>
      json.encode(planAssistanceResponseSchema);

  /// Parses [request.expectedSchema] (JSON text) into the Responses schema.
  Map<String, Object?> _resolveSchema(InferenceRequest request) {
    final raw = request.expectedSchema;
    if (raw == null || raw.trim().isEmpty) return planAssistanceResponseSchema;
    try {
      final decoded = json.decode(raw);
      if (decoded is Map && decoded['type'] == 'object') {
        return Map<String, Object?>.from(decoded);
      }
    } catch (_) {}
    throw StateError('INVALID_SCHEMA');
  }

  @override
  Future<InferenceResponse> infer(InferenceRequest request) async {
    if (request.requestId.isEmpty) throw StateError('INVALID_REQUEST');
    if (!supports(request.task)) throw StateError('CAPABILITY_UNSUPPORTED');
    final generation = _generation;
    void checkCancelled() {
      if (generation != _generation || _pendingCancelled.contains(request.requestId)) {
        throw StateError('CANCELLED:${request.requestId}');
      }
    }
    if (_pendingCancelled.contains(request.requestId)) {
      throw StateError('CANCELLED:${request.requestId}');
    }
    final token = await _accessToken();
    checkCancelled();
    final models = await _listModels();
    checkCancelled();
    final listed = models.where((m) => m.slug.isNotEmpty).toList();
    if (listed.isEmpty) throw StateError('MODEL_ACCESS_UNAVAILABLE');
    final selected = _modelSlug?.call();
    if (selected != null && !listed.any((m) => m.slug == selected)) {
      throw StateError('MODEL_SELECTION_UNAVAILABLE');
    }
    final String model = selected ?? listed.first.slug;
    final schema = _resolveSchema(request);
    final body = <String, Object?>{
      'model': model,
      'instructions': _developerInstructions,
      'input': [
        {'role': 'user', 'content': request.prompt},
      ],
      'store': false,
      'stream': true,
      'text': {
        'format': {
          'type': 'json_schema',
          'name': planAssistanceSchemaName,
          'strict': true,
          'schema': schema,
        },
      },
    };
    final streamClient = _clientFactory();
    final req = http.Request('POST', Uri.parse('${_base.toString().replaceAll(RegExp(r'/$'), '')}/responses'));
    req.headers['authorization'] = 'Bearer $token';
    req.headers['content-type'] = 'application/json';
    req.body = json.encode(body);
    _onRequest?.call(req);
    final call = _ActiveCall(streamClient: streamClient);
    _active[request.requestId] = call;
    http.StreamedResponse resp;
    try {
      resp = await streamClient.send(req).timeout(_timeout);
      checkCancelled();
    } catch (e) {
      _active.remove(request.requestId);
      try {
        streamClient.close();
      } catch (_) {}
      if (call.cancelled || generation != _generation) {
        throw StateError('CANCELLED:${request.requestId}');
      }
      if (e is TimeoutException) throw StateError('TIMEOUT:${request.requestId}');
      rethrow;
    }
    if (call.cancelled || generation != _generation) {
      _active.remove(request.requestId);
      streamClient.close();
      throw StateError('CANCELLED:${request.requestId}');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final raw = await resp.stream.bytesToString();
      final code = _errorCodeFromBody(raw);
      final requestId = resp.headers['x-request-id'];
      _active.remove(request.requestId);
      try {
        streamClient.close();
      } catch (_) {}
      throw StateError(
          '${code ?? 'HTTP_${resp.statusCode}'}${requestId == null ? '' : ':$requestId'}');
    }
    // SSE decode across arbitrary chunk boundaries.
    final completer = Completer<InferenceResponse>();
    call.completer = completer;
    final buffer = StringBuffer();
    var completed = false;
    String? failCode;
    String? failRequestId;
    var lineBuffer = '';
    void handleData(String chunk) {
      lineBuffer += chunk;
      var idx = lineBuffer.indexOf('\n');
      while (idx >= 0) {
        final line = lineBuffer.substring(0, idx).replaceAll('\r', '').trim();
        lineBuffer = lineBuffer.substring(idx + 1);
        idx = lineBuffer.indexOf('\n');
        if (line.isEmpty) continue;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') continue;
        Object? decoded;
        try {
          decoded = json.decode(data);
        } catch (_) {
          continue;
        }
        if (decoded is! Map) continue;
        final type = decoded['type']?.toString();
        if (type == 'response.output_text.delta') {
          buffer.write(decoded['delta']?.toString() ?? '');
        } else if (type == 'response.completed') {
          completed = true;
          final response = decoded['response'];
          final output = response is Map ? response['output'] : null;
          final finalText = StringBuffer();
          if (output is List) {
            for (final item in output) {
              if (item is! Map || item['role'] != 'assistant') continue;
              final content = item['content'];
              if (content is! List) continue;
              for (final part in content) {
                if (part is Map && part['type'] == 'output_text' && part['text'] is String) {
                  finalText.write(part['text']);
                }
              }
            }
          }
          _finish(request, completer,
              finalText.isNotEmpty ? finalText.toString() : buffer.toString(), model);
          return;
        } else if (type == 'response.failed') {
          final r = decoded['response'];
          String? code;
          if (r is Map) {
            final e = r['error'];
            if (e is Map && e['code'] != null) code = e['code'].toString();
          }
          failCode = code ?? 'RESPONSE_FAILED';
          failRequestId = r is Map ? r['id']?.toString() : null;
          _fail(completer, failCode!, failRequestId);
          return;
        } else if (type == 'response.incomplete') {
          failCode = 'RESPONSE_INCOMPLETE';
          _fail(completer, failCode!, null);
          return;
        } else if (type == 'error') {
          final e = decoded['error'];
          failCode = e is Map && e['code'] != null ? e['code'].toString() : 'RESPONSE_FAILED';
          failRequestId = decoded['request_id']?.toString();
          _fail(completer, failCode!, failRequestId);
          return;
        }
      }
    }

    resp.stream
        .transform(utf8.decoder)
        .listen(handleData, onError: (Object e) {
      if (call.cancelled) return;
      _active.remove(request.requestId);
      if (!completer.isCompleted) {
        completer.completeError(StateError('STREAM_ERROR:${request.requestId}'));
      }
    }, onDone: () {
      final cancelled = call.cancelled;
      _active.remove(request.requestId);
      try {
        streamClient.close();
      } catch (_) {}
      if (cancelled) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('CANCELLED:${request.requestId}'));
        }
        return;
      }
      if (!completed && !completer.isCompleted) {
        completer.completeError(
            StateError(failCode ?? 'INCOMPLETE_STREAM:${request.requestId}'));
      }
    });
    return completer.future;
  }

  void _finish(
      InferenceRequest request, Completer<InferenceResponse> completer, String text, String model) {
    if (completer.isCompleted) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      completer.completeError(StateError('INVALID_SUGGESTION'));
      return;
    }
    Object? decoded;
    try {
      decoded = json.decode(trimmed);
    } catch (_) {
      completer.completeError(StateError('INVALID_SUGGESTION'));
      return;
    }
    if (decoded is! Map) {
      completer.completeError(StateError('INVALID_SUGGESTION'));
      return;
    }
    final map = <String, Object?>{};
    for (final e in decoded.entries) {
      map[e.key.toString()] = e.value;
    }
    try {
      PlanAssistanceSuggestion.fromJson(map);
    } catch (_) {
      completer.completeError(StateError('INVALID_SUGGESTION'));
      return;
    }
    _completedModels[request.requestId] = model;
    completer.complete(InferenceResponse(
      requestId: request.requestId,
      text: trimmed,
      structured: map,
    ));
  }

  void _fail(Completer<InferenceResponse> completer, String code, String? rid) {
    if (completer.isCompleted) return;
    completer.completeError(StateError(rid == null ? code : '$code:$rid'));
  }

  String? _errorCodeFromBody(String body) {
    try {
      final decoded = json.decode(body);
      if (decoded is Map) {
        final e = decoded['error'];
        if (e is Map && e['code'] != null) return e['code'].toString();
        final d = decoded['detail'];
        if (d is String) return d;
      }
    } catch (_) {}
    return null;
  }

  /// Test seam: synchronous SSE line handler for split-chunk fixtures.
  static List<String> splitSseLines(List<String> chunks) {
    final lines = <String>[];
    var buf = '';
    for (final c in chunks) {
      buf += c;
      var idx = buf.indexOf('\n');
      while (idx >= 0) {
        lines.add(buf.substring(0, idx).replaceAll('\r', '').trim());
        buf = buf.substring(idx + 1);
        idx = buf.indexOf('\n');
      }
    }
    if (buf.isNotEmpty) lines.add(buf.trim());
    return lines;
  }
}

final class _ActiveCall {
  _ActiveCall({required http.Client streamClient})
      : client = streamClient;
  final http.Client client;
  Completer<InferenceResponse>? completerRef;
  bool cancelled = false;
  Completer<InferenceResponse> get completer =>
      completerRef ??= Completer<InferenceResponse>();
  set completer(Completer<InferenceResponse> c) => completerRef = c;
}
