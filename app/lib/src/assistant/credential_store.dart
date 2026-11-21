import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage port for opaque `salu.*` credential slots.
abstract interface class CredentialStore {
  Future<String?> read(String ref);
  Future<void> write(String ref, String secret);
  Future<void> delete(String ref);
  Future<void> clearSaluCredentials();
}

/// Minimal key-value secure storage adapter so [SecureCredentialStore] can be
/// tested in memory without platform plugins.
abstract interface class SecureKeyValueStorage {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
  Future<Map<String, String>> readAll();
}

/// Production [SecureKeyValueStorage] backed by [FlutterSecureStorage].
final class FlutterSecureStorageAdapter implements SecureKeyValueStorage {
  const FlutterSecureStorageAdapter([
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  ]) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// Secure-storage credential store enforcing `salu.*` slot boundaries and
/// maintaining a secret-free manifest for dynamic slot tracking and deferred
/// cleanup.
final class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({SecureKeyValueStorage? storage})
      : _storage = storage ?? const FlutterSecureStorageAdapter();

  static const String manifestKey = 'salu.endpoint.manifest.v1';
  static const int manifestVersion = 1;
  static const String slotPrefix = 'salu.';
  static const int maxRefLength = 256;
  static const int maxSecretLength = 4096;

  /// Pre-existing `salu.*` slots outside dynamic endpoint profiles.
  static const List<String> legacySaluKeys = <String>[
    'salu.assistant.openai.api_key',
    'salu.chatgpt.session.v1',
    'salu.chatgpt.host.v1',
    'salu.chatgpt.welcome',
  ];

  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');
  static final RegExp _whitespace = RegExp(r'\s');

  final SecureKeyValueStorage _storage;
  Future<void> _tail = Future<void>.value();

  /// Validates a credential slot reference.
  static void validateRef(String ref) {
    if (!ref.startsWith(slotPrefix) ||
        ref.length <= slotPrefix.length ||
        ref.length > maxRefLength ||
        ref == manifestKey ||
        _controlChars.hasMatch(ref) ||
        _whitespace.hasMatch(ref)) {
      throw ArgumentError(
        'Credential reference must start with "$slotPrefix" without spaces or control characters.',
      );
    }
  }

  /// Validates and trims a secret key without echoing secret material in errors.
  static String validateSecret(String secret) {
    if (_controlChars.hasMatch(secret)) {
      throw ArgumentError(
          'Credential secret cannot contain control characters.');
    }
    final trimmed = secret.trim();
    if (trimmed.isEmpty || trimmed.length > maxSecretLength) {
      throw ArgumentError(
        'Credential secret must be 1..$maxSecretLength characters.',
      );
    }
    return trimmed;
  }

  @override
  Future<String?> read(String ref) {
    validateRef(ref);
    return _storage.read(key: ref);
  }

  @override
  Future<void> write(String ref, String secret) {
    validateRef(ref);
    final normalized = validateSecret(secret);
    return _serialized(() async {
      final manifest = await _readManifest();
      manifest.owned.add(ref);
      manifest.pendingDelete.remove(ref);
      await _writeManifest(manifest);

      try {
        await _storage.write(key: ref, value: normalized);
      } catch (_) {
        manifest.owned.remove(ref);
        manifest.pendingDelete.add(ref);
        await _bestEffortWriteManifest(manifest);
        rethrow;
      }

      await _flushPendingDeletesInManifest(manifest, exclude: ref);
    });
  }

  @override
  Future<void> delete(String ref) {
    validateRef(ref);
    return _serialized(() async {
      final manifest = await _bestEffortReadManifest();
      try {
        await _storage.delete(key: ref);
      } catch (_) {
        manifest.owned.remove(ref);
        manifest.pendingDelete.add(ref);
        await _bestEffortWriteManifest(manifest);
        rethrow;
      }

      final changed =
          manifest.owned.remove(ref) | manifest.pendingDelete.remove(ref);
      final flushed = await _flushPendingDeletesInManifest(
        manifest,
        saveWhenUnchanged: changed,
      );
      if (!flushed && changed) {
        await _bestEffortWriteManifest(manifest);
      }
    });
  }

