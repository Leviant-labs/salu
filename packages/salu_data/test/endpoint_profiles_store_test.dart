import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

EndpointProfile _profile(String id, {String? name, int generation = 1}) =>
    EndpointProfile(
      id: id,
      name: name ?? 'Server $id',
      protocol: EndpointProtocol.openaiChat,
      apiRoot: Uri.parse('https://inference.example/v1'),
      credentialRef: 'salu.endpoint.$id.$generation',
      modelId: 'gpt-4.1-mini',
    );

void main() {
  test('load returns empty state at revision 0 when absent', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = EndpointProfilesStore(LocalDocumentStore(db));

    final state = await store.load();
    expect(state.revision, 0);
    expect(state.profiles, isEmpty);
    expect(state.activeId, isNull);
  });

  test('save and load round-trip with CAS revision and valid activeId',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = EndpointProfilesStore(documents);

    final home = _profile('home', name: 'Home server');
    final work = _profile('work', name: 'Work server');

    expect(
      await store.save(
        expectedRevision: 0,
        profiles: [home, work],
        activeId: 'home',
      ),
      isTrue,
    );

    final loaded = await store.load();
    expect(loaded.revision, 1);
    expect(loaded.profiles, [home, work]);
    expect(loaded.activeId, 'home');

    // Selecting chatgpt-plan is allowed even without a profile with that ID.
    expect(
      await store.save(
        expectedRevision: 1,
        profiles: [home, work],
        activeId: EndpointProfile.reservedChatGptId,
      ),
      isTrue,
    );
    final chatGptSelected = await store.load();
    expect(chatGptSelected.revision, 2);
    expect(chatGptSelected.activeId, 'chatgpt-plan');

    // Stale CAS revision is rejected and preserves current state.
    expect(
      await store.save(
        expectedRevision: 1,
        profiles: [home],
        activeId: null,
      ),
      isFalse,
    );
    final current = await store.load();
    expect(current.revision, 2);
    expect(current.profiles, [home, work]);
    expect(current.activeId, 'chatgpt-plan');

    // Raw local_documents payload contains version 1 and refs, never secrets.
    final rows = await db.select(db.localDocuments).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, EndpointProfilesStore.documentId);
    expect(rows.single.payload, contains('"version":1'));
    expect(rows.single.payload, contains('salu.endpoint.home.1'));
    expect(rows.single.payload, isNot(contains('apiKey')));
  });

  test('rejects duplicate profile IDs in save and load', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = EndpointProfilesStore(documents);

    await expectLater(
      store.save(
        expectedRevision: 0,
        profiles: [
          _profile('dup', generation: 1),
          _profile('dup', generation: 2)
        ],
        activeId: 'dup',
      ),
      throwsFormatException,
    );

    await documents.put(EndpointProfilesStore.documentId, 0, {
      'version': 1,
      'activeId': null,
      'profiles': [
        _profile('dup', generation: 1).toJson(),
        _profile('dup', generation: 2).toJson(),
      ],
    });
    await expectLater(store.load(), throwsFormatException);
  });

  test('rejects missing or unknown activeId in save and load', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = EndpointProfilesStore(documents);

    await expectLater(
      store.save(
        expectedRevision: 0,
        profiles: [_profile('home')],
        activeId: 'missing',
      ),
      throwsFormatException,
    );

    await documents.put(EndpointProfilesStore.documentId, 0, {
      'version': 1,
      'activeId': 'missing',
      'profiles': [_profile('home').toJson()],
    });
    await expectLater(store.load(), throwsFormatException);
  });

  test('rejects unknown or future document versions', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = EndpointProfilesStore(documents);

    for (final badVersion in [0, 2, 99, null, '1']) {
      await documents.put(EndpointProfilesStore.documentId, 0, {
        'version': badVersion,
        'activeId': null,
        'profiles': const <Object?>[],
      });
      await expectLater(store.load(), throwsFormatException);
      await documents.remove(EndpointProfilesStore.documentId);
    }
  });
}
