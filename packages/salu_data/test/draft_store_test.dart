import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late MealDraftStore store;
  setUp(() {
    db = AppDatabase.memory();
    store = MealDraftStore(db);
  });
  tearDown(() => db.close());

  test(
      'draft revisions persist and stale provider results cannot replace edits',
      () async {
    final initial = await store
        .create(id: 'draft', requestId: 'create', values: {'text': 'apple'});
    expect(initial.revision, 1);
    final edited = await store.edit(
        id: 'draft',
        requestId: 'edit',
        expectedRevision: 1,
        values: {'text': 'pear'});
    expect(edited.revision, 2);
    await expectLater(
        store.receiveValidated(
            id: 'draft',
            requestId: 'response',
            expectedRevision: 1,
            suggestion: {'food': 'apple'}),
        throwsStateError);
    expect((await store.read('draft'))!.values['text'], 'pear');
    expect((await store.list()).single.revision, 2);
  });

  test(
      'confirmation requires review, commits once and rolls back failed writes',
      () async {
    final workspace = LocalWorkspace(db);
    await store.create(id: 'draft', requestId: 'create');
    await store.receiveValidated(
        id: 'draft',
        requestId: 'response',
        expectedRevision: 1,
        suggestion: {'food': 'apple'});
    var calls = 0;
    Future<void> write() async {
      calls++;
      await workspace.put(
          requestId: 'local',
          collection: 'preferences',
          id: 'example',
          expectedRevision: 0,
          data: {'value': 1});
    }

    await expectLater(
        store.confirm(
            id: 'draft',
            requestId: 'confirm',
            expectedRevision: 2,
            reviewed: false,
            writeLocal: write),
        throwsStateError);
    expect(calls, 0);
    await expectLater(
        store.confirm(
            id: 'draft',
            requestId: 'fail',
            expectedRevision: 2,
            reviewed: true,
            writeLocal: () async {
              await write();
              throw StateError('failed');
            }),
        throwsStateError);
    expect(await workspace.read('preferences', 'example'), isNull);
    expect((await store.read('draft'))!.status, DraftStatus.review);
    calls = 0;
    final result = await store.confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: write);
    expect(result.status, DraftStatus.committed);
    await store.confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: write);
    expect(calls, 1);
    expect((await workspace.read('preferences', 'example'))!.data['value'], 1);
  });

  test('cancelled drafts reject late responses and confirmation', () async {
    await store.create(id: 'draft', requestId: 'create');
    await store.cancel(id: 'draft', requestId: 'cancel', expectedRevision: 1);
    await expectLater(
        store.receiveValidated(
            id: 'draft',
            requestId: 'late',
            expectedRevision: 1,
            suggestion: {}),
        throwsStateError);
    await expectLater(
        store.receiveValidated(
            id: 'draft',
            requestId: 'late-current',
            expectedRevision: 2,
            suggestion: {}),
        throwsStateError);
    expect((await store.read('draft'))!.status, DraftStatus.cancelled);
    await expectLater(
        store.confirm(
            id: 'draft',
            requestId: 'confirm',
            expectedRevision: 2,
            reviewed: true,
            writeLocal: () async {}),
        throwsStateError);
  });
  test('backup and restore preserve draft revisions', () async {
    await store
        .create(id: 'draft', requestId: 'create', values: {'text': 'pear'});
    await store.edit(
        id: 'draft',
        requestId: 'edit',
        expectedRevision: 1,
        values: {'text': 'apple'});
    final archive = await ArchiveService(db).exportJson();
    final restoredDb = AppDatabase.memory();
    addTearDown(restoredDb.close);
    await ArchiveService(restoredDb).restoreJson(archive, confirmed: true);
    final restored = (await MealDraftStore(restoredDb).read('draft'))!;
    expect(restored.revision, 2);
    expect(restored.values['text'], 'apple');
  });
  test('a draft edited between review and commit is not committed', () async {
    await store.create(id: 'draft', requestId: 'create');
    await store.receiveValidated(
        id: 'draft',
        requestId: 'response',
        expectedRevision: 1,
        suggestion: {'food': 'apple'});
    await store.edit(
        id: 'draft',
        requestId: 'edit',
        expectedRevision: 2,
        values: {'food': 'pear'});
    var calls = 0;
    await expectLater(
        store.confirm(
            id: 'draft',
            requestId: 'confirm',
            expectedRevision: 2,
            reviewed: true,
            writeLocal: () async {
              calls++;
            }),
        throwsStateError);
    expect(calls, 0);
    final current = (await store.read('draft'))!;
    expect(current.status, DraftStatus.review);
    expect(current.revision, 3);
    expect(current.values['food'], 'pear');
  });
  test('concurrent retries of one confirmation write once', () async {
    final workspace = LocalWorkspace(db);
    await store.create(id: 'draft', requestId: 'create');
    await store.receiveValidated(
        id: 'draft',
        requestId: 'response',
        expectedRevision: 1,
        suggestion: {'food': 'apple'});
    var calls = 0;
    Future<void> write() async {
      calls++;
      await workspace.put(
          requestId: 'local',
          collection: 'preferences',
          id: 'example',
          expectedRevision: 0,
          data: {'value': 1});
    }

    Future<MealDraft> confirm() => store.confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: write);
    final results = await Future.wait([confirm(), confirm()]);
    expect(results.map((draft) => draft.status),
        everyElement(DraftStatus.committed));
    expect(calls, 1);
    expect((await workspace.read('preferences', 'example'))!.data['value'], 1);
  });
  test('a confirmation request id cannot be replayed for another draft',
      () async {
    final workspace = LocalWorkspace(db);
    Future<void> write(String key) async {
      await workspace.put(
          requestId: 'local-$key',
          collection: 'preferences',
          id: key,
          expectedRevision: 0,
          data: {'value': 1});
    }

    await store.create(id: 'first', requestId: 'create-first');
    await store.receiveValidated(
        id: 'first',
        requestId: 'response-first',
        expectedRevision: 1,
        suggestion: {'food': 'apple'});
    await store.confirm(
        id: 'first',
        requestId: 'shared-confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: () => write('first'));
    await store.create(id: 'second', requestId: 'create-second');
    await store.receiveValidated(
        id: 'second',
        requestId: 'response-second',
        expectedRevision: 1,
        suggestion: {'food': 'pear'});
    await expectLater(
        store.confirm(
            id: 'second',
            requestId: 'shared-confirm',
            expectedRevision: 2,
            reviewed: true,
            writeLocal: () => write('second')),
        throwsStateError);
    expect((await store.read('second'))!.status, DraftStatus.review);
    expect(await workspace.read('preferences', 'second'), isNull);
    expect((await workspace.read('preferences', 'first'))!.data['value'], 1);
  });
  test('a committed draft cannot be reopened or cancelled', () async {
    await store.create(id: 'draft', requestId: 'create');
    await store.receiveValidated(
        id: 'draft',
        requestId: 'response',
        expectedRevision: 1,
        suggestion: {'food': 'apple'});
    await store.confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: () async {});
    var replays = 0;
    final replayed = await store.confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 3,
        reviewed: true,
        writeLocal: () async {
          replays++;
        });
    expect(replayed.status, DraftStatus.committed);
    expect(replays, 0);
    await expectLater(
        store.confirm(
            id: 'draft',
            requestId: 'second-confirm',
            expectedRevision: 2,
            reviewed: true,
            writeLocal: () async {
              replays++;
            }),
        throwsStateError);
    await expectLater(
        store.confirm(
            id: 'draft',
            requestId: 'confirm',
            expectedRevision: 2,
            reviewed: false,
            writeLocal: () async {
              replays++;
            }),
        throwsStateError);
    expect(replays, 0);
    await expectLater(
        store.receiveValidated(
            id: 'draft',
            requestId: 'late',
            expectedRevision: 3,
            suggestion: {'food': 'pear'}),
        throwsStateError);
    await expectLater(
        store.edit(
            id: 'draft',
            requestId: 'edit',
            expectedRevision: 3,
            values: {'food': 'pear'}),
        throwsStateError);
    await expectLater(
        store.cancel(
            id: 'draft', requestId: 'cancel', expectedRevision: 3),
        throwsStateError);
    final current = (await store.read('draft'))!;
    expect(current.status, DraftStatus.committed);
    expect(current.revision, 3);
    expect(current.values['food'], 'apple');
  });
  test('a replayed confirmation after restore does not write intake again',
      () async {
    await store.create(id: 'draft', requestId: 'create');
    await store.receiveValidated(
        id: 'draft',
        requestId: 'response',
        expectedRevision: 1,
        suggestion: {'food': 'apple'});
    var calls = 0;
    await store.confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: () async {
          calls++;
        });
    expect(calls, 1);
    final archive = await ArchiveService(db).exportJson();
    final restoredDb = AppDatabase.memory();
    addTearDown(restoredDb.close);
    await ArchiveService(restoredDb).restoreJson(archive, confirmed: true);
    await MealDraftStore(restoredDb).confirm(
        id: 'draft',
        requestId: 'confirm',
        expectedRevision: 2,
        reviewed: true,
        writeLocal: () async {
          calls++;
        });
    expect(calls, 1);
  });
}
