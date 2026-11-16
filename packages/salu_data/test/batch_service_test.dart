import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('stock allocation and intake are atomic and idempotent', () async {
    final db = AppDatabase.memory();
    try {
      final r = RecipeVersion(
          id: 'r',
          revision: 1,
          name: 'Protein recipe',
          ingredients: [
            RecipeIngredient(
                Food(
                    id: 'f',
                    name: 'Ingredient',
                    per100g: NutrientProfile(
                        {NutrientKey.proteinG: NutrientReported(60)}),
                    source:
                        const FoodSource(dataset: 'fixture', datasetId: '1')),
                Exact.parse('100'))
          ],
          servings: Exact.parse('3'),
          minutes: 10);
      final w = LocalWorkspace(db);
      await w.put(
          requestId: 'create-batch',
          collection: 'batch',
          id: 'b',
          expectedRevision: 0,
          data: {
            'recipe': recipeSnapshot(r),
            'available': Exact.parse('600').toJson(),
            'finishedWeightG': Exact.parse('600').toJson(),
            'unit': 'g',
            'allocations': <Object?>[]
          });
      final service =
          BatchService(db, const SystemClock(), SequentialIdGenerator());
      final first = await service.consumeAmount(
          requestId: 'consume',
          batchId: 'b',
          expectedRevision: 1,
          amount: Exact.parse('200'), unit: FoodUnit.g,
          offsetMinutes: 0,
          confirmed: true);
      final retry = await service.consumeAmount(
          requestId: 'consume',
          batchId: 'b',
          expectedRevision: 1,
          amount: Exact.parse('200'), unit: FoodUnit.g,
          offsetMinutes: 0,
          confirmed: true);
      expect(retry.id, first.id);
      expect(first.nutrientSum(NutrientKey.proteinG).value, 20);
      expect((await w.read('batch', 'b'))!.data['allocations'] as List,
          hasLength(1));
      await expectLater(
          service.consumeAmount(
              requestId: 'too-much',
              batchId: 'b',
              expectedRevision: 2,
              amount: Exact.parse('500'), unit: FoodUnit.g,
              offsetMinutes: 0,
              confirmed: true),
          throwsStateError);
      expect(
          await DriftEntryRepository(db).findByRequestId('too-much'), isNull);
      expect((await w.read('batch', 'b'))!.revision, 2);

      final entries = DriftEntryRepository(db);
      await entries.revise(ReviseEntryCommand(
          requestId: 'correct',
          entryId: first.id,
          expectedRevision: 1,
          recordedAt: DateTime.utc(2026),
          multiplier: Exact.parse('2')));
      expect(
          (await entries.findByRequestId('consume'))!
              .nutrientSum(NutrientKey.proteinG)
              .value,
          40);
      expect((await w.read('batch', 'b'))!.revision, 3);
      await expectLater(
          entries.revise(ReviseEntryCommand(
              requestId: 'over-correct',
              entryId: first.id,
              expectedRevision: 2,
              recordedAt: DateTime.utc(2026),
              multiplier: Exact.parse('2'))),
          throwsStateError);
      expect((await entries.findByRequestId('consume'))!.revision, 2);
      expect((await w.read('batch', 'b'))!.revision, 3);
    } finally {
      await db.close();
    }
  });
  test('reserved stock is counted once when confirmed and remains correctable',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = RecipeVersion(
        id: 'r',
        revision: 1,
        name: 'Soup',
        servings: Exact.parse('3'),
        minutes: 10,
        ingredients: [
          RecipeIngredient(
              Food(
                  id: 'f',
                  name: 'Ingredient',
                  per100g: NutrientProfile(
                      {NutrientKey.proteinG: NutrientReported(60)}),
                  source: const FoodSource(dataset: 'fixture', datasetId: '1')),
              Exact.parse('100'))
        ]);
    final workspace = LocalWorkspace(db);
    await workspace.put(
        requestId: 'create',
        collection: 'batch',
        id: 'b',
        expectedRevision: 0,
        data: {
          'recipe': recipeSnapshot(recipe),
          'available': Exact.parse('600').toJson(),
          'finishedWeightG': Exact.parse('600').toJson(),
          'unit': 'g',
          'allocations': <Object?>[]
        });
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    expect(await db.select(db.logEntries).get(), isEmpty);
    await expectLater(
        service.reserveAmount(
            requestId: 'reserve-2',
            batchId: 'b',
            allocationId: 'plan-2',
            expectedRevision: 2,
            amount: Exact.parse('300'), unit: FoodUnit.g),
        throwsStateError);
    await expectLater(
        service.consumeAmount(
            requestId: 'bad',
            batchId: 'b',
            expectedRevision: 2,
            amount: Exact.parse('300'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'plan-1'),
        throwsStateError);
    expect((await workspace.read('batch', 'b'))!.revision, 2);
    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('400'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-1');
    expect(entry.nutrientSum(NutrientKey.proteinG).value, 40);
    final allocations =
        (await workspace.read('batch', 'b'))!.data['allocations']! as List;
    expect(allocations, hasLength(1));
    expect((allocations.single as Map)['id'], 'plan-1');
    expect((allocations.single as Map)['intakeRequestId'], 'meal');
    expect((allocations.single as Map)['status'], 'consumed');
    await DriftEntryRepository(db).revise(ReviseEntryCommand(
        requestId: 'reduce',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        multiplier: Exact.parse('0.5')));
    final correctedAllocation =
        ((await workspace.read('batch', 'b'))!.data['allocations'] as List).single as Map;
    expect(correctedAllocation['id'], 'plan-1');
    expect(correctedAllocation['intakeRequestId'], 'meal');
    expect(Exact.fromJson(Map<String, Object?>.from(correctedAllocation['amount'] as Map)),
        Exact.parse('200'));
    expect((await workspace.read('batch', 'b'))!.revision, 4);
    await expectLater(
        service.releaseReservation(
            requestId: 'release-consumed',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 4),
        throwsStateError);
    expect(
        await service.reserveAmount(
            requestId: 'reserve-3',
            batchId: 'b',
            allocationId: 'plan-3',
            expectedRevision: 4,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        5);
    final retained = ((await workspace.read('batch', 'b'))!.data['allocations'] as List)
        .cast<Map<String, Object?>>()
        .singleWhere((a) => a['id'] == 'plan-1');
    expect(retained['intakeRequestId'], 'meal');
    expect(
        await service.releaseReservation(
            requestId: 'release-3',
            batchId: 'b',
            allocationId: 'plan-3',
            expectedRevision: 5),
        6);
    expect(
        await service.releaseReservation(
            requestId: 'release-3',
            batchId: 'b',
            allocationId: 'plan-3',
            expectedRevision: 5),
        6);
    expect(((await workspace.read('batch', 'b'))!.data['allocations'] as List),
        hasLength(1));
  });
  test('simultaneous reservations against one revision keep stock exact',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    // Start both before awaiting so each transaction opens from revision 1.
    final first = service.reserveAmount(
        requestId: 'reserve-a',
        batchId: 'b',
        allocationId: 'plan-a',
        expectedRevision: 1,
        amount: Exact.parse('300'), unit: FoodUnit.g);
    final second = service.reserveAmount(
        requestId: 'reserve-b',
        batchId: 'b',
        allocationId: 'plan-b',
        expectedRevision: 1,
        amount: Exact.parse('300'), unit: FoodUnit.g);
    final outcomes = await Future.wait([_outcome(first), _outcome(second)]);

    expect(outcomes.whereType<int>().toList(), [2]);
    final rejected = outcomes.whereType<StateError>().toList();
    expect(rejected, hasLength(1));
    expect(rejected.single.message, 'STALE_BATCH');

    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 2);
    final winner = _allocationsOf(doc).single;
    expect(_amountOf(winner), Exact.parse('300'));
    expect(winner['status'], 'planned');
    // Reserving is not intake.
    expect(await db.select(db.logEntries).get(), isEmpty);

    final loser = winner['id'] == 'plan-a' ? 'plan-b' : 'plan-a';
    // The losing transaction retries against the revision the winner wrote.
    expect(
        await service.reserveAmount(
            requestId: 'retry-$loser',
            batchId: 'b',
            allocationId: loser,
            expectedRevision: 2,
            amount: Exact.parse('300'), unit: FoodUnit.g),
        3);
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    final allocations = _allocationsOf(doc);
    expect(allocations.map((a) => a['id']),
        containsAll(<Object?>['plan-a', 'plan-b']));
    expect(allocations.fold<Exact>(Exact.zero, (sum, a) => sum + _amountOf(a)),
        Exact.parse('600'));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
  test('simultaneous reservations cannot overspend the cooked stock',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    final outcomes = await Future.wait([
      _outcome(service.reserveAmount(
          requestId: 'reserve-a',
          batchId: 'b',
          allocationId: 'plan-a',
          expectedRevision: 1,
          amount: Exact.parse('400'), unit: FoodUnit.g)),
      _outcome(service.reserveAmount(
          requestId: 'reserve-b',
          batchId: 'b',
          allocationId: 'plan-b',
          expectedRevision: 1,
          amount: Exact.parse('400'), unit: FoodUnit.g))
    ]);
    expect(outcomes.whereType<int>().toList(), [2]);
    final rejected = outcomes.whereType<StateError>().toList();
    expect(rejected, hasLength(1));
    expect(rejected.single.message, 'STALE_BATCH');

    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 2);
    final winner = _allocationsOf(doc).single;
    expect(_amountOf(winner), Exact.parse('400'));

    final loser = winner['id'] == 'plan-a' ? 'plan-b' : 'plan-a';
    // Even after retrying with the winner's revision the stock cannot fit.
    await expectLater(
        service.reserveAmount(
            requestId: 'retry-$loser',
            batchId: 'b',
            allocationId: loser,
            expectedRevision: 2,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        _stateError('BATCH_OVERALLOCATED'));
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 2);
    expect(_allocationsOf(doc).single['id'], winner['id']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
  test('stale revisions are rejected before any write', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    final receipts = (await db.select(db.appliedCommands).get()).length;

    await expectLater(
        service.reserveAmount(
            requestId: 'stale-reserve',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 0,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        _stateError('STALE_BATCH'));
    await expectLater(
        service.reserveAmount(
            requestId: 'future-reserve',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 99,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        _stateError('STALE_BATCH'));
    await expectLater(
        service.consumeAmount(
            requestId: 'stale-meal',
            batchId: 'b',
            expectedRevision: 0,
            amount: Exact.parse('100'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('STALE_BATCH'));
    expect(await _hasCommand(db, 'stock:stale-meal'), isFalse);
    expect((await db.select(db.appliedCommands).get()).length, receipts);

    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        2);
    await expectLater(
        service.releaseReservation(
            requestId: 'stale-release',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1),
        _stateError('STALE_BATCH'));
    await expectLater(
        service.reserveAmount(
            requestId: 'stale-noop-reserve',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        _stateError('STALE_BATCH'));
    await expectLater(
        service.releaseReservation(
            requestId: 'stale-noop-release',
            batchId: 'b',
            allocationId: 'missing',
            expectedRevision: 1),
        _stateError('STALE_BATCH'));

    var doc = (await workspace.read('batch', 'b'))!;
    await expectLater(
        workspace.put(
            requestId: 'direct-stale',
            collection: 'batch',
            id: 'b',
            expectedRevision: 1,
            data: doc.data),
        _stateError('STALE_REVISION'));

    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 2);
    final allocation = _allocationsOf(doc).single;
    expect(allocation['id'], 'plan-a');
    expect(_amountOf(allocation), Exact.parse('100'));
    // Every failed attempt above wrote nothing; the accepted reservation
    // recorded its receipt(s).
    expect(
        (await db.select(db.appliedCommands).get()).length,
        greaterThan(receipts));
    expect(await _hasCommand(db, 'batch-reserve:reserve-1'), isTrue);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
  test('a failing diary insert rolls back the stock write', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    await db.into(db.logEntries).insert(LogEntriesCompanion.insert(
        id: 'seed-entry',
        requestId: 'seed-request',
        diaryDate: '2026-01-01',
        instantUtcMs: 0,
        offsetMinutes: 0,
        channel: 'manual',
        recordedAtMs: 0));
    await workspace.put(
        requestId: 'seed-checkin',
        collection: 'checkin',
        id: 'seed-checkin',
        expectedRevision: 0,
        data: {'checked': true});
    // A real primary-key collision: the generated entry id already exists.
    final service = BatchService(
        db, const SystemClock(), const _FixedIdGenerator('seed-entry'));

    await expectLater(
        service.consumeAmount(
            requestId: 'rollback-insert',
            batchId: 'b',
            expectedRevision: 1,
            amount: Exact.parse('200'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        throwsA(isA<SqliteException>()
            .having((error) => error.message, 'message', contains('UNIQUE'))));

    final doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 1);
    expect(_allocationsOf(doc), isEmpty);
    expect(await _hasCommand(db, 'stock:rollback-insert'), isFalse);
    expect(await _hasCommand(db, 'day-log:rollback-insert'), isFalse);
    final entries = await db.select(db.logEntries).get();
    expect(entries, hasLength(1));
    expect(entries.single.requestId, 'seed-request');
    expect(
        await DriftEntryRepository(db).findByRequestId('rollback-insert'),
        isNull);
    // invalidateHistory() ran inside the rolled back transaction.
    expect(await workspace.read('checkin', 'seed-checkin'), isNotNull);
    expect(await workspace.list('day'), isEmpty);
  });
  test('a failing diary workspace write rolls back the stock write', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    // A stored command for this key with a different payload is a real
    // conflict for the day document write inside the diary append.
    await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: 'day-log:rollback-workspace',
        resultJson: jsonEncode({
          'collection': 'day',
          'id': '1999-01-01',
          'revision': 1,
          'payload': '{}'
        })));
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    await expectLater(
        service.consumeAmount(
            requestId: 'rollback-workspace',
            batchId: 'b',
            expectedRevision: 1,
            amount: Exact.parse('200'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('REQUEST_ID_REUSED'));

    final doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 1);
    expect(_allocationsOf(doc), isEmpty);
    expect(await _hasCommand(db, 'stock:rollback-workspace'), isFalse);
    expect(await db.select(db.logEntries).get(), isEmpty);
    expect(await workspace.list('day'), isEmpty);
    expect(await _hasCommand(db, 'day-log:rollback-workspace'), isTrue);
  });
  test('reserve and consume retries replay or reject conflicting payloads',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    // Identical retry: no second allocation and no revision bump.
    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    expect(_allocationsOf((await workspace.read('batch', 'b'))!), hasLength(1));

    // Another request for the same allocation and amount is a recorded no-op.
    expect(
        await service.reserveAmount(
            requestId: 'reserve-dup',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 2,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    expect(_allocationsOf((await workspace.read('batch', 'b'))!), hasLength(1));

    // Another request may not take over an existing allocation.
    await expectLater(
        service.reserveAmount(
            requestId: 'reserve-2',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 2,
            amount: Exact.parse('300'), unit: FoodUnit.g),
        _stateError('BATCH_ALLOCATION_CONFLICT'));
    // Same request with another allocation is a reused request id.
    await expectLater(
        service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-x',
            expectedRevision: 2,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        _stateError('REQUEST_ID_REUSED'));
    // Same request and allocation with another quantity is also a reused id.
    await expectLater(
        service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 2,
            amount: Exact.parse('300'), unit: FoodUnit.g),
        _stateError('REQUEST_ID_REUSED'));
    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 2);
    final reservation = _allocationsOf(doc).single;
    expect(reservation['id'], 'plan-1');
    expect(_amountOf(reservation), Exact.parse('400'));

    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('400'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-1');
    expect(entry.revision, 1);
    // Identical retry replays the entry and spends the stock once.
    final retry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('400'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-1');
    expect(retry.id, entry.id);
    expect(retry.items.single.sourceSnapshot!['consumedBatchGrams'],
        Exact.parse('400').toJson());
    // A different payload under the same request id is rejected, not replayed.
    await expectLater(
        service.consumeAmount(
            requestId: 'meal',
            batchId: 'b',
            expectedRevision: 3,
            amount: Exact.parse('100'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('REQUEST_ID_REUSED'));
    await expectLater(
        service.consumeAmount(
            requestId: 'meal',
            batchId: 'other',
            expectedRevision: 3,
            amount: Exact.parse('400'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('REQUEST_ID_REUSED'));
    // Dropping the reservation id is a different payload too.
    await expectLater(
        service.consumeAmount(
            requestId: 'meal',
            batchId: 'b',
            expectedRevision: 3,
            amount: Exact.parse('400'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('REQUEST_ID_REUSED'));
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    final consumed = _allocationsOf(doc).single;
    expect(consumed['id'], 'plan-1');
    expect(consumed['intakeRequestId'], 'meal');
    expect(consumed['status'], 'consumed');
    expect(_amountOf(consumed), Exact.parse('400'));
    final stored = await db.select(db.logEntries).get();
    expect(stored, hasLength(1));
    expect(stored.single.requestId, 'meal');
    // The original reserve request keeps returning its recorded revision even
    // after later writes moved the batch on.
    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    expect((await workspace.read('batch', 'b'))!.revision, 3);
  });
  test('reservations release, retry and consume exactly once', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('600'), unit: FoodUnit.g),
        2);
    await expectLater(
        service.reserveAmount(
            requestId: 'reserve-2',
            batchId: 'b',
            allocationId: 'plan-b',
            expectedRevision: 2,
            amount: Exact.parse('100'), unit: FoodUnit.g),
        _stateError('BATCH_OVERALLOCATED'));
    expect(
        await service.releaseReservation(
            requestId: 'release-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 2),
        3);
    // The same request id replays its recorded revision.
    expect(
        await service.releaseReservation(
            requestId: 'release-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 2),
        3);
    // A never-seen allocation is an idempotent no-op at the current revision.
    expect(
        await service.releaseReservation(
            requestId: 'release-absent',
            batchId: 'b',
            allocationId: 'ghost',
            expectedRevision: 3),
        3);
    expect(
        await service.reserveAmount(
            requestId: 'reserve-3',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 3,
            amount: Exact.parse('600'), unit: FoodUnit.g),
        4);
    // The absent-allocation no-op recorded its outcome at revision 3.
    expect(
        await service.releaseReservation(
            requestId: 'release-absent',
            batchId: 'b',
            allocationId: 'ghost',
            expectedRevision: 3),
        3);
    expect((await workspace.read('batch', 'b'))!.revision, 4);
    // Retrying the completed release after the allocation was reserved again
    // replays the recorded revision and never frees the new reservation.
    expect(
        await service.releaseReservation(
            requestId: 'release-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 2),
        3);
    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 4);
    var allocation = _allocationsOf(doc).single;
    expect(allocation['id'], 'plan-a');
    expect(allocation['status'], 'planned');
    expect(_amountOf(allocation), Exact.parse('600'));
    // Reusing that request id for a later revision is rejected.
    await expectLater(
        service.releaseReservation(
            requestId: 'release-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 4),
        _stateError('REQUEST_ID_REUSED'));
    expect((await workspace.read('batch', 'b'))!.revision, 4);
    // Reusing that request id for another allocation is rejected.
    await expectLater(
        service.releaseReservation(
            requestId: 'release-1',
            batchId: 'b',
            allocationId: 'plan-b',
            expectedRevision: 2),
        _stateError('REQUEST_ID_REUSED'));
    expect((await workspace.read('batch', 'b'))!.revision, 4);

    // A fresh request id releases the re-reserved stock.
    expect(
        await service.releaseReservation(
            requestId: 'release-2',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 4),
        5);
    expect(_allocationsOf((await workspace.read('batch', 'b'))!), isEmpty);
    // The freed stock can be reserved and consumed again.
    expect(
        await service.reserveAmount(
            requestId: 'reserve-4',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 5,
            amount: Exact.parse('600'), unit: FoodUnit.g),
        6);
    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 6,
        amount: Exact.parse('600'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-a');
    expect(entry.nutrientSum(NutrientKey.proteinG).value, 60);
    // The reservation keeps its plan identity and cannot be spent twice.
    await expectLater(
        service.consumeAmount(
            requestId: 'meal-2',
            batchId: 'b',
            expectedRevision: 7,
            amount: Exact.parse('600'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'plan-a'),
        _stateError('BATCH_RESERVATION_MISMATCH'));
    expect(await DriftEntryRepository(db).findByRequestId('meal-2'), isNull);
    // Retrying the old release after consumption still replays and never
    // touches the consumed allocation.
    expect(
        await service.releaseReservation(
            requestId: 'release-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 2),
        3);
    await expectLater(
        service.releaseReservation(
            requestId: 'release-3',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 7),
        _stateError('BATCH_ALLOCATION_ALREADY_CONSUMED'));
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 7);
    allocation = _allocationsOf(doc).single;
    expect(allocation['id'], 'plan-a');
    expect(allocation['intakeRequestId'], 'meal');
    expect(allocation['status'], 'consumed');
    expect(_amountOf(allocation), Exact.parse('600'));
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });
  test('a request id already used by a manual entry is rejected', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final entries = DriftEntryRepository(db);
    await entries.append(LoggedEntry(
        id: 'manual-1',
        requestId: 'manual-meal',
        diaryDate: DiaryDate(2026, 1, 1),
        stamp: EventStamp(instant: DateTime.utc(2026), offsetMinutes: 0),
        channel: EntryChannel.manual,
        recordedAt: DateTime.utc(2026),
        items: [
          LoggedItem(
              name: 'Ingredient',
              grams: 100,
              nutrients: NutrientProfile(
                  {NutrientKey.proteinG: NutrientReported(60)}))
        ]));
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    // The id belongs to a diary entry that did not come from a batch.
    await expectLater(
        service.consumeAmount(
            requestId: 'manual-meal',
            batchId: 'b',
            expectedRevision: 1,
            amount: Exact.parse('100'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('REQUEST_ID_REUSED'));
    final doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 1);
    expect(_allocationsOf(doc), isEmpty);
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });
  test('unreserved intake coexists with planned stock without overspending',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    expect(
        await service.reserveAmount(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('400'), unit: FoodUnit.g),
        2);
    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('200'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(entry.nutrientSum(NutrientKey.proteinG).value, 20);
    expect((entry.items.single.sourceSnapshot!)['batchRevision'], 2);
    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    var allocations = _allocationsOf(doc);
    expect(allocations, hasLength(2));
    final planned = allocations.singleWhere((a) => a['id'] == 'plan-a');
    expect(planned['status'], 'planned');
    expect(_amountOf(planned), Exact.parse('400'));
    final consumed = allocations.singleWhere((a) => a['id'] == 'meal');
    expect(consumed['status'], 'consumed');
    expect(_amountOf(consumed), Exact.parse('200'));
    expect(allocations.fold<Exact>(Exact.zero, (sum, a) => sum + _amountOf(a)),
        Exact.parse('600'));

    // Planned stock still counts against the batch: 0 g remain, not 200 g.
    await expectLater(
        service.consumeAmount(
            requestId: 'meal-2',
            batchId: 'b',
            expectedRevision: 3,
            amount: Exact.parse('100'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('BATCH_OVERALLOCATED'));
    expect(await DriftEntryRepository(db).findByRequestId('meal-2'), isNull);

    // Replaying the original request after later writes returns the stored
    // entry without spending stock again.
    final retry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('200'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(retry.id, entry.id);
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    expect(await db.select(db.logEntries).get(), hasLength(1));

    // Consuming the reservation keeps the total at exactly the cooked weight.
    final reserved = await service.consumeAmount(
        requestId: 'meal-3',
        batchId: 'b',
        expectedRevision: 3,
        amount: Exact.parse('400'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-a');
    expect(reserved.nutrientSum(NutrientKey.proteinG).value, 40);
    allocations = _allocationsOf((await workspace.read('batch', 'b'))!);
    expect(allocations.map((a) => a['id']),
        containsAll(<Object?>['meal', 'plan-a']));
    expect(allocations.singleWhere((a) => a['id'] == 'plan-a')['intakeRequestId'],
        'meal-3');
    expect(allocations.every((a) => a['status'] == 'consumed'), isTrue);
    expect(allocations.fold<Exact>(Exact.zero, (sum, a) => sum + _amountOf(a)),
        Exact.parse('600'));
    expect(await db.select(db.logEntries).get(), hasLength(2));
  });
  test('corrections scale allocations without over-allocating stock', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    final entries = DriftEntryRepository(db);

    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 1,
        amount: Exact.parse('400'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(entry.revision, 1);
    expect(
        await entries.revise(ReviseEntryCommand(
            requestId: 'grow-ok',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('1.5'))),
        2);
    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    expect(_amountOf(_allocationsOf(doc).single), Exact.parse('600'));
    expect(
        (await entries.findByRequestId('meal'))!
            .nutrientSum(NutrientKey.proteinG)
            .value,
        60);

    // A correction that would exceed the cooked weight is rejected whole.
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'grow-too-much',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('2'))),
        _stateError('BATCH_OVERALLOCATED'));
    expect((await entries.findByRequestId('meal'))!.revision, 2);
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    expect(_amountOf(_allocationsOf(doc).single), Exact.parse('600'));
    expect(await workspace.read('entry-revision', '${entry.id}:2'), isNull);
    expect(await _hasCommand(db, 'history:grow-too-much'), isFalse);

    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'stale-correct',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('0.5'))),
        _stateError('STALE_ENTRY'));
    expect((await entries.findByRequestId('meal'))!.revision, 2);

    expect(
        await entries.revise(ReviseEntryCommand(
            requestId: 'shrink',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('0.5'))),
        3);
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 4);
    expect(_amountOf(_allocationsOf(doc).single), Exact.parse('300'));
    expect(
        (await entries.findByRequestId('meal'))!
            .nutrientSum(NutrientKey.proteinG)
            .value,
        30);

    // The corrected-down stock is fully available again.
    final second = await service.consumeAmount(
        requestId: 'meal-2',
        batchId: 'b',
        expectedRevision: 4,
        amount: Exact.parse('300'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(second.nutrientSum(NutrientKey.proteinG).value, 30);
    expect(
        _allocationsOf((await workspace.read('batch', 'b'))!)
            .fold<Exact>(Exact.zero, (sum, a) => sum + _amountOf(a)),
        Exact.parse('600'));

    // Replaying the correction returns the stored revision instead of
    // applying the multiplier twice; a changed payload is rejected.
    expect(
        await entries.revise(ReviseEntryCommand(
            requestId: 'shrink',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('0.5'))),
        3);
    expect((await workspace.read('batch', 'b'))!.revision, 5);
    expect(
        _amountOf(_allocationsOf((await workspace.read('batch', 'b'))!)
            .singleWhere((a) => a['id'] == 'meal')),
        Exact.parse('300'));
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'shrink',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('0.25'))),
        _stateError('REQUEST_ID_REUSED'));
    expect((await entries.findByRequestId('meal'))!.revision, 3);
    // A retried consume request returns the corrected entry, not the original
    // snapshot, and never appends a second row or spends stock again.
    final replay = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 1,
        amount: Exact.parse('400'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(replay.id, entry.id);
    expect(replay.revision, 3);
    expect(replay.nutrientSum(NutrientKey.proteinG).value, 30);
    expect(await db.select(db.logEntries).get(), hasLength(2));
    expect((await workspace.read('batch', 'b'))!.revision, 5);
  });
  test('restored batch receipts prevent duplicate consumption', () async {
    final source = AppDatabase.memory();
    final restored = AppDatabase.memory();
    addTearDown(source.close);
    addTearDown(restored.close);
    await _seedBatch(source);
    final service =
        BatchService(source, const SystemClock(), SequentialIdGenerator());
    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 1,
        amount: Exact.parse('200'), unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    final archive = await ArchiveService(source).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);
    final retried = await BatchService(
            restored, const SystemClock(), SequentialIdGenerator())
        .consumeAmount(
            requestId: 'meal',
            batchId: 'b',
            expectedRevision: 1,
            amount: Exact.parse('200'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true);
    expect(retried.id, entry.id);
    expect(await restored.select(restored.logEntries).get(), hasLength(1));
    final batch = (await LocalWorkspace(restored).read('batch', 'b'))!;
    expect(_amountOf(_allocationsOf(batch).single), Exact.parse('200'));
  });
  test('ambiguous legacy reservation receipts never claim a retry succeeded',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final original = (await workspace.read('batch', 'b'))!;
    final allocation = {
      'id': 'planned',
      'amount': Exact.parse('200').toJson(),
      'status': 'planned'
    };
    await workspace.put(
        requestId: 'reserve:old-reserve',
        collection: 'batch',
        id: 'b',
        expectedRevision: 1,
        data: {...original.data, 'allocations': [allocation]});
    final reserved = (await workspace.read('batch', 'b'))!;
    await workspace.put(
        requestId: 'release:old-release',
        collection: 'batch',
        id: 'b',
        expectedRevision: 2,
        data: {...reserved.data, 'allocations': <Object?>[]});
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    await expectLater(
        service.reserveAmount(
            requestId: 'old-reserve',
            batchId: 'b',
            allocationId: 'planned',
            expectedRevision: 1,
            amount: Exact.parse('200'), unit: FoodUnit.g),
        _stateError('LEGACY_REQUEST_REVIEW_REQUIRED'));
    await expectLater(
        service.releaseReservation(
            requestId: 'old-release',
            batchId: 'b',
            allocationId: 'different-absent-allocation',
            expectedRevision: 2),
        _stateError('LEGACY_REQUEST_REVIEW_REQUIRED'));
    expect((await workspace.read('batch', 'b'))!.revision, 3);
    expect((await workspace.read('batch', 'b'))!.data['allocations'], isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });
  test('legacy consumption receipt cannot replay an unverified reservation',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final original = (await workspace.read('batch', 'b'))!;
    await workspace.put(
        requestId: 'stock:old-meal',
        collection: 'batch',
        id: 'b',
        expectedRevision: 1,
        data: {
          ...original.data,
          'allocations': [
            {
              'id': 'old-meal',
              'amount': Exact.parse('200').toJson(),
              'status': 'consumed'
            }
          ]
        });
    final now = DateTime.utc(2026);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'old-entry',
        requestId: 'old-meal',
        diaryDate: DiaryDate(2026, 1, 1),
        stamp: EventStamp(instant: now, offsetMinutes: 0),
        channel: EntryChannel.manual,
        recordedAt: now,
        items: [
          LoggedItem(name: 'Soup', grams: 200, nutrients: NutrientProfile({}))
        ]));
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    await expectLater(
        service.consumeAmount(
            requestId: 'old-meal',
            batchId: 'b',
            expectedRevision: 1,
            amount: Exact.parse('200'), unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'unverified'),
        _stateError('LEGACY_REQUEST_REVIEW_REQUIRED'));
    expect((await workspace.read('batch', 'b'))!.revision, 2);
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });
  test('serving stock spends exact portions without inventing grams', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    // A measured weight may be stored for information, but serving stock must
    // never derive its portion from it.
    final workspace = await _seedServingBatch(db, finishedWeightG: '900');
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    expect(
        await service.reserveAmount(
            requestId: 'reserve-a',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('2'),
            unit: FoodUnit.serving),
        2);
    expect(await db.select(db.logEntries).get(), isEmpty);
    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.data['unit'], 'serving');
    var allocation = _allocationsOf(doc).single;
    expect(allocation['id'], 'plan-a');
    expect(allocation['status'], 'planned');
    expect(_amountOf(allocation), Exact.parse('2'));

    final factor = Exact.parse('2') / Exact.parse('3');
    final entry = await service.consumeAmount(
        requestId: 'meal-a',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('2'),
        unit: FoodUnit.serving,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-a');
    // The recipe provides 60 g protein across three servings; two portions are
    // exactly two thirds, no gram conversion involved.
    expect(entry.nutrientSum(NutrientKey.proteinG).value, 40);
    final item = entry.items.single;
    expect(item.grams, isNull);
    expect(item.quantity!.unit, FoodUnit.g);
    expect(item.quantity!.value, Exact.parse('100') * factor);
    final source = item.sourceSnapshot!;
    expect(source['consumedBatchUnit'], 'serving');
    expect(source['consumedBatchServings'], Exact.parse('2').toJson());
    expect(source.containsKey('consumedBatchGrams'), isFalse);
    expect(source.containsKey('finishedWeightG'), isFalse);
    expect(source['recipeServings'], Exact.parse('3').toJson());
    expect(source['allocationScale'], factor.toJson());
    expect(source['reservedAllocationId'], 'plan-a');
    expect(source['batchRevision'], 2);

    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 3);
    allocation = _allocationsOf(doc).single;
    expect(allocation['status'], 'consumed');
    expect(allocation['intakeRequestId'], 'meal-a');
    expect(_amountOf(allocation), Exact.parse('2'));

    // A retry replays the same intake without spending stock twice.
    final retry = await service.consumeAmount(
        requestId: 'meal-a',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('2'),
        unit: FoodUnit.serving,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-a');
    expect(retry.id, entry.id);
    expect(await db.select(db.logEntries).get(), hasLength(1));
    expect((await workspace.read('batch', 'b'))!.revision, 3);

    // The original reservation request still replays its recorded revision
    // after the stock moved on; a different payload under that id is rejected.
    expect(
        await service.reserveAmount(
            requestId: 'reserve-a',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('2'),
            unit: FoodUnit.serving),
        2);
    await expectLater(
        service.reserveAmount(
            requestId: 'reserve-a',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving),
        _stateError('REQUEST_ID_REUSED'));

    // Unreserved consumption spends the remaining exact serving.
    final remaining = await service.consumeAmount(
        requestId: 'meal-b',
        batchId: 'b',
        expectedRevision: 3,
        amount: Exact.parse('1'),
        unit: FoodUnit.serving,
        offsetMinutes: 0,
        confirmed: true);
    expect(remaining.nutrientSum(NutrientKey.proteinG).value, 20);
    expect(remaining.items.single.sourceSnapshot!['consumedBatchServings'],
        Exact.parse('1').toJson());
    expect(
        _allocationsOf((await workspace.read('batch', 'b'))!)
            .fold<Exact>(Exact.zero, (sum, a) => sum + _amountOf(a)),
        Exact.parse('3'));
    // Unreserved consumption has no separate reservation link: its allocation
    // identity is the intake request id itself.
    final unreserved = _allocationsOf((await workspace.read('batch', 'b'))!)
        .singleWhere((a) => a['id'] == 'meal-b');
    expect(unreserved['status'], 'consumed');
    expect(unreserved['intakeRequestId'], isNull);
    // The batch is fully spent: 0 servings remain, not a converted mass.
    await expectLater(
        service.consumeAmount(
            requestId: 'meal-c',
            batchId: 'b',
            expectedRevision: 4,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('BATCH_OVERALLOCATED'));
    expect(await DriftEntryRepository(db).findByRequestId('meal-c'), isNull);
    expect(await db.select(db.logEntries).get(), hasLength(2));
  });
  test('serving stock is finite under concurrency and unit mismatch is safe',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _seedServingBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());

    final outcomes = await Future.wait([
      _outcome(service.reserveAmount(
          requestId: 'reserve-a',
          batchId: 'b',
          allocationId: 'plan-a',
          expectedRevision: 1,
          amount: Exact.parse('2'),
          unit: FoodUnit.serving)),
      _outcome(service.reserveAmount(
          requestId: 'reserve-b',
          batchId: 'b',
          allocationId: 'plan-b',
          expectedRevision: 1,
          amount: Exact.parse('2'),
          unit: FoodUnit.serving))
    ]);
    expect(outcomes.whereType<int>().toList(), [2]);
    final winnerIndex = outcomes.indexOf(2);
    final winner = winnerIndex == 0 ? 'plan-a' : 'plan-b';
    final loser = winner == 'plan-a' ? 'plan-b' : 'plan-a';
    final rejected = outcomes.whereType<StateError>().single;
    expect(rejected.message, 'STALE_BATCH');
    // Even at the winner's revision, 2 + 2 servings cannot fit in 3.
    await expectLater(
        service.reserveAmount(
            requestId: 'retry-$loser',
            batchId: 'b',
            allocationId: loser,
            expectedRevision: 2,
            amount: Exact.parse('2'),
            unit: FoodUnit.serving),
        _stateError('BATCH_OVERALLOCATED'));
    final doc = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(doc.revision, 2);
    expect(_allocationsOf(doc).single['id'], winner);

    // Gram and serving stock never substitute for each other.
    await expectLater(
        service.reserveAmount(
            requestId: 'as-grams',
            batchId: 'b',
            allocationId: 'plan-g',
            expectedRevision: 2,
            amount: Exact.parse('100'),
            unit: FoodUnit.g),
        _stateError('BATCH_UNIT_MISMATCH'));
    await expectLater(
        service.consumeAmount(
            requestId: 'as-grams',
            batchId: 'b',
            expectedRevision: 2,
            amount: Exact.parse('100'),
            unit: FoodUnit.g,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('BATCH_UNIT_MISMATCH'));
    await expectLater(
        service.reserveAmount(
            requestId: 'as-ml',
            batchId: 'b',
            allocationId: 'plan-ml',
            expectedRevision: 2,
            amount: Exact.parse('1'),
            unit: FoodUnit.ml),
        throwsArgumentError);
    expect(await _hasCommand(db, 'batch-reserve:as-grams'), isFalse);
    expect(await _hasCommand(db, 'batch-consume:as-grams'), isFalse);
    expect(await db.select(db.logEntries).get(), isEmpty);
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 2);

    // Releasing frees the exact serving count for re-use.
    expect(
        await service.releaseReservation(
            requestId: 'release-a',
            batchId: 'b',
            allocationId: winner,
            expectedRevision: 2),
        3);
    expect(
        await service.reserveAmount(
            requestId: 'reserve-c',
            batchId: 'b',
            allocationId: 'plan-c',
            expectedRevision: 3,
            amount: Exact.parse('3'),
            unit: FoodUnit.serving),
        4);
    expect(
        _amountOf(_allocationsOf((await LocalWorkspace(db).read('batch', 'b'))!)
            .single),
        Exact.parse('3'));

    // A gram batch rejects a serving reservation instead of guessing grams.
    await _seedBatch(db, id: 'g', requestId: 'create-g');
    await expectLater(
        service.reserveAmount(
            requestId: 'serving-on-gram',
            batchId: 'g',
            allocationId: 'plan-s',
            expectedRevision: 1,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving),
        _stateError('BATCH_UNIT_MISMATCH'));
    expect(_allocationsOf((await LocalWorkspace(db).read('batch', 'g'))!),
        isEmpty);
  });
  test('legacy gram receipts replay only as gram stock', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    final grams = Exact.parse('200');

    // A reservation receipt written before stock became unit-explicit.
    await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: 'batch-reserve:legacy-reserve',
        resultJson: jsonEncode({
          'operation': 'reserve',
          'batchId': 'b',
          'allocationId': 'plan-legacy',
          'expectedRevision': 1,
          'grams': grams.toJson(),
          'revision': 2
        })));
    expect(
        await service.reserveAmount(
            requestId: 'legacy-reserve',
            batchId: 'b',
            allocationId: 'plan-legacy',
            expectedRevision: 1,
            amount: grams,
            unit: FoodUnit.g),
        2);
    // The same receipt can never satisfy a serving retry.
    await expectLater(
        service.reserveAmount(
            requestId: 'legacy-reserve',
            batchId: 'b',
            allocationId: 'plan-legacy',
            expectedRevision: 1,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving),
        _stateError('REQUEST_ID_REUSED'));
    expect(_allocationsOf((await workspace.read('batch', 'b'))!), isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);

    // A consumption receipt written before stock became unit-explicit.
    final now = DateTime.utc(2026);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'legacy-entry',
        requestId: 'legacy-meal',
        diaryDate: DiaryDate(2026, 1, 1),
        stamp: EventStamp(instant: now, offsetMinutes: 0),
        channel: EntryChannel.manual,
        recordedAt: now,
        items: [LoggedItem(name: 'Soup', grams: 200, nutrients: NutrientProfile({}))]));
    await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: 'batch-consume:legacy-meal',
        resultJson: jsonEncode({
          'operation': 'consume',
          'batchId': 'b',
          'expectedRevision': 1,
          'grams': grams.toJson(),
          'offsetMinutes': 0,
          'reservedAllocationId': null,
          'entryId': 'legacy-entry',
          'revision': 2
        })));
    final replayed = await service.consumeAmount(
        requestId: 'legacy-meal',
        batchId: 'b',
        expectedRevision: 1,
        amount: grams,
        unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(replayed.id, 'legacy-entry');
    await expectLater(
        service.consumeAmount(
            requestId: 'legacy-meal',
            batchId: 'b',
            expectedRevision: 1,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving,
            offsetMinutes: 0,
            confirmed: true),
        _stateError('REQUEST_ID_REUSED'));
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });
  test('serving corrections scale every ingredient and refuse over-allocation',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedServingBatch(db,
        recipe: _twoIngredientRecipe(), available: '3', servings: '3');
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    final entries = DriftEntryRepository(db);

    expect(
        await service.reserveAmount(
            requestId: 'reserve-a',
            batchId: 'b',
            allocationId: 'plan-a',
            expectedRevision: 1,
            amount: Exact.parse('2'),
            unit: FoodUnit.serving),
        2);
    final entry = await service.consumeAmount(
        requestId: 'meal-a',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('2'),
        unit: FoodUnit.serving,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-a');
    expect(entry.revision, 1);
    final factor = Exact.parse('2') / Exact.parse('3');
    expect(entry.items, hasLength(2));
    expect(entry.nutrientSum(NutrientKey.proteinG).value, 50);
    for (final item in entry.items) {
      expect(item.sourceSnapshot!['consumedBatchUnit'], 'serving');
      expect(item.sourceSnapshot!['allocationScale'], factor.toJson());
    }

    expect(
        await entries.revise(ReviseEntryCommand(
            requestId: 'grow',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('1.5'))),
        2);
    var doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 4);
    expect(_amountOf(_allocationsOf(doc).single), Exact.parse('3'));
    final corrected = (await entries.findByRequestId('meal-a'))!;
    expect(corrected.nutrientSum(NutrientKey.proteinG).value, 75);
    expect(corrected.items, hasLength(2));
    final byName = {
      for (final item in corrected.items) item.name: item.sourceSnapshot!
    };
    for (final name in ['Ingredient A', 'Ingredient B']) {
      final source = byName[name]!;
      expect(source['consumedBatchUnit'], 'serving');
      expect(source['consumedBatchServings'], Exact.parse('3').toJson());
      expect(source['allocationScale'], Exact.one.toJson());
      expect(source['recipeServings'], Exact.parse('3').toJson());
      expect(source['batchRevision'], 4);
      expect(source['reservedAllocationId'], 'plan-a');
      expect(source.containsKey('consumedBatchGrams'), isFalse);
    }
    // Raw ingredient quantities stay the recipe definition, not the eaten mass.
    expect(byName['Ingredient A']!['ingredientQuantityG'],
        Exact.parse('100').toJson());
    expect(byName['Ingredient B']!['ingredientQuantityG'],
        Exact.parse('50').toJson());
    final itemsByName = {
      for (final item in corrected.items) item.name: item
    };
    expect(itemsByName['Ingredient A']!.quantity!.value, Exact.parse('100'));
    expect(itemsByName['Ingredient B']!.quantity!.value, Exact.parse('50'));

    // Six servings cannot fit in three; the correction is rejected whole.
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'too-big',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('2'))),
        _stateError('BATCH_OVERALLOCATED'));
    expect((await entries.findByRequestId('meal-a'))!.revision, 2);
    doc = (await workspace.read('batch', 'b'))!;
    expect(doc.revision, 4);
    expect(_amountOf(_allocationsOf(doc).single), Exact.parse('3'));
    expect(await workspace.read('entry-revision', '${entry.id}:2'), isNull);
    expect(await _hasCommand(db, 'history:too-big'), isFalse);
  });
  test('restored serving receipts prevent duplicate consumption', () async {
    final source = AppDatabase.memory();
    final restored = AppDatabase.memory();
    addTearDown(source.close);
    addTearDown(restored.close);
    await _seedServingBatch(source);
    final service =
        BatchService(source, const SystemClock(), SequentialIdGenerator());
    expect(
        await service.reserveAmount(
            requestId: 'reserve-serving',
            batchId: 'b',
            allocationId: 'plan-serving',
            expectedRevision: 1,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving),
        2);
    final entry = await service.consumeAmount(
        requestId: 'meal-serving',
        batchId: 'b',
        expectedRevision: 2,
        amount: Exact.parse('1'),
        unit: FoodUnit.serving,
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-serving');
    final archive = await ArchiveService(source).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);
    final retried = await BatchService(
            restored, const SystemClock(), SequentialIdGenerator())
        .consumeAmount(
            requestId: 'meal-serving',
            batchId: 'b',
            expectedRevision: 2,
            amount: Exact.parse('1'),
            unit: FoodUnit.serving,
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'plan-serving');
    expect(retried.id, entry.id);
    expect(retried.items.single.sourceSnapshot!['consumedBatchUnit'], 'serving');
    expect(retried.items.single.sourceSnapshot!['consumedBatchServings'],
        Exact.parse('1').toJson());
    expect(retried.items.single.sourceSnapshot!['reservedAllocationId'],
        'plan-serving');
    expect(await restored.select(restored.logEntries).get(), hasLength(1));
    final batch = (await LocalWorkspace(restored).read('batch', 'b'))!;
    final allocation = _allocationsOf(batch).single;
    expect(allocation['id'], 'plan-serving');
    expect(allocation['status'], 'consumed');
    expect(_amountOf(allocation), Exact.parse('1'));
    expect(allocation['intakeRequestId'], 'meal-serving');
  });
  test('mixed or mismatched snapshot stock units fail closed on correction',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = await _seedServingBatch(db);
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    final entries = DriftEntryRepository(db);
    final entry = await service.consumeAmount(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 1,
        amount: Exact.parse('1'),
        unit: FoodUnit.serving,
        offsetMinutes: 0,
        confirmed: true);
    final itemId = (await db.select(db.logEntryItems).get()).single.id;

    // A snapshot carrying both amount keys is ambiguous and must not be scaled.
    final mixed = Map<String, Object?>.from(entry.items.single.sourceSnapshot!);
    mixed['consumedBatchGrams'] = Exact.parse('100').toJson();
    await db.customStatement(
        'UPDATE log_entry_items SET source_json = ? WHERE id = ?',
        [jsonEncode(mixed), itemId]);
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'mixed',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('1.5'))),
        _stateError('BATCH_RECONCILIATION_REQUIRED'));

    // A serving amount relabelled as grams disagrees with the live batch unit.
    final wrongUnit =
        Map<String, Object?>.from(entry.items.single.sourceSnapshot!);
    wrongUnit['consumedBatchUnit'] = 'g';
    await db.customStatement(
        'UPDATE log_entry_items SET source_json = ? WHERE id = ?',
        [jsonEncode(wrongUnit), itemId]);
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'wrong-unit',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('1.5'))),
        _stateError('BATCH_RECONCILIATION_REQUIRED'));

    expect((await entries.findByRequestId('meal'))!.revision, 1);
    expect((await workspace.read('batch', 'b'))!.revision, 2);
    expect(await workspace.read('entry-revision', '${entry.id}:1'), isNull);
  });
}

