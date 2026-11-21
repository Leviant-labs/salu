import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/features/settings/connections_controller.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

const _testKey1 = 'sk-test-only-alpha-111111111111';
const _testKey2 = 'sk-test-only-bravo-222222222222';
const _testKey3 = 'sk-test-only-charlie-3333333333';

final class _MemorySecureStorage implements SecureKeyValueStorage {
  final Map<String, String> values = <String, String>{};
  bool failWrite = false;
  bool failDelete = false;
  bool failReadAll = false;
  Set<String> failDeleteForKeys = <String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    if (failWrite && key != SecureCredentialStore.manifestKey) {
      throw StateError('simulated secure write failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (failDelete || failDeleteForKeys.contains(key)) {
      throw StateError('simulated secure delete failure');
    }
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (failReadAll) {
      throw UnsupportedError('simulated readAll failure');
    }
    return Map<String, String>.from(values);
  }
}

final class _InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> slots = <String, String>{};
  bool failWrite = false;
  bool failDelete = false;

  @override
  Future<String?> read(String ref) async => slots[ref];

  @override
  Future<void> write(String ref, String secret) async {
    SecureCredentialStore.validateRef(ref);
    SecureCredentialStore.validateSecret(secret);
    if (failWrite) throw StateError('write failed');
    slots[ref] = secret;
  }

  @override
  Future<void> delete(String ref) async {
    SecureCredentialStore.validateRef(ref);
    if (failDelete) throw StateError('delete failed');
    slots.remove(ref);
  }

  @override
  Future<void> clearSaluCredentials() async {
    slots.removeWhere((key, _) => key.startsWith('salu.'));
  }
}

EndpointProfile _profile({
  String id = 'home',
  String name = 'Home server',
  EndpointProtocol protocol = EndpointProtocol.openaiChat,
  String apiRoot = 'https://inference.example/v1',
  String credentialRef = 'salu.endpoint.home.1',
  String? modelId = 'vision-test',
  bool allowInsecureLocal = false,
}) =>
    EndpointProfile(
      id: id,
      name: name,
      protocol: protocol,
      apiRoot: Uri.parse(apiRoot),
      credentialRef: credentialRef,
      modelId: modelId,
      allowInsecureLocal: allowInsecureLocal,
    );

