import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../assistant/assistant.dart';
import '../../assistant/credential_store.dart';
import '../../assistant/endpoint_transport.dart';
import '../../assistant/model_discovery.dart';
import '../../assistant/operation_fence.dart';

typedef DiscoverModelsCallback = Future<List<DiscoveredModel>> Function(
  EndpointProfile profile,
  CredentialStore credentials,
  EndpointTransport transport,
  OperationFence fence,
);

enum ConnectionCheckOutcome { untested, available, unavailable }

final class ConnectionStatus {
  const ConnectionStatus({
    this.outcome = ConnectionCheckOutcome.untested,
    this.message = 'Not tested',
    this.errorCode,
  });

  final ConnectionCheckOutcome outcome;
  final String message;
  final SaluAssistantErrorCode? errorCode;
}

/// Coordinates nonsecret [EndpointProfile] persistence with staged
/// [CredentialStore] slot writes, rotation, removal, and bounded discovery/test
/// checks.
class ConnectionsController extends ChangeNotifier {
  ConnectionsController(
    this._profilesStore,
    this._credentials, {
    EndpointTransport? transport,
    OperationFence? fence,
    DiscoverModelsCallback? discoverModelsCallback,
    Future<bool> Function()? isChatGptConnected,
    Future<void> Function()? signInChatGpt,
    Future<void> Function()? signOutChatGpt,
    void Function()? onInvalidate,
  })  : _transport = transport,
        _fence = fence,
        _discoverModels = discoverModelsCallback ?? discoverModels,
        _isChatGptConnected = isChatGptConnected,
        _signInChatGpt = signInChatGpt,
        _signOutChatGpt = signOutChatGpt,
        _onInvalidate = onInvalidate;

  final EndpointProfilesStore _profilesStore;
  final CredentialStore _credentials;
  EndpointTransport? _transport;
  OperationFence? _fence;
  final DiscoverModelsCallback _discoverModels;
  final Future<bool> Function()? _isChatGptConnected;
  final Future<void> Function()? _signInChatGpt;
  final Future<void> Function()? _signOutChatGpt;
  final void Function()? _onInvalidate;

  List<EndpointProfile> _profiles = const <EndpointProfile>[];
  String? _activeId;
  int _revision = 0;
  bool _loaded = false;
  bool _chatGptConnected = false;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();
  final Set<String> _busyIds = <String>{};
  final Map<String, List<DiscoveredModel>> _discoveredModels =
      <String, List<DiscoveredModel>>{};
  final Map<String, ConnectionStatus> _statuses = <String, ConnectionStatus>{};

  List<EndpointProfile> get profiles => _profiles;
  String? get activeId => _activeId;
  int get revision => _revision;
  bool get loaded => _loaded;
  bool get chatGptConnected => _chatGptConnected;
  bool get anyBusy => _busyIds.isNotEmpty;
  bool isBusy(String id) => _busyIds.contains(id);

  EndpointProfile? get activeProfile {
    final id = _activeId;
    if (id == null || id == EndpointProfile.reservedChatGptId) return null;
    return _findById(_profiles, id);
  }

  List<DiscoveredModel> discoveredModelsFor(String id) =>
      _discoveredModels[id] ?? const <DiscoveredModel>[];

  ConnectionStatus statusFor(String id) =>
      _statuses[id] ?? const ConnectionStatus();

  EndpointTransport get _effectiveTransport =>
      _transport ??= EndpointTransport();
  OperationFence get _effectiveFence => _fence ??= OperationFence();

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

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Reloads endpoint profiles, active selection, and ChatGPT session state.
  Future<void> load() => _serialized(() async {
        final state = await _profilesStore.load();
        final chatGpt =
            await (_isChatGptConnected?.call() ?? Future<bool>.value(false));
        _revision = state.revision;
        _profiles = state.profiles;
        _activeId = state.activeId;
        _chatGptConnected = chatGpt;
        _loaded = true;
        _notify();
      });

