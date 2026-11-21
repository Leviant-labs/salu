import 'package:salu_core/salu_core.dart';

import 'assistant.dart';
import 'credential_store.dart';
import 'endpoint_transport.dart';
import 'operation_fence.dart';
import 'protocol_adapters.dart';

const int maxDiscoveryPages = 10;
const int maxDiscoveryResponseBytes = 1024 * 1024;
const int maxDiscoveredModels = 2000;
const Duration defaultDiscoveryTimeout = Duration(seconds: 15);

final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');
const _invalidResponse =
    SaluAssistantException(SaluAssistantErrorCode.invalidResponse);
const _requestRejected =
    SaluAssistantException(SaluAssistantErrorCode.requestRejected);

const Set<String> _unsupportedPaginationKeys = <String>{
  'next_cursor',
  'nextCursor',
  'next_page',
  'nextPage',
  'next_page_token',
  'nextPageToken',
  'page_token',
  'pageToken',
  'cursor',
  'next_token',
};

/// A validated model identifier and display name returned by explicit model
/// discovery. Does not imply image capability.
final class DiscoveredModel {
  const DiscoveredModel({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredModel && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'DiscoveredModel(id: $id, name: $name)';
}

/// Fetches available models via explicit `GET` against `models` or `catalogue`
/// under [profile.apiRoot]. Never guesses alternate paths or probes with POST.
Future<List<DiscoveredModel>> discoverModels(
  EndpointProfile profile,
  CredentialStore credentials,
  EndpointTransport transport,
  OperationFence fence, {
  Duration timeout = defaultDiscoveryTimeout,
}) async {
  final relativePath = switch (profile.discovery) {
    ModelDiscoveryMode.models => 'models',
    ModelDiscoveryMode.catalogue => 'catalogue',
    ModelDiscoveryMode.manual => throw _requestRejected,
  };

  final epoch = fence.capture();
  final stopwatch = Stopwatch()..start();
  Duration remaining() {
    final left = timeout - stopwatch.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  final baseUri = endpointUri(profile.apiRoot, relativePath);

  final String? secret;
  try {
    secret = await credentials.read(profile.credentialRef);
  } on Object {
    if (!fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    throw const SaluAssistantException(
      SaluAssistantErrorCode.storageUnavailable,
    );
  }

  if (!fence.isCurrent(epoch)) {
    throw const SaluAssistantException(
      SaluAssistantErrorCode.connectionChanged,
    );
  }
  if (secret == null || secret.trim().isEmpty) {
    throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
  }
  final normalizedSecret = secret.trim();
  final headers = protocolAuthHeaders(profile.protocol, normalizedSecret);

  final byId = <String, DiscoveredModel>{};
  final visitedUris = <String>{};
  final seenCursors = <String>{};

  Uri? currentUri = baseUri;
  for (var page = 0; page < maxDiscoveryPages && currentUri != null; page++) {
    if (!fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }
    final budget = remaining();
    if (budget <= Duration.zero) {
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    }
    if (!visitedUris.add(currentUri.toString())) {
      throw _invalidResponse;
    }

    final envelope = await transport.send(
      uri: currentUri,
      method: 'GET',
      headers: headers,
      allowInsecureLocal: profile.allowInsecureLocal,
      fence: fence,
      maxBytes: maxDiscoveryResponseBytes,
      deadline: budget,
      epoch: epoch,
    );

    if (!fence.isCurrent(epoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final parsedItems = _parsePageItems(
      envelope,
      profile.discovery,
      normalizedSecret,
    );
    for (final item in parsedItems) {
      if (byId.containsKey(item.id)) {
        continue;
      }
      if (byId.length >= maxDiscoveredModels) {
        return List<DiscoveredModel>.unmodifiable(byId.values);
      }
      byId[item.id] = item;
    }

    if (byId.length >= maxDiscoveredModels) {
      break;
    }

    currentUri = _resolveNextPageUri(
      root: profile.apiRoot,
      baseUri: baseUri,
      currentUri: currentUri,
      envelope: envelope,
      seenCursors: seenCursors,
    );
  }

  return List<DiscoveredModel>.unmodifiable(byId.values);
}

List<DiscoveredModel> _parsePageItems(
  Map<String, dynamic> envelope,
  ModelDiscoveryMode mode,
  String secret,
) {
  final List<Object?> rawItems;
  final String nameKey;

  switch (mode) {
    case ModelDiscoveryMode.models:
      final data = envelope['data'];
      if (data is! List<Object?>) {
        throw _invalidResponse;
      }
      rawItems = data;
      nameKey = 'display_name';
    case ModelDiscoveryMode.catalogue:
      final hasData = envelope['data'] != null;
      final hasModels = envelope['models'] != null;
      if (hasData == hasModels) {
        throw _invalidResponse;
      }
      if (hasData) {
        final data = envelope['data'];
        if (data is! List<Object?>) {
          throw _invalidResponse;
        }
        rawItems = data;
        nameKey = 'display_name';
      } else {
        final models = envelope['models'];
        if (models is! List<Object?>) {
          throw _invalidResponse;
        }
        rawItems = models;
        nameKey = 'name';
      }
    case ModelDiscoveryMode.manual:
      throw _requestRejected;
  }

  final items = <DiscoveredModel>[];
  for (final rawItem in rawItems) {
    if (rawItem is! Map) {
      throw _invalidResponse;
    }
    final rawId = rawItem['id'];
    if (rawId is! String ||
        _controlChars.hasMatch(rawId) ||
        rawId.trim() != rawId ||
        rawId.isEmpty ||
        rawId.length > EndpointProfile.maxModelIdLength ||
        rawId.contains(secret)) {
      throw _invalidResponse;
    }

    final rawName = rawItem[nameKey];
    if (rawName != null && rawName is! String) {
      throw _invalidResponse;
    }
    final String effectiveName;
    if (rawName is String) {
      if (_controlChars.hasMatch(rawName) || rawName.contains(secret)) {
        throw _invalidResponse;
      }
      final trimmedName = rawName.trim();
      effectiveName = trimmedName.isEmpty ? rawId : trimmedName;
    } else {
      effectiveName = rawId;
    }

    items.add(DiscoveredModel(id: rawId, name: effectiveName));
  }
  return items;
}

Uri? _resolveNextPageUri({
  required Uri root,
  required Uri baseUri,
  required Uri currentUri,
  required Map<String, dynamic> envelope,
  required Set<String> seenCursors,
}) {
  final rawHasMore = envelope['has_more'];
  if (rawHasMore != null && rawHasMore is! bool) {
    throw _invalidResponse;
  }
  final rawNext = envelope['next'];
  if (rawNext != null && rawNext is! String) {
    throw _invalidResponse;
  }

  for (final key in _unsupportedPaginationKeys) {
    if (envelope[key] != null) {
      throw _invalidResponse;
    }
  }
  final links = envelope['links'];
  if (links != null) {
    if (links is! Map || links['next'] != null) {
      throw _invalidResponse;
    }
  }

  if (rawNext is String && rawNext.trim().isNotEmpty) {
    return _validateNextPageUri(root, currentUri, rawNext);
  }

  if (rawHasMore == true) {
    final lastId = envelope['last_id'];
    if (lastId is! String ||
        _controlChars.hasMatch(lastId) ||
        lastId.trim() != lastId ||
        lastId.isEmpty ||
        lastId.length > EndpointProfile.maxModelIdLength) {
      throw _invalidResponse;
    }
    if (!seenCursors.add(lastId)) {
      throw _invalidResponse;
    }
    final queryParams = Map<String, String>.from(baseUri.queryParameters);
    queryParams['after_id'] = lastId;
    final nextUri = baseUri.replace(queryParameters: queryParams);
    if (!isUriUnderRootPrefix(root, nextUri)) {
      throw _invalidResponse;
    }
    return nextUri;
  }

  return null;
}

Uri _validateNextPageUri(Uri root, Uri currentUri, String rawNext) {
  if (rawNext.isEmpty ||
      rawNext.trim() != rawNext ||
      _controlChars.hasMatch(rawNext) ||
      rawNext.startsWith('//') ||
      rawNext.contains('\\') ||
      rawNext.contains('#')) {
    throw _invalidResponse;
  }

  final Uri parsed;
  try {
    parsed = Uri.parse(rawNext);
  } on FormatException {
    throw _invalidResponse;
  }
  if ((parsed.hasAuthority && !parsed.hasScheme) ||
      parsed.userInfo.isNotEmpty ||
      parsed.authority.contains('@') ||
      parsed.authority.toLowerCase().contains('%40') ||
      parsed.hasFragment) {
    throw _invalidResponse;
  }

  for (final segment in parsed.pathSegments) {
    if (segment == '.' || segment == '..') {
      throw _invalidResponse;
    }
    final String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } on ArgumentError {
      throw _invalidResponse;
    }
    if (decoded == '.' ||
        decoded == '..' ||
        decoded.contains('\\') ||
        _controlChars.hasMatch(decoded)) {
      throw _invalidResponse;
    }
  }

  final resolved = parsed.hasScheme ? parsed : currentUri.resolveUri(parsed);
  if (!isUriUnderRootPrefix(root, resolved)) {
    throw _invalidResponse;
  }
  final rootSegments =
      root.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  final resolvedSegments =
      resolved.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (resolvedSegments.length <= rootSegments.length) {
    throw _invalidResponse;
  }
  return resolved;
}
