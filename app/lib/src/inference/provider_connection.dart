/// Connection view over [ChatGptAuthController] for AssistantController.
///
/// The assistant gates every transfer on [ProviderAuthorization] built from
/// live OAuth state (connected + direct-plan grant), never on legacy
/// terms/distribution switches.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:salu_core/salu_core.dart';

import 'chatgpt_auth.dart';
/// Observed connection facts for one provider.
final class ProviderConnectionInfo {
  const ProviderConnectionInfo({
    required this.providerId,
    required this.connected,
    required this.planUsageGranted,
    this.modelSlug,
    this.errorCode,
  });
  final String providerId;
  final bool connected;
  final bool planUsageGranted;
  final String? modelSlug;
  final String? errorCode;
  ProviderAuthorization toAuthorization() => ProviderAuthorization(
        providerId: providerId,
        connected: connected,
        planUsageGranted: planUsageGranted,
      );
}

/// Read side of the connection (Riverpod-wired in providers.dart).
abstract interface class ProviderConnectionSource {
  ProviderConnectionInfo? current();
  Stream<ProviderConnectionInfo> get changes;
}

/// Model catalog/choice (server-ordered, `visibility == 'list'` only).
final class ChatGptModel {
  const ChatGptModel({required this.slug, required this.displayName});
  final String slug;
  final String displayName;
}

abstract interface class ModelSelectionSource {
  Future<List<ChatGptModel>> listModels();
  String? get selectedSlug;
  Future<void> selectModel(String slug);
}

/// Default [ProviderConnectionSource] adapting [ChatGptAuthController].
final class AuthProviderConnectionSource implements ProviderConnectionSource {
  AuthProviderConnectionSource(this._auth, {String? modelSlug})
      : _modelSlug = modelSlug {
    _auth.addListener(push);
  }
  final ChatGptAuthController _auth;
  String? _modelSlug;
  final _controller = StreamController<ProviderConnectionInfo>.broadcast();

  @override
  ProviderConnectionInfo? current() {
    if (!_auth.isConnected && _auth.activeRegistrationId == null) {
      return const ProviderConnectionInfo(
        providerId: 'chatgpt-plan',
        connected: false,
        planUsageGranted: false,
      );
    }
    return ProviderConnectionInfo(
      providerId: 'chatgpt-plan',
      connected: _auth.isConnected,
      planUsageGranted: _auth.planUsageGranted,
      modelSlug: _modelSlug,
    );
  }

  @override
  Stream<ProviderConnectionInfo> get changes => _controller.stream;

  void push() {
    final c = current();
    if (c != null && !_controller.isClosed) _controller.add(c);
  }

  void setModelSlug(String? slug) {
    _modelSlug = slug;
    push();
  }

  void dispose() {
    _auth.removeListener(push);
    _controller.close();
  }
}

/// Fetches the account model catalog (visibility == 'list', server order).
Future<List<ChatGptModel>> fetchChatGptModels({
  required String accessToken,
  required http.Client client,
}) async {
  final resp = await client.get(
    Uri.parse('https://api.openai.com/v1/models'),
    headers: {'authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw StateError('MODEL_LIST_FAILED:${resp.statusCode}');
  }
  final decoded = json.decode(resp.body) as Map<String, Object?>;
  final raw = decoded['models'];
  if (raw is! List) return const <ChatGptModel>[];
  final out = <ChatGptModel>[];
  for (final e in raw) {
    if (e is! Map) continue;
    if (e['visibility']?.toString() != 'list') continue;
    final slug = e['slug']?.toString();
    if (slug == null || slug.isEmpty) continue;
    out.add(ChatGptModel(
      slug: slug,
      displayName: e['display_name']?.toString() ?? slug,
    ));
  }
  return out;
}
