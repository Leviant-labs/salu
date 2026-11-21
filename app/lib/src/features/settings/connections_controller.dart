import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../assistant/credential_store.dart';

/// Coordinates nonsecret [EndpointProfile] persistence with staged
/// [CredentialStore] slot writes, rotation, and removal.
class ConnectionsController extends ChangeNotifier {
  ConnectionsController(
    this._profilesStore,
    this._credentials, {
    void Function()? onInvalidate,
  }) : _onInvalidate = onInvalidate;

  final EndpointProfilesStore _profilesStore;
  final CredentialStore _credentials;
  final void Function()? _onInvalidate;

  List<EndpointProfile> _profiles = const <EndpointProfile>[];
  String? _activeId;
  int _revision = 0;
  bool _disposed = false;

  List<EndpointProfile> get profiles => _profiles;
  String? get activeId => _activeId;
  int get revision => _revision;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Reloads endpoint profiles and active selection from storage.
  Future<void> load() async {
    final state = await _profilesStore.load();
    _revision = state.revision;
    _profiles = state.profiles;
    _activeId = state.activeId;
    _notify();
  }

  /// Creates or updates [profile].
  ///
  /// New profiles and destination (origin/protocol) changes require [newKey].
  /// Credential slots are staged before the profile document commit and rolled
  /// back (or left for deferred cleanup) if the commit fails.
  Future<void> saveProfile(EndpointProfile profile, {String? newKey}) async {
    final normalizedKey =
        newKey == null ? null : SecureCredentialStore.validateSecret(newKey);

    final current = await _profilesStore.load();
    final existing = _findById(current.profiles, profile.id);

    if (existing == null && normalizedKey == null) {
      throw StateError('An API key is required for a new endpoint profile.');
    }
    if (existing != null &&
        !existing.hasSameDestination(profile) &&
        normalizedKey == null) {
      throw StateError(
        'A new API key is required when changing the endpoint origin or protocol.',
      );
    }

    if (existing != null &&
        (!existing.hasSameDestination(profile) ||
            normalizedKey != null ||
            current.activeId == profile.id)) {
      _onInvalidate?.call();
    }

    if (normalizedKey != null) {
      final nextSlot = _nextCredentialRef(profile.id, existing?.credentialRef);
      await _credentials.write(nextSlot, normalizedKey);

      final updated = profile.copyWith(credentialRef: nextSlot);
      final nextProfiles = _upsertProfile(current.profiles, updated);

      final bool saved;
      try {
        saved = await _profilesStore.save(
          expectedRevision: current.revision,
          profiles: nextProfiles,
          activeId: current.activeId,
        );
      } catch (_) {
        await _bestEffortDeleteCredential(nextSlot);
        rethrow;
      }

      if (!saved) {
        await _bestEffortDeleteCredential(nextSlot);
        throw StateError('Endpoint profiles changed concurrently; retry save.');
      }

      if (existing != null && existing.credentialRef != nextSlot) {
        await _bestEffortDeleteCredential(existing.credentialRef);
      }

      _revision = current.revision + 1;
      _profiles = List<EndpointProfile>.unmodifiable(nextProfiles);
      _activeId = current.activeId;
      _notify();
      return;
    }

    // Same destination without key rotation: preserve the existing slot.
    final updated = profile.copyWith(credentialRef: existing!.credentialRef);
    final nextProfiles = _upsertProfile(current.profiles, updated);
    final saved = await _profilesStore.save(
      expectedRevision: current.revision,
      profiles: nextProfiles,
      activeId: current.activeId,
    );
    if (!saved) {
      throw StateError('Endpoint profiles changed concurrently; retry save.');
    }

    _revision = current.revision + 1;
    _profiles = List<EndpointProfile>.unmodifiable(nextProfiles);
    _activeId = current.activeId;
    _notify();
  }

  /// Invalidates in-flight operations, removes [id] from storage, then cleans
  /// up its credential slot.
  Future<void> removeProfile(String id) async {
    final current = await _profilesStore.load();
    final target = _findById(current.profiles, id);
    if (target == null) return;

    _onInvalidate?.call();

    final nextProfiles =
        current.profiles.where((p) => p.id != id).toList(growable: false);
    final nextActiveId = current.activeId == id ? null : current.activeId;
    final saved = await _profilesStore.save(
      expectedRevision: current.revision,
      profiles: nextProfiles,
      activeId: nextActiveId,
    );
    if (!saved) {
      throw StateError('Endpoint profiles changed concurrently; retry remove.');
    }

    await _bestEffortDeleteCredential(target.credentialRef);

    _revision = current.revision + 1;
    _profiles = List<EndpointProfile>.unmodifiable(nextProfiles);
    _activeId = nextActiveId;
    _notify();
  }

  /// Invalidates in-flight operations when changing selection and persists
  /// [id] (`null`, `'chatgpt-plan'`, or an existing profile id).
  Future<void> select(String? id) async {
    final current = await _profilesStore.load();
    if (id != null &&
        id != EndpointProfile.reservedChatGptId &&
        _findById(current.profiles, id) == null) {
      throw FormatException('Unknown endpoint profile id: $id', id);
    }

    if (current.activeId != id) {
      _onInvalidate?.call();
    }

    final saved = await _profilesStore.save(
      expectedRevision: current.revision,
      profiles: current.profiles,
      activeId: id,
    );
    if (!saved) {
      throw StateError('Endpoint profiles changed concurrently; retry select.');
    }

    _revision = current.revision + 1;
    _profiles = current.profiles;
    _activeId = id;
    _notify();
  }

  Future<void> _bestEffortDeleteCredential(String ref) async {
    try {
      await _credentials.delete(ref);
    } catch (_) {
      // SecureCredentialStore schedules deferred cleanup in its manifest.
    }
  }

  static EndpointProfile? _findById(
    List<EndpointProfile> profiles,
    String id,
  ) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  static List<EndpointProfile> _upsertProfile(
    List<EndpointProfile> profiles,
    EndpointProfile updated,
  ) {
    final result = <EndpointProfile>[];
    var replaced = false;
    for (final profile in profiles) {
      if (profile.id == updated.id) {
        result.add(updated);
        replaced = true;
      } else {
        result.add(profile);
      }
    }
    if (!replaced) {
      result.add(updated);
    }
    return result;
  }

  static String _nextCredentialRef(String profileId, String? previousRef) {
    final prefix = 'salu.endpoint.$profileId.';
    var generation = 1;
    if (previousRef != null && previousRef.startsWith(prefix)) {
      final parsed = int.tryParse(previousRef.substring(prefix.length));
      if (parsed != null && parsed >= 1) {
        generation = parsed + 1;
      }
    }
    var candidate = '$prefix$generation';
    if (candidate == previousRef) {
      candidate = '$prefix${generation + 1}';
    }
    return candidate;
  }
}
