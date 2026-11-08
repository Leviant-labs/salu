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
}