  Future<bool> hasCredential(String id) async {
    final profile = _findById(_profiles, id);
    if (profile == null) return false;
    try {
      final secret = await _credentials.read(profile.credentialRef);
      return secret != null && secret.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// Creates or updates [profile].
  ///
  /// New profiles and destination (origin/protocol) changes require [newKey].
  /// Credential slots are staged before the profile document commit and rolled
  /// back (or left for deferred cleanup) if the commit fails.
  Future<void> saveProfile(EndpointProfile profile, {String? newKey}) {
    final normalizedKey =
        newKey == null ? null : SecureCredentialStore.validateSecret(newKey);

    return _serialized(() async {
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
        final nextSlot =
            _nextCredentialRef(profile.id, existing?.credentialRef);
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
          throw StateError(
              'Endpoint profiles changed concurrently; retry save.');
        }

        if (existing != null && existing.credentialRef != nextSlot) {
          await _bestEffortDeleteCredential(existing.credentialRef);
        }

        _revision = current.revision + 1;
        _profiles = List<EndpointProfile>.unmodifiable(nextProfiles);
        _activeId = current.activeId;
        _loaded = true;
        if (existing != null &&
            (!existing.hasSameDestination(profile) ||
                existing.discovery != profile.discovery)) {
          _discoveredModels.remove(profile.id);
          _statuses.remove(profile.id);
        }
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
      _loaded = true;
      if (existing.discovery != profile.discovery) {
        _discoveredModels.remove(profile.id);
        _statuses.remove(profile.id);
      }
      _notify();
    });
  }

  /// Invalidates in-flight operations, removes [id] from storage, then cleans
  /// up its credential slot.
  Future<void> removeProfile(String id) => _serialized(() async {
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
          throw StateError(
              'Endpoint profiles changed concurrently; retry remove.');
        }

        await _bestEffortDeleteCredential(target.credentialRef);

        _revision = current.revision + 1;
        _profiles = List<EndpointProfile>.unmodifiable(nextProfiles);
        _activeId = nextActiveId;
        _loaded = true;
        _discoveredModels.remove(id);
        _statuses.remove(id);
        _notify();
      });

