import 'dart:convert';

import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('a reward event is written once across retries and is not intake',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);

    expect(await workspace.reward('planning:2026-11-11'), 1);
    expect(await workspace.reward('planning:2026-11-11'), 1);

    final rewards = await workspace.list('reward');
    expect(rewards, hasLength(1));
    expect(rewards.single.id, 'planning:2026-11-11');
    expect(rewards.single.data, {'engagement': true});
    expect(await db.select(db.appliedCommands).get(), hasLength(1));
    // A reward is an engagement marker, never a diary entry or a plan.
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('simultaneous retries of one reward event write exactly once', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);

    // Start every call before awaiting any, so they contend for the same row.
    final revisions = await Future.wait(List.generate(
        8, (_) => workspace.reward('return:2026-11-08')));

    expect(revisions.toSet(), {1});
    expect(await workspace.list('reward'), hasLength(1));
    expect(await db.select(db.appliedCommands).get(), hasLength(1));
  });

  test('reward retries are safe inside an enclosing transaction', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);

    final revisions = await db.transaction(() async {
      return [
        await workspace.reward('engagement'),
        await workspace.reward('engagement'),
      ];
    });

    expect(revisions, [1, 1]);
    expect(await workspace.list('reward'), hasLength(1));
    expect(await db.select(db.appliedCommands).get(), hasLength(1));
  });

  test('simultaneous distinct reward events are all retained', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    const events = [
      'engagement',
      'planning:2026-11-11',
      'learning:portion-sizes',
      'return:2026-11-12',
      'day-review:2026-11-11',
      'checkin:2026-11-11',
    ];

    final revisions =
        await Future.wait([for (final event in events) workspace.reward(event)]);

    expect(revisions, everyElement(1));
    expect((await workspace.list('reward')).map((r) => r.id).toSet(),
        events.toSet());
  });

  test('new rewards reject intake, weight, fasting and punitive streak events',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    const refused = [
      'weight:2026-11-11',
      'weight-loss:2026-11-11',
      'fast:16h',
      'fasting:18h',
      'intake:low',
      'calories:deficit',
      'deficit:2026-11-11',
      'streak:10',
      'lower-intake',
      'missed-day',
      'penalty',
    ];

    for (final event in refused) {
      await expectLater(workspace.reward(event), throwsArgumentError,
          reason: event);
    }

    expect(await workspace.list('reward'), isEmpty);
    expect(await db.select(db.appliedCommands).get(), isEmpty);
  });

  test('malformed reward event ids are refused before any write', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);

    for (final event in [
      '',
      ' ',
      ' planning:2026-11-11',
      'planning:2026-11-11 ',
      'planning:',
      'planning:2026-11-11:extra',
      'planning: 2026-11-11',
    ]) {
      await expectLater(workspace.reward(event), throwsArgumentError,
          reason: event);
    }

    expect(await workspace.list('reward'), isEmpty);
    expect(await db.select(db.appliedCommands).get(), isEmpty);
  });

  test('generic new reward writes enforce the same allowlist and idempotency',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);

    await expectLater(
        workspace.put(
            requestId: 'direct-unsafe',
            collection: 'reward',
            id: 'weight-loss:2026-11-11',
            expectedRevision: 0,
            data: const <String, Object?>{'engagement': true}),
        throwsArgumentError);
    await expectLater(
        workspace.put(
            requestId: 'direct-punitive',
            collection: 'reward',
            id: 'engagement',
            expectedRevision: 0,
            data: const <String, Object?>{'engagement': false}),
        throwsArgumentError);

    expect(await workspace.list('reward'), isEmpty);
    expect(await db.select(db.appliedCommands).get(), isEmpty);

    expect(
        await workspace.put(
            requestId: 'direct-safe',
            collection: 'reward',
            id: 'engagement',
            expectedRevision: 0,
            data: const <String, Object?>{'engagement': true}),
        1);
    // Receipt replay of the creating request is still allowed after the row
    // exists.
    expect(
        await workspace.put(
            requestId: 'direct-safe',
            collection: 'reward',
            id: 'engagement',
            expectedRevision: 0,
            data: const <String, Object?>{'engagement': true}),
        1);
    // A new request id cannot update the existing reward row.
    await expectLater(
        workspace.put(
            requestId: 'direct-update',
            collection: 'reward',
            id: 'engagement',
            expectedRevision: 1,
            data: const <String, Object?>{'engagement': true}),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'REWARD_UPDATE_UNSUPPORTED')));
    expect((await workspace.read('reward', 'engagement'))!.revision, 1);
    expect(await workspace.reward('engagement'), 1);
    expect((await workspace.read('reward', 'engagement'))!.data,
        {'engagement': true});
    expect(await workspace.list('reward'), hasLength(1));
    expect(await db.select(db.appliedCommands).get(), hasLength(1));
  });

  test('historical reward records are kept and retries return their revision',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await db.into(db.userDocuments).insert(UserDocumentsCompanion.insert(
        collection: 'reward',
        id: 'return:2026-10-01',
        revision: 4,
        payload: jsonEncode({'engagement': true})));
    final workspace = LocalWorkspace(db);

    expect(await workspace.reward('return:2026-10-01'), 4);
    final stored = (await workspace.read('reward', 'return:2026-10-01'))!;
    expect(stored.revision, 4);
    expect(stored.data, {'engagement': true});
    expect(await workspace.list('reward'), hasLength(1));
    // The existing document is the source of truth even without a command row.
    expect(await db.select(db.appliedCommands).get(), isEmpty);
  });

  test('rewards survive export and restore and stay idempotent there',
      () async {
    final source = AppDatabase.memory();
    final restored = AppDatabase.memory();
    addTearDown(source.close);
    addTearDown(restored.close);
    final original = LocalWorkspace(source);
    await original.reward('engagement');
    await original.reward('day-review:2026-11-08');
    await original.reward('day-review:2026-11-08');
    // A record written before the current reward policy is history. It is not
    // rewritten or deleted by restoration even though the reward API now
    // rejects new events of that kind.
    await source.into(source.userDocuments).insert(
        UserDocumentsCompanion.insert(
            collection: 'reward',
            id: 'legacy:2026-01-01',
            revision: 2,
            payload: jsonEncode({'engagement': true})));
    final archive = await ArchiveService(source).exportJson();

    await ArchiveService(restored).restoreJson(archive, confirmed: true);
    final copy = LocalWorkspace(restored);
    expect((await copy.read('reward', 'legacy:2026-01-01'))!.revision, 2);
    // A direct generic update of an existing historical row is refused; the
    // row is left untouched and remains readable/retryable through reward().
    await expectLater(
        copy.put(
            requestId: 'legacy-update',
            collection: 'reward',
            id: 'legacy:2026-01-01',
            expectedRevision: 2,
            data: const <String, Object?>{'engagement': true}),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'REWARD_UPDATE_UNSUPPORTED')));
    expect((await copy.read('reward', 'legacy:2026-01-01'))!.revision, 2);
    // The historical event remains an idempotent no-op even though new events
    // of that kind are rejected; no row or command is written.
    expect(await copy.reward('legacy:2026-01-01'), 2);
    expect((await copy.read('reward', 'legacy:2026-01-01'))!.revision, 2);
    await expectLater(
        copy.reward('legacy:2026-01-02'), throwsArgumentError);
    expect(await copy.reward('engagement'), 1);
    expect(await copy.reward('day-review:2026-11-08'), 1);
    expect((await copy.list('reward')).map((r) => r.id).toSet(),
        {'engagement', 'day-review:2026-11-08', 'legacy:2026-01-01'});
    // Retries after restoration must not add a second event or command row.
    expect(await ArchiveService(restored).exportJson(), archive);
  });

  test(
      'missed days never remove earned rewards and history invalidation keeps '
      'them', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);

    await workspace.reward('day-review:2026-11-08');
    await workspace.reward('checkin:2026-11-08');
    // 2026-11-09 is deliberately missed: no call and no penalty record.
    await workspace.reward('day-review:2026-11-10');
    await workspace.put(
        requestId: 'checkin-body',
        collection: 'checkin',
        id: '2026-11-08',
        expectedRevision: 0,
        data: {'note': 'recomputed'});

    await workspace.invalidateHistory();

    expect(await workspace.list('checkin'), isEmpty);
    final rewards = await workspace.list('reward');
    expect(rewards.map((r) => r.id).toSet(), {
      'day-review:2026-11-08',
      'checkin:2026-11-08',
      'day-review:2026-11-10'
    });
    expect(rewards.every((r) => r.data['engagement'] == true), isTrue);
  });

  test('a conflicting idempotency record fails without writing a reward',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: 'reward:planning:2026-11-11',
        resultJson: jsonEncode({
          'collection': 'reward',
          'id': 'planning:2026-11-11',
          'revision': 1,
          'payload': jsonEncode({'engagement': false})
        })));

    await expectLater(
        workspace.reward('planning:2026-11-11'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', 'REQUEST_ID_REUSED')));

    expect(await workspace.list('reward'), isEmpty);
    expect(await db.select(db.appliedCommands).get(), hasLength(1));
  });
}