RecipeVersion _recipe({String servings = '3'}) => RecipeVersion(
    id: 'r',
    revision: 1,
    name: 'Soup',
    servings: Exact.parse(servings),
    minutes: 10,
    ingredients: [
      RecipeIngredient(
          Food(
              id: 'f',
              name: 'Ingredient',
              per100g: NutrientProfile(
                  {NutrientKey.proteinG: NutrientReported(60)}),
              source: const FoodSource(dataset: 'fixture', datasetId: '1')),
          Exact.parse('100'))
    ]);

RecipeVersion _twoIngredientRecipe({String servings = '3'}) => RecipeVersion(
    id: 'r2',
    revision: 1,
    name: 'Stew',
    servings: Exact.parse(servings),
    minutes: 20,
    ingredients: [
      RecipeIngredient(
          Food(
              id: 'f1',
              name: 'Ingredient A',
              per100g: NutrientProfile(
                  {NutrientKey.proteinG: NutrientReported(60)}),
              source: const FoodSource(dataset: 'fixture', datasetId: '1')),
          Exact.parse('100')),
      RecipeIngredient(
          Food(
              id: 'f2',
              name: 'Ingredient B',
              per100g: NutrientProfile(
                  {NutrientKey.proteinG: NutrientReported(30)}),
              source: const FoodSource(dataset: 'fixture', datasetId: '2')),
          Exact.parse('50'))
    ]);