  /// Invalidates in-flight operations when changing selection and persists
  /// [id] (`null`, `'chatgpt-plan'`, or an existing profile id).
  Future<void> select(String? id) => _serialized(() async {
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
          throw StateError(
              'Endpoint profiles changed concurrently; retry select.');
        }

        _revision = current.revision + 1;
        _profiles = current.profiles;
        _activeId = id;
        _loaded = true;
        _notify();
      });

  /// Explicitly discovers models via bounded GET requests for profile [id].
  Future<List<DiscoveredModel>> discover(String id) async {
    _busyIds.add(id);
    _notify();
    try {
      final current = await _profilesStore.load();
      final profile = _findById(current.profiles, id);
      if (profile == null) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }

      final models = await _discoverModels(
        profile,
        _credentials,
        _effectiveTransport,
        _effectiveFence,
      );
      _discoveredModels[id] = models;
      _statuses[id] = ConnectionStatus(
        outcome: ConnectionCheckOutcome.available,
        message:
            'Discovered ${models.length} ${models.length == 1 ? 'model' : 'models'}. '
            'Generation and image input are not verified.',
      );
      return models;
    } on SaluAssistantException catch (error) {
      _statuses[id] = ConnectionStatus(
        outcome: ConnectionCheckOutcome.unavailable,
        message: error.message,
        errorCode: error.code,
      );
      rethrow;
    } on Object {
      _statuses[id] = const ConnectionStatus(
        outcome: ConnectionCheckOutcome.unavailable,
        message: 'Model discovery failed. Check your endpoint and credentials.',
      );
      rethrow;
    } finally {
      _busyIds.remove(id);
      _notify();
    }
  }

  /// Runs a bounded credential/discovery availability check for [id].
  ///
  /// Never sends a generation POST request and explicitly discloses that
  /// generation and image input are not verified.
  Future<void> testConnection(String id) async {
    _busyIds.add(id);
    _notify();
    try {
      if (id == EndpointProfile.reservedChatGptId) {
        final connected =
            await (_isChatGptConnected?.call() ?? Future<bool>.value(false));
        _chatGptConnected = connected;
        if (!connected) {
          throw const SaluAssistantException(
            SaluAssistantErrorCode.notConnected,
          );
        }
        _statuses[id] = const ConnectionStatus(
          outcome: ConnectionCheckOutcome.available,
          message:
              'ChatGPT session saved locally. Generation and image input are not verified.',
        );
        return;
      }

      final current = await _profilesStore.load();
      final profile = _findById(current.profiles, id);
      if (profile == null) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }

      final String? secret;
      try {
        secret = await _credentials.read(profile.credentialRef);
      } on Object {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.storageUnavailable,
        );
      }
      if (secret == null || secret.trim().isEmpty) {
        throw const SaluAssistantException(SaluAssistantErrorCode.notConnected);
      }

      if (profile.discovery == ModelDiscoveryMode.manual) {
        final modelId = profile.modelId?.trim() ?? '';
        if (modelId.isEmpty) {
          throw const SaluAssistantException(
            SaluAssistantErrorCode.requestRejected,
          );
        }
        _statuses[id] = ConnectionStatus(
          outcome: ConnectionCheckOutcome.available,
          message: 'Credentials saved locally for manual model "$modelId". '
              'Endpoint reachability, generation, and image input are not verified.',
        );
        return;
      }

      final models = await _discoverModels(
        profile,
        _credentials,
        _effectiveTransport,
        _effectiveFence,
      );
      _discoveredModels[id] = models;
      _statuses[id] = ConnectionStatus(
        outcome: ConnectionCheckOutcome.available,
        message:
            'Credentials present and ${models.length} ${models.length == 1 ? 'model' : 'models'} reachable. '
            'Generation and image input are not verified.',
      );
    } on SaluAssistantException catch (error) {
      _statuses[id] = ConnectionStatus(
        outcome: ConnectionCheckOutcome.unavailable,
        message: error.message,
        errorCode: error.code,
      );
      rethrow;
    } on Object {
      _statuses[id] = const ConnectionStatus(
        outcome: ConnectionCheckOutcome.unavailable,
        message:
            'Connection check failed. Generation and image input are not verified.',
      );
      rethrow;
    } finally {
      _busyIds.remove(id);
      _notify();
    }
  }

  /// Signs into ChatGPT if configured, leaving previous state intact on failure.
  Future<void> connectChatGpt() async {
    _busyIds.add(EndpointProfile.reservedChatGptId);
    _notify();
    try {
      _onInvalidate?.call();
      final signIn = _signInChatGpt;
      if (signIn == null) {
        throw StateError('ChatGPT sign-in is not configured.');
      }
      await signIn();
      _chatGptConnected =
          await (_isChatGptConnected?.call() ?? Future<bool>.value(true));
      if (_chatGptConnected) {
        _statuses[EndpointProfile.reservedChatGptId] = const ConnectionStatus(
          outcome: ConnectionCheckOutcome.available,
          message:
              'ChatGPT session saved locally. Generation and image input are not verified.',
        );
      }
    } finally {
      _busyIds.remove(EndpointProfile.reservedChatGptId);
      _notify();
    }
  }

  /// Disconnects ChatGPT and clears active selection if ChatGPT was selected.
  Future<void> disconnectChatGpt() async {
    _busyIds.add(EndpointProfile.reservedChatGptId);
    _notify();
    try {
      _onInvalidate?.call();
      final current = await _profilesStore.load();
      if (current.activeId == EndpointProfile.reservedChatGptId) {
        await _profilesStore.save(
          expectedRevision: current.revision,
          profiles: current.profiles,
          activeId: null,
        );
        _revision = current.revision + 1;
        _activeId = null;
      }
      await _signOutChatGpt?.call();
      _chatGptConnected =
          await (_isChatGptConnected?.call() ?? Future<bool>.value(false));
      _statuses.remove(EndpointProfile.reservedChatGptId);
    } finally {
      _busyIds.remove(EndpointProfile.reservedChatGptId);
      _notify();
    }
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
