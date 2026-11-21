import 'package:salu_core/salu_core.dart';

import 'local_document_store.dart';

/// Persistence for named endpoint connection profiles and active selection.
final class EndpointProfilesStore {
  const EndpointProfilesStore(this.documents);

  static const int currentVersion = 1;
  static const String documentId = 'endpoint-connections';

  final LocalDocumentStore documents;

  Future<({int revision, List<EndpointProfile> profiles, String? activeId})>
      load() async {
    final record = await documents.read(documentId);
    if (record == null) {
      return (
        revision: 0,
        profiles: const <EndpointProfile>[],
        activeId: null,
      );
    }

    final data = record.data;
    final version = data['version'];
    if (version != currentVersion) {
      throw FormatException(
        'Unsupported endpoint-connections version: $version',
        version,
      );
    }

    final rawActiveId = data['activeId'];
    if (rawActiveId != null && rawActiveId is! String) {
      throw FormatException(
          'Invalid activeId in endpoint-connections', rawActiveId);
    }

    final rawProfiles = data['profiles'];
    if (rawProfiles is! List<Object?>) {
      throw FormatException(
        'Invalid profiles list in endpoint-connections',
        rawProfiles,
      );
    }

    final profiles = <EndpointProfile>[];
    final ids = <String>{};
    for (final rawItem in rawProfiles) {
      if (rawItem is! Map) {
        throw FormatException('Invalid endpoint profile entry', rawItem);
      }
      final profile = EndpointProfile.fromJson(
        Map<String, dynamic>.from(rawItem),
      );
      if (!ids.add(profile.id)) {
        throw FormatException(
          'Duplicate endpoint profile id: ${profile.id}',
          profile.id,
        );
      }
      profiles.add(profile);
    }

    final activeId = rawActiveId as String?;
    _validateActiveId(activeId, ids);

    return (
      revision: record.revision,
      profiles: List<EndpointProfile>.unmodifiable(profiles),
      activeId: activeId,
    );
  }

  Future<bool> save({
    required int expectedRevision,
    required List<EndpointProfile> profiles,
    required String? activeId,
  }) async {
    if (expectedRevision < 0) {
      throw ArgumentError.value(
        expectedRevision,
        'expectedRevision',
        'must be non-negative',
      );
    }

    final ids = <String>{};
    for (final profile in profiles) {
      if (!ids.add(profile.id)) {
        throw FormatException(
          'Duplicate endpoint profile id: ${profile.id}',
          profile.id,
        );
      }
    }
    _validateActiveId(activeId, ids);

    return documents.put(documentId, expectedRevision, {
      'version': currentVersion,
      'activeId': activeId,
      'profiles': [for (final profile in profiles) profile.toJson()],
    });
  }

  static void _validateActiveId(String? activeId, Set<String> profileIds) {
    if (activeId == null || activeId == EndpointProfile.reservedChatGptId) {
      return;
    }
    if (!profileIds.contains(activeId)) {
      throw FormatException(
        'Invalid active endpoint profile id: $activeId',
        activeId,
      );
    }
  }
}