Future<LocalWorkspace> _seedBatch(AppDatabase db,
    {String id = 'b',
    String requestId = 'create',
    String available = '600',
    String finishedWeight = '600',
    RecipeVersion? recipe}) async {
  final workspace = LocalWorkspace(db);
  await workspace.put(
      requestId: requestId,
      collection: 'batch',
      id: id,
      expectedRevision: 0,
      data: {
        'recipe': recipeSnapshot(recipe ?? _recipe()),
        'available': Exact.parse(available).toJson(),
        'finishedWeightG': Exact.parse(finishedWeight).toJson(),
        'unit': 'g',
        'allocations': <Object?>[]
      });
  return workspace;
}

Future<LocalWorkspace> _seedServingBatch(AppDatabase db,
    {String id = 'b',
    String requestId = 'create',
    String available = '3',
    String servings = '3',
    RecipeVersion? recipe,
    String? finishedWeightG}) async {
  final workspace = LocalWorkspace(db);
  await workspace.put(
      requestId: requestId,
      collection: 'batch',
      id: id,
      expectedRevision: 0,
      data: {
        'recipe': recipeSnapshot(recipe ?? _recipe(servings: servings)),
        'available': Exact.parse(available).toJson(),
        if (finishedWeightG != null)
          'finishedWeightG': Exact.parse(finishedWeightG).toJson(),
        'unit': 'serving',
        'allocations': <Object?>[]
      });
  return workspace;
}

List<Map<String, Object?>> _allocationsOf(StoredDocument doc) => [
      for (final raw in doc.data['allocations']! as List)
        Map<String, Object?>.from(raw as Map)
    ];

Exact _amountOf(Map<String, Object?> allocation) =>
    Exact.fromJson(Map<String, Object?>.from(allocation['amount']! as Map));

Future<bool> _hasCommand(AppDatabase db, String requestId) async {
  final row = await (db.select(db.appliedCommands)
        ..where((t) => t.requestId.equals(requestId)))
      .getSingleOrNull();
  return row != null;
}

/// Captures either an accepted revision or the rejection, in call order.
Future<Object?> _outcome(Future<int> future) async {
  try {
    return await future;
  } on Object catch (error) {
    return error;
  }
}

Matcher _stateError(String message) =>
    throwsA(isA<StateError>().having((error) => error.message, 'message', message));

final class _FixedIdGenerator implements IdGenerator {
  const _FixedIdGenerator(this.value);
  final String value;
  @override
  String next() => value;
}