  /// Retries deleting any slots previously recorded for deferred cleanup.
  Future<void> flushPendingDeletes() => _serialized(() async {
        final manifest = await _readManifest();
        if (manifest.pendingDelete.isEmpty) return;
        await _flushPendingDeletesInManifest(manifest);
      });

  @override
  Future<void> clearSaluCredentials() => _serialized(() async {
        final manifest = await _bestEffortReadManifest();
        final targets = <String>{
          ...manifest.owned,
          ...manifest.pendingDelete,
          ...legacySaluKeys,
        };

        try {
          final all = await _storage.readAll();
          for (final key in all.keys) {
            if (key.startsWith(slotPrefix) && key != manifestKey) {
              targets.add(key);
            }
          }
        } catch (_) {
          // Explicit manifest + legacy key deletion remains intact if readAll fails.
        }

        final failedSlots = <String>{};
        Object? firstError;
        StackTrace? firstTrace;
        for (final key in targets) {
          try {
            await _storage.delete(key: key);
          } catch (error, stackTrace) {
            failedSlots.add(key);
            firstError ??= error;
            firstTrace ??= stackTrace;
          }
        }

        if (failedSlots.isNotEmpty) {
          await _bestEffortWriteManifest(
            _CredentialManifest(
              owned: <String>{},
              pendingDelete: failedSlots,
            ),
          );
          Error.throwWithStackTrace(firstError!, firstTrace!);
        }

        await _storage.delete(key: manifestKey);
      });

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<_CredentialManifest> _readManifest() async {
    final raw = await _storage.read(key: manifestKey);
    if (raw == null || raw.isEmpty) {
      return _CredentialManifest.empty();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Invalid credential manifest structure');
    }
    if (decoded['version'] != manifestVersion) {
      throw FormatException(
        'Unsupported credential manifest version: ${decoded['version']}',
      );
    }
    return _CredentialManifest(
      owned: _readStringSet(decoded['owned']),
      pendingDelete: _readStringSet(decoded['pendingDelete']),
    );
  }

  Future<_CredentialManifest> _bestEffortReadManifest() async {
    try {
      return await _readManifest();
    } catch (_) {
      return _CredentialManifest.empty();
    }
  }

  Future<void> _writeManifest(_CredentialManifest manifest) async {
    await _storage.write(
      key: manifestKey,
      value: jsonEncode(manifest.toJson()),
    );
  }

  Future<void> _bestEffortWriteManifest(_CredentialManifest manifest) async {
    try {
      await _writeManifest(manifest);
    } catch (_) {
      // Preserve primary caller failure.
    }
  }

  Future<bool> _flushPendingDeletesInManifest(
    _CredentialManifest manifest, {
    String? exclude,
    bool saveWhenUnchanged = false,
  }) async {
    var changed = false;
    final candidates = manifest.pendingDelete
        .where((slot) => slot != exclude)
        .toList(growable: false);
    for (final slot in candidates) {
      try {
        await _storage.delete(key: slot);
        manifest.pendingDelete.remove(slot);
        changed = true;
      } catch (_) {
        // Keep in pendingDelete for a future retry.
      }
    }
    if (changed || saveWhenUnchanged) {
      await _bestEffortWriteManifest(manifest);
      return true;
    }
    return false;
  }

  static Set<String> _readStringSet(Object? raw) {
    if (raw == null) return <String>{};
    if (raw is! List) {
      throw const FormatException('Expected list in credential manifest');
    }
    final result = <String>{};
    for (final item in raw) {
      if (item is! String) {
        throw const FormatException('Expected string in credential manifest');
      }
      result.add(item);
    }
    return result;
  }
}

final class _CredentialManifest {
  _CredentialManifest({
    required this.owned,
    required this.pendingDelete,
  });

  factory _CredentialManifest.empty() => _CredentialManifest(
        owned: <String>{},
        pendingDelete: <String>{},
      );

  final Set<String> owned;
  final Set<String> pendingDelete;

  Map<String, Object?> toJson() {
    final sortedOwned = owned.toList()..sort();
    final sortedPending = pendingDelete.toList()..sort();
    return {
      'version': SecureCredentialStore.manifestVersion,
      'owned': sortedOwned,
      'pendingDelete': sortedPending,
    };
  }
}