void main() {
  test('SecureCredentialStore enforces salu.* refs and secret constraints',
      () async {
    final raw = _MemorySecureStorage();
    final store = SecureCredentialStore(storage: raw);

    for (final badRef in [
      '',
      'salu.',
      'openai.key',
      SecureCredentialStore.manifestKey,
      'salu.key\n',
      'salu.key with space',
    ]) {
      expect(
        () => store.write(badRef, _testKey1),
        throwsArgumentError,
        reason: 'expected ref rejection for "$badRef"',
      );
      expect(() => store.read(badRef), throwsArgumentError);
      expect(() => store.delete(badRef), throwsArgumentError);
    }

    for (final badSecret in [
      '',
      '   ',
      'sk-bad\r\nHeader: injected',
      'sk-bad\nline',
      'sk-bad\x00null',
      'k' * 4097,
    ]) {
      Object? caught;
      try {
        await store.write('salu.endpoint.home.1', badSecret);
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isArgumentError);
      final trimmed = badSecret.trim();
      if (trimmed.isNotEmpty) {
        expect(caught.toString(), isNot(contains(trimmed)));
      }
    }

    final maxSecret = 'k' * 4096;
    await store.write('salu.endpoint.home.1', maxSecret);
    expect(await store.read('salu.endpoint.home.1'), maxSecret);
  });

  test(
      'SecureCredentialStore manifest tracks dynamic slots without secrets and clears all salu.* keys even if readAll fails',
      () async {
    final raw = _MemorySecureStorage()
      ..values['salu.assistant.openai.api_key'] = _testKey1
      ..values['salu.chatgpt.session.v1'] = '{"refresh_token":"tok"}'
      ..values['salu.chatgpt.host.v1'] = 'urn:uuid:test'
      ..values['salu.chatgpt.welcome'] = 'shown'
      ..values['unrelated.other.key'] = 'keep-me';

    final store = SecureCredentialStore(storage: raw);
    await store.write('salu.endpoint.home.1', _testKey2);
    await store.write('salu.endpoint.work.1', _testKey3);

    final manifestJson = raw.values[SecureCredentialStore.manifestKey]!;
    expect(manifestJson, contains('salu.endpoint.home.1'));
    expect(manifestJson, contains('salu.endpoint.work.1'));
    expect(manifestJson, isNot(contains(_testKey1)));
    expect(manifestJson, isNot(contains(_testKey2)));
    expect(manifestJson, isNot(contains(_testKey3)));

    // Simulate readAll() unavailable on a platform: explicit manifest + legacy
    // keys must still be completely erased.
    raw.failReadAll = true;
    await store.clearSaluCredentials();

    for (final key in [
      ...SecureCredentialStore.legacySaluKeys,
      'salu.endpoint.home.1',
      'salu.endpoint.work.1',
      SecureCredentialStore.manifestKey,
    ]) {
      expect(raw.values.containsKey(key), isFalse,
          reason: '$key should be gone');
    }
    expect(raw.values['unrelated.other.key'], 'keep-me');
  });

  test('SecureCredentialStore records deferred cleanup on delete/write failure',
      () async {
    final raw = _MemorySecureStorage();
    final store = SecureCredentialStore(storage: raw);

    await store.write('salu.endpoint.home.1', _testKey1);
    raw.failDelete = true;
    await expectLater(store.delete('salu.endpoint.home.1'), throwsStateError);

    final manifestAfterFailedDelete = jsonDecode(
      raw.values[SecureCredentialStore.manifestKey]!,
    ) as Map<String, dynamic>;
    expect(
      manifestAfterFailedDelete['pendingDelete'],
      contains('salu.endpoint.home.1'),
    );
    expect(manifestAfterFailedDelete['owned'], isEmpty);

    // Recover delete and flush.
    raw.failDelete = false;
    await store.flushPendingDeletes();
    expect(raw.values.containsKey('salu.endpoint.home.1'), isFalse);
    final manifestAfterFlush = jsonDecode(
      raw.values[SecureCredentialStore.manifestKey]!,
    ) as Map<String, dynamic>;
    expect(manifestAfterFlush['pendingDelete'], isEmpty);

    // Failed write tracks slot in pendingDelete for cleanup without storing key.
    raw.failWrite = true;
    await expectLater(
      store.write('salu.endpoint.home.2', _testKey2),
      throwsStateError,
    );
    expect(raw.values.containsKey('salu.endpoint.home.2'), isFalse);
    final manifestAfterFailedWrite = jsonDecode(
      raw.values[SecureCredentialStore.manifestKey]!,
    ) as Map<String, dynamic>;
    expect(
      manifestAfterFailedWrite['pendingDelete'],
      contains('salu.endpoint.home.2'),
    );
    expect(
      raw.values[SecureCredentialStore.manifestKey]!,
      isNot(contains(_testKey2)),
    );
  });

  test(
      'ConnectionsController stages keys, blocks destination change without newKey, rotates slots, and never uses HttpClient',
      () async {
    await HttpOverrides.runZoned(
      () async {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
        final creds = _InMemoryCredentialStore();
        var invalidations = 0;
        final controller = ConnectionsController(
          profilesStore,
          creds,
          onInvalidate: () => invalidations++,
        );

        // Brand-new profile requires a key.
        await expectLater(
          controller.saveProfile(_profile()),
          throwsStateError,
        );
        expect((await profilesStore.load()).profiles, isEmpty);

        // Save brand-new profile with key -> writes salu.endpoint.home.1.
        await controller.saveProfile(_profile(), newKey: '  $_testKey1  ');
        expect(creds.slots['salu.endpoint.home.1'], _testKey1);

        var loaded = await profilesStore.load();
        expect(loaded.profiles, hasLength(1));
        expect(loaded.profiles.single.credentialRef, 'salu.endpoint.home.1');

        // Raw SQLite payload never contains the secret key.
        final rows = await db.select(db.localDocuments).get();
        expect(rows.single.payload, isNot(contains(_testKey1)));
        expect(loaded.profiles.single.toString(), isNot(contains(_testKey1)));

        // Select profile -> invokes onInvalidate before committing selection.
        await controller.select('home');
        expect(invalidations, 1);
        expect((await profilesStore.load()).activeId, 'home');

        // Updating metadata with the same origin/protocol preserves slot & key.
        await controller.saveProfile(
          _profile(name: 'Renamed Home', modelId: 'gpt-4.1'),
        );
        expect(invalidations, 2);
        expect(creds.slots['salu.endpoint.home.1'], _testKey1);
        loaded = await profilesStore.load();
        expect(loaded.profiles.single.name, 'Renamed Home');
        expect(loaded.profiles.single.modelId, 'gpt-4.1');

        // Changing host or protocol without newKey is rejected.
        await expectLater(
          controller.saveProfile(
            _profile(apiRoot: 'https://other.example/v1'),
          ),
          throwsStateError,
        );
        await expectLater(
          controller.saveProfile(
            _profile(protocol: EndpointProtocol.anthropicMessages),
          ),
          throwsStateError,
        );
        loaded = await profilesStore.load();
        expect(loaded.profiles.single.apiRoot.host, 'inference.example');
        expect(loaded.profiles.single.protocol, EndpointProtocol.openaiChat);

        // Changing destination WITH newKey rotates slot and retires old slot.
        await controller.saveProfile(
          _profile(
            protocol: EndpointProtocol.anthropicMessages,
            apiRoot: 'https://anthropic.example/v1',
          ),
          newKey: _testKey2,
        );
        expect(invalidations, 3);
        expect(creds.slots.containsKey('salu.endpoint.home.1'), isFalse);
        expect(creds.slots['salu.endpoint.home.2'], _testKey2);
        loaded = await profilesStore.load();
        expect(loaded.profiles.single.credentialRef, 'salu.endpoint.home.2');
        expect(
          loaded.profiles.single.protocol,
          EndpointProtocol.anthropicMessages,
        );

        // Remove profile -> invalidates, clears activeId, deletes credential.
        await controller.removeProfile('home');
        expect(invalidations, 4);
        loaded = await profilesStore.load();
        expect(loaded.profiles, isEmpty);
        expect(loaded.activeId, isNull);
        expect(creds.slots, isEmpty);
      },
      createHttpClient: (_) => throw StateError(
          'ConnectionsController must never create HttpClient'),
    );
  });

  test(
      'failed secure write leaves old profile and key intact; failed DB commit rolls back new slot or schedules deferred cleanup',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final raw = _MemorySecureStorage();
    final creds = SecureCredentialStore(storage: raw);
    final controller = ConnectionsController(profilesStore, creds);

    await controller.saveProfile(_profile(), newKey: _testKey1);
    expect(raw.values['salu.endpoint.home.1'], _testKey1);

    // 1. Failed secure write leaves old profile & key intact.
    raw.failWrite = true;
    await expectLater(
      controller.saveProfile(
        _profile(apiRoot: 'https://new.example/v1'),
        newKey: _testKey2,
      ),
      throwsStateError,
    );
    var loaded = await profilesStore.load();
    expect(loaded.profiles.single.apiRoot.host, 'inference.example');
    expect(loaded.profiles.single.credentialRef, 'salu.endpoint.home.1');
    expect(raw.values['salu.endpoint.home.1'], _testKey1);
    expect(raw.values.containsKey('salu.endpoint.home.2'), isFalse);

    // 2. Failed DB commit rolls back newly written slot; if delete also fails,
    //    schedules deferred cleanup while preserving old profile + old key.
    raw.failWrite = false;
    raw.failDeleteForKeys = {'salu.endpoint.home.2'};
    await db.customStatement('''
      CREATE TRIGGER fail_endpoint_update
      BEFORE INSERT ON local_documents
      WHEN NEW.id = 'endpoint-connections'
      BEGIN
        SELECT RAISE(ABORT, 'simulated db commit failure');
      END;
    ''');

    await expectLater(
      controller.saveProfile(
        _profile(apiRoot: 'https://new.example/v1'),
        newKey: _testKey2,
      ),
      throwsException,
    );

    loaded = await profilesStore.load();
    expect(loaded.profiles.single.apiRoot.host, 'inference.example');
    expect(loaded.profiles.single.credentialRef, 'salu.endpoint.home.1');
    expect(raw.values['salu.endpoint.home.1'], _testKey1);

    final manifest = jsonDecode(
      raw.values[SecureCredentialStore.manifestKey]!,
    ) as Map<String, dynamic>;
    expect(manifest['pendingDelete'], contains('salu.endpoint.home.2'));

    // Key material never appears in local_documents.
    final rows = await db.select(db.localDocuments).get();
    expect(rows.single.payload, isNot(contains(_testKey1)));
    expect(rows.single.payload, isNot(contains(_testKey2)));
  });

  test(
      'failed retirement of previous slot after DB commit schedules deferred cleanup',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final raw = _MemorySecureStorage();
    final creds = SecureCredentialStore(storage: raw);
    final controller = ConnectionsController(profilesStore, creds);

    await controller.saveProfile(_profile(), newKey: _testKey1);
    raw.failDeleteForKeys = {'salu.endpoint.home.1'};

    await controller.saveProfile(
      _profile(apiRoot: 'https://rotated.example/v1'),
      newKey: _testKey2,
    );

    final loaded = await profilesStore.load();
    expect(loaded.profiles.single.credentialRef, 'salu.endpoint.home.2');
    expect(raw.values['salu.endpoint.home.2'], _testKey2);

    final manifest = jsonDecode(
      raw.values[SecureCredentialStore.manifestKey]!,
    ) as Map<String, dynamic>;
    expect(manifest['pendingDelete'], contains('salu.endpoint.home.1'));

    // Later flush removes the retired slot once storage succeeds.
    raw.failDeleteForKeys = <String>{};
    await creds.flushPendingDeletes();
    expect(raw.values.containsKey('salu.endpoint.home.1'), isFalse);
  });
}
