import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('full-day dated schedules exclude only the named meal', () {
    final schedule = PlanSchedule.fromMetadata({
      'schemaVersion': 2, 'startDate': '2026-11-10', 'days': 7,
      'labels': ['breakfast', 'lunch', 'dinner'],
      'excludedSlotIds': ['2026-11-11:lunch'],
    })!;
    expect(schedule.generatedSlots, hasLength(21));
    expect(schedule.slots, hasLength(20));
    expect(schedule.slots.map((slot) => slot.id),
        containsAll(['2026-11-11:breakfast', '2026-11-11:dinner']));
    expect(schedule.slots.map((slot) => slot.id),
        isNot(contains('2026-11-11:lunch')));
    expect(schedule.slots.last.date, '2026-11-16');
  });

  test('separate week documents cannot claim one batch allocation', () async {
    final db = _freshDb();
    final recipe = _recipe('multi-week');
    await _seedBatch(db, recipe: recipe);
    final first = PlanService(db, const SystemClock(), SequentialIdGenerator(),
        documentId: 'week:2026-11-10');
    final next = PlanService(db, const SystemClock(), SequentialIdGenerator(),
        documentId: 'week:2026-11-17');
    final saved = await first.save(requestId: 'week-one',
        expectedPlanRevision: 0, meals: [
          _meal('first', '2026-11-10', recipe, '1',
              batchId: 'b', allocationId: 'owned-allocation')
        ]);
    await expectLater(next.save(requestId: 'week-two',
        expectedPlanRevision: 0, meals: [
          _meal('next', '2026-11-17', recipe, '1',
              batchId: 'b', batchRevision: saved.batchRevisions['b']!,
              allocationId: 'owned-allocation')
        ]), _planError('BATCH_ALLOCATION_ALREADY_PLANNED'));
    expect((await first.load())!.meals.single.slot.id, 'first');
    expect(await next.load(), isNull);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, saved.batchRevisions['b']);
  });

  test('plan saves reserve exact cooked stock without writing intake', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b1', recipe: recipe, available: '600', finishedWeight: '600');
    await _seedBatch(db,
        id: 'b2', recipe: recipe, available: '500', finishedWeight: '500');
    final result = await _service(db).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b1', allocationId: 'plan-1'),
        _meal('d2', '2026-11-11', recipe, '1',
            batchId: 'b2', allocationId: 'plan-2'),
      ],
    );

    expect(result.revision, 1);
    expect(result.batchRevisions, {'b1': 2, 'b2': 2});
    expect(result.meals.map((meal) => meal.batchUse!.batchRevision), [2, 2]);
    expect(await db.select(db.logEntries).get(), isEmpty);

    final b1 = (await LocalWorkspace(db).read('batch', 'b1'))!;
    final b2 = (await LocalWorkspace(db).read('batch', 'b2'))!;
    expect(b1.revision, 2);
    expect(b2.revision, 2);
    expect(_amountOf(_allocations(b1).single), Exact.parse('400'));
    expect(_amountOf(_allocations(b2).single),
        Exact.parse('500') / Exact.parse('3'));
    expect(_allocations(b1).single['status'], 'planned');

    final plan = await _service(db).load();
    expect(plan!.revision, 1);
    expect(plan.seed, 7);
    expect(plan.policyVersion, 'planner-v3');
    expect(plan.meals, hasLength(2));
    expect(plan.meals.map((meal) => meal.batchUse!.allocationId),
        ['plan-1', 'plan-2']);
    expect((plan.document['meals']! as List<Object?>), hasLength(2));
  });

  test('reservations on one batch share the final revision and stock is exact',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1'),
        _meal('d2', '2026-11-11', recipe, '1',
            batchId: 'b', allocationId: 'plan-2'),
      ],
    );
    expect(first.batchRevisions, {'b': 3});
    expect(first.meals.every((meal) => meal.batchUse!.batchRevision == 3),
        isTrue);
    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 3);
    expect(_allocations(batch).fold<Exact>(
        Exact.zero, (sum, allocation) => sum + _amountOf(allocation)),
        Exact.parse('400'));

    await BatchService(db, const SystemClock(), SequentialIdGenerator())
        .reserveAmount(
            requestId: 'other',
            batchId: 'b',
            allocationId: 'other',
            expectedRevision: 3,
            amount: Exact.parse('100'),
            unit: FoodUnit.g);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 4);

    // The stored use revisions are stale but the reservations are live; the
    // save accepts them and refreshes every pointer to the final revision.
    final second = await service.save(
        requestId: 'save-2', expectedPlanRevision: 1, meals: first.meals);
    expect(second.revision, 2);
    expect(second.batchRevisions, {'b': 4});
    expect(second.meals.every((meal) => meal.batchUse!.batchRevision == 4),
        isTrue);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 4);
    expect(_allocations(batch), hasLength(3));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('pin edits keep reservations and removed meals release only unspent stock',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(first.revision, 1);
    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 2);

    final pinned = await service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1', pinned: true)
      ],
    );
    expect(pinned.revision, 2);
    expect(pinned.batchRevisions, {'b': 2});
    expect(pinned.meals.single.pinned, isTrue);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 2);
    expect(_allocations(batch).single['id'], 'plan-1');

    final cleared =
        await service.save(requestId: 'save-3', expectedPlanRevision: 2, meals: const []);
    expect(cleared.revision, 3);
    expect(cleared.batchRevisions, {'b': 3});
    expect(cleared.meals, isEmpty);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 3);
    expect(_allocations(batch), isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('replacing a meal releases the old reservation and reserves the new one',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-a')
      ],
    );
    final replaced = await service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-b', batchRevision: 2)
      ],
    );
    expect(replaced.revision, 2);
    expect(replaced.batchRevisions, {'b': 4});
    expect(replaced.meals.single.batchUse!.allocationId, 'plan-b');
    expect(replaced.meals.single.batchUse!.batchRevision, 4);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 4);
    final allocations = _allocations(batch);
    expect(allocations.map((allocation) => allocation['id']), ['plan-b']);
    expect(_amountOf(allocations.single), Exact.parse('400'));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('a kept consumed allocation stays accounted exactly once', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        allocations: [
          _alloc('plan-1', '400', 'consumed', intakeRequestId: 'meal-1')
        ]);
    await _seedPlan(db, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-1')
    ]);
    final service = _service(db);
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(first.revision, 2);
    expect(first.batchRevisions, {'b': 1});
    expect(first.meals.single.batchUse!.allocationId, 'plan-1');
    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    var allocations = _allocations(batch);
    expect(allocations, hasLength(1));
    expect(allocations.single['status'], 'consumed');
    expect(_amountOf(allocations.single), Exact.parse('400'));
    expect(await db.select(db.logEntries).get(), isEmpty);

    final second = await service.save(
      requestId: 'save-2',
      expectedPlanRevision: 2,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(second.revision, 3);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    allocations = _allocations(batch);
    expect(allocations, hasLength(1));
    expect(_amountOf(allocations.single), Exact.parse('400'));

    // Re-consuming the same portion is refused and writes no second entry.
    await expectLater(
        BatchService(db, const SystemClock(), SequentialIdGenerator())
            .consumeAmount(
                requestId: 'meal-2',
                batchId: 'b',
                expectedRevision: 1,
                amount: Exact.parse('400'),
                unit: FoodUnit.g,
                offsetMinutes: 0,
                confirmed: true,
                reservedAllocationId: 'plan-1'),
        throwsStateError);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('a new plan use cannot claim a consumed allocation', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        allocations: [
          _alloc('plan-1', '400', 'consumed', intakeRequestId: 'meal-1')
        ]);
    await expectLater(
        _service(db).save(
          requestId: 'save-1',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-1')
          ],
        ),
        _planError('PLAN_BATCH_USE_CONSUMED'));
    expect(await _service(db).load(), isNull);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch).single['status'], 'consumed');
    expect(await _planReceipts(db), 0);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('dropping a consumed plan use never releases consumed stock', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        allocations: [_alloc('plan-1', '400', 'consumed')]);
    await _seedPlan(db, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-1')
    ]);
    final result = await _service(db)
        .save(requestId: 'save-1', expectedPlanRevision: 1, meals: const []);
    expect(result.revision, 2);
    expect(result.batchRevisions, {'b': 1});
    expect(result.meals, isEmpty);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    final allocations = _allocations(batch);
    expect(allocations.single['status'], 'consumed');
    expect(_amountOf(allocations.single), Exact.parse('400'));
    final receiptIds =
        (await db.select(db.appliedCommands).get()).map((row) => row.requestId);
    expect(receiptIds.any((id) => id.startsWith('batch-release:plan-release:')),
        isFalse);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('legacy re-keyed consumption is reconciled only from a diary snapshot',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        allocations: [_alloc('meal-legacy', '400', 'consumed')]);
    await _seedIntake(db,
        entryId: 'entry-1',
        requestId: 'meal-legacy',
        batchId: 'b',
        reservedAllocationId: 'plan-1',
        grams: '400');
    await _seedPlan(db, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-1')
    ]);
    final service = _service(db);

    final reconciled = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(reconciled.revision, 2);
    expect(reconciled.meals.single.batchUse!.allocationId, 'meal-legacy');
    expect(reconciled.meals.single.batchUse!.batchRevision, 1);
    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    var allocations = _allocations(batch);
    expect(allocations, hasLength(1));
    expect(allocations.single['id'], 'meal-legacy');
    expect(allocations.single['status'], 'consumed');
    expect(_amountOf(allocations.single), Exact.parse('400'));
    expect(await db.select(db.logEntries).get(), hasLength(1));

    final reloaded = await service.load();
    final again = await service.save(
        requestId: 'save-2',
        expectedPlanRevision: 2,
        meals: reloaded!.meals);
    expect(again.revision, 3);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    allocations = _allocations(batch);
    expect(allocations, hasLength(1));
    expect(_amountOf(allocations.single), Exact.parse('400'));
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });

  test('unverifiable or ambiguous legacy consumption fails closed', () async {
    final recipe = _recipe('r1');
    final missingDb = _freshDb();
    await _seedBatch(missingDb,
        id: 'b',
        recipe: recipe,
        allocations: [_alloc('meal-legacy', '400', 'consumed')]);
    await _seedPlan(missingDb, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-1')
    ]);
    await expectLater(
        _service(missingDb).save(
          requestId: 'save-1',
          expectedPlanRevision: 1,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-1')
          ],
        ),
        _planError('PLAN_BATCH_ALLOCATION_MISSING'));
    expect((await _service(missingDb).load())!.revision, 1);
    expect((await LocalWorkspace(missingDb).read('batch', 'b'))!.revision, 1);
    expect(await _planReceipts(missingDb), 0);

    final ambiguousDb = _freshDb();
    await _seedBatch(ambiguousDb,
        id: 'b',
        recipe: recipe,
        available: '1200',
        allocations: [
          _alloc('meal-a', '400', 'consumed'),
          _alloc('meal-b', '400', 'consumed')
        ]);
    await _seedIntake(ambiguousDb,
        entryId: 'entry-a',
        requestId: 'meal-a',
        batchId: 'b',
        reservedAllocationId: 'plan-1',
        grams: '400');
    await _seedIntake(ambiguousDb,
        entryId: 'entry-b',
        requestId: 'meal-b',
        batchId: 'b',
        reservedAllocationId: 'plan-1',
        grams: '400');
    await _seedPlan(ambiguousDb, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-1')
    ]);
    await expectLater(
        _service(ambiguousDb).save(
          requestId: 'save-1',
          expectedPlanRevision: 1,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-1')
          ],
        ),
        _planError('PLAN_LEGACY_AMBIGUOUS'));
    expect((await _service(ambiguousDb).load())!.revision, 1);
    expect((await LocalWorkspace(ambiguousDb).read('batch', 'b'))!.revision, 1);
    expect(await _planReceipts(ambiguousDb), 0);
  });

  test('stale newly selected batch stock is rejected and rolled back',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    final batches =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    await batches.reserveAmount(
        requestId: 'other',
        batchId: 'b',
        allocationId: 'other',
        expectedRevision: 1,
        amount: Exact.parse('100'),
        unit: FoodUnit.g);
    // The batch is now revision 2, but this new selection was read at 1.
    final stale = await _outcome(service.save(
      requestId: 'stale-new',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1', batchRevision: 1)
      ],
    ));
    expect(
        stale,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'STALE_BATCH'));
    expect(await service.load(), isNull);
    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 2);
    expect(_allocations(batch).map((allocation) => allocation['id']).toList(),
        ['other']);
    expect(await _planReceipts(db), 0);

    // A changed selection on an existing plan is new stock too. Its pointer is
    // stale, so the old reservation is restored when the save is rejected.
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1', batchRevision: 2)
      ],
    );
    expect(first.revision, 1);
    await batches.reserveAmount(
        requestId: 'other-2',
        batchId: 'b',
        allocationId: 'other-2',
        expectedRevision: 3,
        amount: Exact.parse('50'),
        unit: FoodUnit.g);
    final changed = await _outcome(service.save(
      requestId: 'stale-change',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-2', batchRevision: 3)
      ],
    ));
    expect(
        changed,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'STALE_BATCH'));
    expect((await service.load())!.revision, 1);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 4);
    final allocationIds =
        _allocations(batch).map((allocation) => allocation['id']).toList();
    expect(allocationIds, hasLength(3));
    expect(allocationIds,
        containsAll(<Object?>['plan-1', 'other', 'other-2']));
    expect(allocationIds, isNot(contains('plan-2')));
    expect(await _planReceipts(db), 2);
  });

  test('stale plans and future batch revisions are rejected before writes',
      () async {
    final recipe = _recipe('r1');
    final staleDb = _freshDb();
    await _seedPlan(staleDb, meals: const []);
    await expectLater(
        _service(staleDb).save(
            requestId: 'stale', expectedPlanRevision: 0, meals: const []),
        _planError('STALE_PLAN'));
    expect((await _service(staleDb).load())!.revision, 1);
    expect(await _planReceipts(staleDb), 0);

    final futureDb = _freshDb();
    await _seedBatch(futureDb, id: 'b', recipe: recipe);
    await expectLater(
        _service(futureDb).save(
          requestId: 'future',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-1', batchRevision: 99)
          ],
        ),
        _planError('PLAN_BATCH_REVISION_MISMATCH'));
    expect(await _service(futureDb).load(), isNull);
    expect((await LocalWorkspace(futureDb).read('batch', 'b'))!.revision, 1);
    expect(await _planReceipts(futureDb), 0);
  });

  test('identical retries replay and conflicting request reuse is rejected',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    final original = await service.save(
      requestId: 'retry',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(original.revision, 1);
    await service.save(
        requestId: 'later', expectedPlanRevision: 1, meals: const []);
    expect((await service.load())!.revision, 2);
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 3);

    // The original request replays its recorded result even though the plan
    // and batch moved on; it must not re-reserve the released allocation.
    final replay = await service.save(
      requestId: 'retry',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(replay.revision, 1);
    expect(replay.batchRevisions, {'b': 2});
    expect(replay.meals.single.batchUse!.allocationId, 'plan-1');
    expect((await service.load())!.revision, 2);
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 3);
    expect(_allocations((await LocalWorkspace(db).read('batch', 'b'))!),
        isEmpty);

    await expectLater(
        service.save(
            requestId: 'retry', expectedPlanRevision: 1, meals: const []),
        _planError('REQUEST_ID_REUSED'));
    await expectLater(
        service.save(
          requestId: 'retry',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-2')
          ],
        ),
        _planError('REQUEST_ID_REUSED'));
    await expectLater(
        service.save(
          requestId: 'retry',
          expectedPlanRevision: 0,
          seed: 9,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-1')
          ],
        ),
        _planError('REQUEST_ID_REUSED'));
    expect((await service.load())!.revision, 2);
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 3);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('a failed later batch rolls back earlier reservations and the plan',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b1', recipe: recipe, available: '600', finishedWeight: '600');
    await _seedBatch(db,
        id: 'b2', recipe: recipe, available: '200', finishedWeight: '600');
    final outcome = await _outcome(_service(db).save(
      requestId: 'rollback',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b1', allocationId: 'plan-1'),
        _meal('d2', '2026-11-11', recipe, '2',
            batchId: 'b2', allocationId: 'plan-2'),
      ],
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'BATCH_OVERALLOCATED'));
    expect(await _service(db).load(), isNull);
    for (final id in ['b1', 'b2']) {
      final batch = (await LocalWorkspace(db).read('batch', id))!;
      expect(batch.revision, 1);
      expect(_allocations(batch), isEmpty);
    }
    expect(await _planReceipts(db), 0);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('a failed reservation rolls back releases made for removed meals',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-a')
      ],
    );
    final before = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(before.revision, 2);

    final outcome = await _outcome(service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'ghost', allocationId: 'plan-ghost')
      ],
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_BATCH_MISSING'));
    final after = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(after.revision, 2);
    expect(_allocations(after).single['id'], 'plan-a');
    expect((await service.load())!.revision, 1);
    final receiptIds =
        (await db.select(db.appliedCommands).get()).map((row) => row.requestId);
    expect(receiptIds.contains('plan-save:save-2'), isFalse);
    expect(
        receiptIds.any(
            (id) => id.startsWith('batch-release:plan-release:save-2')),
        isFalse);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('duplicate and invalid plan requests are rejected before any write',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    await expectLater(
        service.save(
          requestId: 'duplicate-slot',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-1'),
            _meal('d1', '2026-11-11', recipe, '1',
                batchId: 'b', allocationId: 'plan-2'),
          ],
        ),
        _planError('DUPLICATE_MEAL_SLOT'));
    await expectLater(
        service.save(
          requestId: 'duplicate-use',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-1'),
            _meal('d2', '2026-11-11', recipe, '1',
                batchId: 'b', allocationId: 'plan-1'),
          ],
        ),
        _planError('DUPLICATE_BATCH_USE'));
    await expectLater(
        service.save(
          requestId: 'invalid-date',
          expectedPlanRevision: 0,
          meals: [_meal('d1', '2026-13-01', recipe, '1')],
        ),
        _planError('PLAN_INVALID_DATE'));
    await expectLater(
        service.save(
            requestId: 'reserved-metadata',
            expectedPlanRevision: 0,
            meals: const [],
            metadata: const {'meals': <Object?>[]}),
        throwsArgumentError);
    expect(await service.load(), isNull);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch), isEmpty);
    expect(await _planReceipts(db), 0);
  });

  test('legacy plan metadata and meals survive a save', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final schedule = <String, Object?>{
      'startDate': '2026-11-10',
      'days': 1,
      'label': 'Dinner',
      'portions': [Exact.one.toJson()],
    };
    await _seedPlan(db, meals: const [], extra: {
      'seed': 11,
      'policyVersion': 'planner-v1',
      'schedule': schedule,
      'constraints': <String, Object?>{
        'maximumMinutes': 45,
        'maximumRepeats': null,
        'energyMinimum': null,
        'energyMaximum': null,
      },
      'constraintRevision': 1,
      'acceptedRelaxations': <Object?>[],
      'relaxations': ['time'],
    });
    final service = _service(db);
    final loaded = await service.load();
    expect(loaded!.seed, 11);
    expect(loaded.policyVersion, 'planner-v1');
    expect(loaded.meals, isEmpty);

    final result = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: [_meal('Dinner:0', '2026-11-10', recipe, '1')],
      metadata: {
        'schedule': schedule,
        'constraints': <String, Object?>{
          'maximumMinutes': 30,
          'maximumRepeats': null,
          'energyMinimum': null,
          'energyMaximum': null,
        },
        'constraintRevision': 2,
        'acceptedRelaxations': <Object?>[],
      },
    );
    expect(result.revision, 2);
    expect(result.document['seed'], 11);
    expect(result.document['policyVersion'], 'planner-v1');
    expect((result.document['schedule']! as Map<String, Object?>)['days'], 1);
    expect(
        (result.document['constraints']!
            as Map<String, Object?>)['maximumMinutes'],
        30);
    expect(result.document['relaxations'], ['time']);
    expect(result.batchRevisions, isEmpty);
    final raw = (await LocalWorkspace(db).read('plan', 'current'))!;
    final storedMeals = raw.data['meals']! as List<Object?>;
    expect(storedMeals, hasLength(1));
    final storedMeal =
        Map<String, Object?>.from(storedMeals.single! as Map);
    expect(storedMeal.containsKey('batchUse'), isFalse);
    expect((await service.load())!.document['schedule'], schedule);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('plan save enforces persisted strict exclusions', () async {
    final excluded = _freshDb();
    final milk = _recipe('milk', allergens: {'milk'});
    await _seedBatch(excluded, id: 'b', recipe: milk);
    await LocalWorkspace(excluded).put(
      requestId: 'seed-safety',
      collection: 'profile',
      id: 'safety',
      expectedRevision: 0,
      data: const SafetyProfile(strictExclusions: {'milk'}).toJson(),
    );
    final metadata = <String, Object?>{
      ..._planMetadata(label: 'meal'),
      // Opaque caller metadata cannot relax the persisted profile.
      'strictExclusions': <String>[],
    };
    final outcome = await _outcome(_service(excluded).save(
      requestId: 'excluded',
      expectedPlanRevision: 0,
      meals: [
        _meal('meal:0', '2026-11-10', milk, '1',
            batchId: 'b', allocationId: 'plan-1')
      ],
      metadata: metadata,
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('EXCLUSION_CONFLICT'),
                'violations',
                isTrue));
    expect(await _service(excluded).load(), isNull);
    expect(await _planReceipts(excluded), 0);
    final batch = (await LocalWorkspace(excluded).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch), isEmpty);
    expect(await excluded.select(excluded.logEntries).get(), isEmpty);

    final unknown = _freshDb();
    final unknownRecipe = _recipe('unknown');
    await _seedRecipe(unknown, unknownRecipe);
    await LocalWorkspace(unknown).put(
      requestId: 'seed-safety',
      collection: 'profile',
      id: 'safety',
      expectedRevision: 0,
      data: const SafetyProfile(strictExclusions: {'milk'}).toJson(),
    );
    final unknownOutcome = await _outcome(_service(unknown).save(
      requestId: 'unknown',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', unknownRecipe, '1')],
      metadata: _planMetadata(label: 'meal'),
    ));
    expect(
        unknownOutcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('ALLERGEN_STATUS_UNKNOWN'),
                'violations',
                isTrue));
    expect(await _service(unknown).load(), isNull);
  });

  test('plan save rejects unavailable ingredients even when pinned', () async {
    final db = _freshDb();
    final recipe = _recipe('blocked');
    await _seedRecipe(db, recipe);
    final service = _service(db);
    final pinned = _meal('meal:0', '2026-11-10', recipe, '1', pinned: true);
    final base = _planMetadata(label: 'meal');
    final first = await service.save(
      requestId: 'pinned',
      expectedPlanRevision: 0,
      meals: [pinned],
      metadata: base,
    );
    expect(first.revision, 1);

    // The retained pinned meal becomes unavailable under a newly reviewed
    // revision; commit rejects it and the applied plan stays intact.
    final metadata = _planMetadata(
        label: 'meal', unavailableFoodIds: ['custom:blocked'], revision: 2);
    final outcome = await _outcome(service.save(
      requestId: 'unavailable',
      expectedPlanRevision: 1,
      meals: [pinned],
      metadata: metadata,
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('INGREDIENT_UNAVAILABLE'),
                'violations',
                isTrue));
    final stored = (await service.load())!;
    expect(stored.revision, 1);
    expect(stored.meals.single.pinned, isTrue);
    expect(
        (stored.document['constraints']! as Map<String, Object?>)
            .containsKey('unavailableFoodIds'),
        isFalse);
    expect(await _planReceipts(db), 1);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('preview metadata that omits constraints cannot bypass unavailable ids',
      () async {
    final db = _freshDb();
    final recipe = _recipe('blocked');
    await _seedRecipe(db, recipe);
    final seeded =
        _planMetadata(label: 'meal', unavailableFoodIds: ['custom:blocked']);
    await _seedPlan(db, meals: const [], extra: seeded);
    final service = _service(db);

    // A preview that only round-trips the schedule omits `constraints`; the
    // persisted hard availability declaration still applies at commit.
    final outcome = await _outcome(service.save(
      requestId: 'preview',
      expectedPlanRevision: 1,
      meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
      metadata: {'schedule': seeded['schedule']},
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('INGREDIENT_UNAVAILABLE'),
                'violations',
                isTrue));
    final stored = (await service.load())!;
    expect(stored.revision, 1);
    expect(
        (stored.document['constraints']! as Map<String, Object?>)
            ['unavailableFoodIds'],
        ['custom:blocked']);
    expect(await _planReceipts(db), 0);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('unavailable ids are normalized and need a new constraint revision',
      () async {
    final db = _freshDb();
    final allowed = _recipe('allowed');
    final blocked = _recipe('blocked');
    await _seedRecipe(db, allowed);
    await _seedRecipe(db, blocked);
    final allowedMeal = _meal('meal:0', '2026-11-10', allowed, '1');
    final seeded = _planMetadata(
        label: 'meal',
        unavailableFoodIds: ['custom:blocked-b', 'custom:blocked']);
    await _seedPlan(db, meals: const [], extra: seeded);
    final service = _service(db);

    // Reordering the ids is the same reviewed hard constraint.
    final reordered = await service.save(
      requestId: 'reordered',
      expectedPlanRevision: 1,
      meals: [allowedMeal],
      metadata: _planMetadata(
          label: 'meal',
          unavailableFoodIds: ['custom:blocked', 'custom:blocked-b']),
    );
    expect(reordered.revision, 2);
    expect(
        (reordered.document['constraints']! as Map<String, Object?>)
            ['unavailableFoodIds'],
        ['custom:blocked', 'custom:blocked-b']);

    // The declaration still blocks its ingredient at commit.
    final blockedOutcome = await _outcome(service.save(
      requestId: 'blocked',
      expectedPlanRevision: 2,
      meals: [_meal('meal:0', '2026-11-10', blocked, '1')],
      metadata: _planMetadata(
          label: 'meal',
          unavailableFoodIds: ['custom:blocked', 'custom:blocked-b']),
    ));
    expect(
        blockedOutcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('INGREDIENT_UNAVAILABLE'),
                'violations',
                isTrue));
    expect((await service.load())!.revision, 2);

    // Dropping the declaration implicitly or explicitly clears a hard
    // constraint and therefore needs a newer constraint revision.
    final implicitClear = await _outcome(service.save(
      requestId: 'implicit-clear',
      expectedPlanRevision: 2,
      meals: [allowedMeal],
      metadata: _planMetadata(label: 'meal'),
    ));
    expect(
        implicitClear,
        isA<PlanException>().having((error) => error.code, 'code',
            'PLAN_CONSTRAINT_REVISION_REQUIRED'));
    final explicitClear = await _outcome(service.save(
      requestId: 'explicit-clear',
      expectedPlanRevision: 2,
      meals: [allowedMeal],
      metadata: _planMetadata(label: 'meal', unavailableFoodIds: const []),
    ));
    expect(
        explicitClear,
        isA<PlanException>().having((error) => error.code, 'code',
            'PLAN_CONSTRAINT_REVISION_REQUIRED'));
    expect((await service.load())!.revision, 2);

    final cleared = await service.save(
      requestId: 'cleared',
      expectedPlanRevision: 2,
      meals: [allowedMeal],
      metadata: _planMetadata(
          label: 'meal', unavailableFoodIds: const [], revision: 2),
    );
    expect(cleared.revision, 3);
    expect(
        (cleared.document['constraints']! as Map<String, Object?>)
            ['unavailableFoodIds'],
        isEmpty);

    // Missing and empty declarations are the same reviewed state, and the
    // cleared declaration lets the previously unavailable ingredient commit.
    final missing = await service.save(
      requestId: 'missing',
      expectedPlanRevision: 3,
      meals: [_meal('meal:0', '2026-11-10', blocked, '1')],
      metadata: _planMetadata(label: 'meal', revision: 2),
    );
    expect(missing.revision, 4);
    expect(missing.meals.single.recipe.id, 'blocked');
    expect(
        (missing.document['constraints']! as Map<String, Object?>)
            .containsKey('unavailableFoodIds'),
        isFalse);
  });

  test('malformed persisted unavailable ids fail closed without writes',
      () async {
    final malformed = <Object?>[
      'custom:r1',
      null,
      [1],
      [''],
      ['   '],
      ['custom:r1', 'custom:r1'],
      [null],
    ];
    for (var index = 0; index < malformed.length; index++) {
      final db = _freshDb();
      final seeded = _planMetadata(label: 'meal');
      (seeded['constraints']! as Map<String, Object?>)['unavailableFoodIds'] =
          malformed[index];
      await _seedPlan(db, meals: const [], extra: seeded);
      final service = _service(db);
      final outcome = await _outcome(service.save(
        requestId: 'malformed-$index',
        expectedPlanRevision: 1,
        meals: const [],
        metadata: {'schedule': seeded['schedule']},
      ));
      expect(
          outcome,
          isA<PlanException>()
              .having((error) => error.code, 'code', 'PLAN_CONTEXT_INVALID'),
          reason: '$malformed[index]');
      expect((await service.load())!.revision, 1, reason: '$malformed[index]');
      expect(await _planReceipts(db), 0, reason: '$malformed[index]');
      expect(await db.select(db.logEntries).get(), isEmpty,
          reason: '$malformed[index]');
    }
  });

  test('malformed new unavailable ids are rejected before commit', () async {
    final db = _freshDb();
    final recipe = _recipe('allowed');
    await _seedRecipe(db, recipe);
    final metadata = _planMetadata(label: 'meal');
    (metadata['constraints']! as Map<String, Object?>)['unavailableFoodIds'] =
        ['custom:allowed', 'custom:allowed'];
    final outcome = await _outcome(_service(db).save(
      requestId: 'malformed-new',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
      metadata: metadata,
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONTEXT_INVALID'));
    expect(await _service(db).load(), isNull);
    expect(await _planReceipts(db), 0);
  });

  test('an unavailable ingredient rolls back staged reservations', () async {
    final db = _freshDb();
    final allowed = _recipe('allowed');
    final blocked = _recipe('blocked');
    await _seedBatch(db, id: 'b1', recipe: allowed);
    await _seedBatch(db, id: 'b2', recipe: blocked);
    final metadata =
        _planMetadata(label: 'meal', unavailableFoodIds: ['custom:blocked']);
    final service = _service(db);
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('meal:0', '2026-11-10', allowed, '1',
            batchId: 'b1', allocationId: 'plan-1')
      ],
      metadata: metadata,
    );
    expect(first.batchRevisions, {'b1': 2});

    // The replacement releases b1 and stages a b2 reservation before commit
    // validation rejects the unavailable ingredient; both must roll back.
    final rejected = await _outcome(service.save(
      requestId: 'blocked',
      expectedPlanRevision: 1,
      meals: [
        _meal('meal:0', '2026-11-10', blocked, '1',
            batchId: 'b2', allocationId: 'plan-2')
      ],
      metadata: metadata,
    ));
    expect(
        rejected,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('INGREDIENT_UNAVAILABLE'),
                'violations',
                isTrue));
    expect((await service.load())!.revision, 1);
    final b1 = (await LocalWorkspace(db).read('batch', 'b1'))!;
    expect(b1.revision, 2);
    final b1Allocations = _allocations(b1);
    expect(b1Allocations.single['id'], 'plan-1');
    expect(_amountOf(b1Allocations.single), Exact.parse('200'));
    final b2 = (await LocalWorkspace(db).read('batch', 'b2'))!;
    expect(b2.revision, 1);
    expect(_allocations(b2), isEmpty);
    // One plan receipt plus the first save's reservation receipt; the rejected
    // save's release and reservation were rolled back with it.
    expect(await _planReceipts(db), 2);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('unavailable ids do not weaken persisted medical exclusions', () async {
    final db = _freshDb();
    final milk = _recipe('milk', allergens: {'milk'});
    await _seedBatch(db, id: 'b', recipe: milk);
    await LocalWorkspace(db).put(
      requestId: 'seed-safety',
      collection: 'profile',
      id: 'safety',
      expectedRevision: 0,
      data: const SafetyProfile(strictExclusions: {'milk'}).toJson(),
    );
    final outcome = await _outcome(_service(db).save(
      requestId: 'milk',
      expectedPlanRevision: 0,
      meals: [
        _meal('meal:0', '2026-11-10', milk, '1',
            batchId: 'b', allocationId: 'plan-1')
      ],
      metadata: _planMetadata(
          label: 'meal', unavailableFoodIds: ['custom:milk']),
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('EXCLUSION_CONFLICT'),
                'exclusions',
                isTrue)
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('INGREDIENT_UNAVAILABLE'),
                'availability',
                isTrue));
    expect(await _service(db).load(), isNull);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch), isEmpty);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('plan save enforces schedule and hard constraint revisions', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final service = _service(db);
    final meal = _meal('meal:0', '2026-11-10', recipe, '1');
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [meal],
      metadata: _planMetadata(label: 'meal', maximumMinutes: 20),
    );
    expect(first.revision, 1);

    final noBump = await _outcome(service.save(
      requestId: 'no-bump',
      expectedPlanRevision: 1,
      meals: [meal],
      metadata: _planMetadata(label: 'meal', maximumMinutes: 30),
    ));
    expect(
        noBump,
        isA<PlanException>().having((error) => error.code, 'code',
            'PLAN_CONSTRAINT_REVISION_REQUIRED'));
    expect((await service.load())!.revision, 1);

    final bumped = await service.save(
      requestId: 'bumped',
      expectedPlanRevision: 1,
      meals: [meal],
      metadata: _planMetadata(
          label: 'meal', maximumMinutes: 30, revision: 2),
    );
    expect(bumped.revision, 2);

    final tooSlow = await _outcome(service.save(
      requestId: 'too-slow',
      expectedPlanRevision: 2,
      meals: [meal],
      metadata:
          _planMetadata(label: 'meal', maximumMinutes: 5, revision: 3),
    ));
    expect(
        tooSlow,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) =>
                    (error.cause! as List<Object?>).contains('COOKING_TIME'),
                'violations',
                isTrue));
    expect((await service.load())!.revision, 2);

    final slotMismatch = await _outcome(service.save(
      requestId: 'slot-mismatch',
      expectedPlanRevision: 2,
      meals: [meal],
      metadata:
          _planMetadata(label: 'other', maximumMinutes: 30, revision: 3),
    ));
    expect(
        slotMismatch,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) =>
                    (error.cause! as List<Object?>).contains('SLOT_MISMATCH'),
                'violations',
                isTrue));
    expect((await service.load())!.revision, 2);
    expect(await _planReceipts(db), 2);
  });

  test('excluding first, middle or last slots never moves retained meals',
      () async {
    final recipe = _recipe('r1');
    for (final excludedIndex in [0, 1, 2]) {
      final db = _freshDb();
      await _seedRecipe(db, recipe);
      final service = _service(db);
      final meals = [
        for (var index = 0; index < 3; index++)
          _meal('meal:$index', '2026-11-${10 + index}', recipe, '1',
              pinned: index == 1)
      ];
      await service.save(
        requestId: 'save-1',
        expectedPlanRevision: 0,
        meals: meals,
        metadata: _planMetadata(days: 3, label: 'meal'),
      );

      final retained = [
        for (var index = 0; index < 3; index++)
          if (index != excludedIndex) meals[index]
      ];
      final saved = await service.save(
        requestId: 'save-2',
        expectedPlanRevision: 1,
        meals: retained,
        metadata: _planMetadata(
            days: 3,
            label: 'meal',
            revision: 2,
            excludedSlotIds: ['meal:$excludedIndex']),
      );
      expect(saved.revision, 2);
      expect(
          saved.meals.map((meal) => meal.slot.id),
          [
            for (var index = 0; index < 3; index++)
              if (index != excludedIndex) 'meal:$index'
          ]);
      expect(
          saved.meals.map((meal) => meal.slot.date),
          [
            for (var index = 0; index < 3; index++)
              if (index != excludedIndex) '2026-11-${10 + index}'
          ]);
      expect(
          saved.meals.map((meal) => meal.pinned),
          [
            for (var index = 0; index < 3; index++)
              if (index != excludedIndex) index == 1
          ]);

      final loaded = await service.load();
      expect(loaded!.revision, 2);
      expect(loaded.meals.map((meal) => meal.slot.id),
          saved.meals.map((meal) => meal.slot.id));
      expect(loaded.meals.map((meal) => meal.slot.date),
          saved.meals.map((meal) => meal.slot.date));
      final schedule = loaded.document['schedule']! as Map<String, Object?>;
      expect(schedule['excludedSlotIds'], ['meal:$excludedIndex']);
      expect(schedule['days'], 3);
      expect(schedule['startDate'], '2026-11-10');
      expect(await db.select(db.logEntries).get(), isEmpty);
    }
  });

  test('excluding a slot releases only its unconsumed reservation', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b', recipe: recipe, available: '600', finishedWeight: '600');
    final service = _service(db);
    final meals = [
      for (var index = 0; index < 3; index++)
        _meal('meal:$index', '2026-11-${10 + index}', recipe, '1',
            batchId: 'b', allocationId: 'plan-$index')
    ];
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: meals,
      metadata: _planMetadata(days: 3, label: 'meal'),
    );
    expect(first.batchRevisions, {'b': 4});

    final second = await service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        for (var index = 0; index < 3; index++)
          if (index != 1)
            _meal('meal:$index', '2026-11-${10 + index}', recipe, '1',
                batchId: 'b',
                allocationId: 'plan-$index',
                batchRevision: first.meals[index].batchUse!.batchRevision)
      ],
      metadata: _planMetadata(
          days: 3,
          label: 'meal',
          revision: 2,
          excludedSlotIds: ['meal:1']),
    );
    expect(second.revision, 2);
    expect(second.batchRevisions, {'b': 5});
    expect(second.meals.map((meal) => meal.batchUse!.batchRevision), [5, 5]);
    expect(second.meals.map((meal) => meal.batchUse!.allocationId),
        ['plan-0', 'plan-2']);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    final allocations = _allocations(batch);
    expect(allocations.map((allocation) => allocation['id']),
        ['plan-0', 'plan-2']);
    expect(_amountOf(allocations[0]), Exact.parse('200'));
    expect(_amountOf(allocations[1]), Exact.parse('200'));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('excluding a consumed slot never releases consumed stock', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        allocations: [
          _alloc('plan-0', '200', 'planned'),
          _alloc('plan-1', '200', 'consumed'),
          _alloc('plan-2', '200', 'planned'),
        ]);
    await _seedPlan(db, meals: [
      for (var index = 0; index < 3; index++)
        _meal('meal:$index', '2026-11-${10 + index}', recipe, '1',
            batchId: 'b', allocationId: 'plan-$index')
    ], extra: _planMetadata(days: 3, label: 'meal'));
    final saved = await _service(db).save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: [
        _meal('meal:0', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-0'),
        _meal('meal:2', '2026-11-12', recipe, '1',
            batchId: 'b', allocationId: 'plan-2'),
      ],
      metadata: _planMetadata(
          days: 3,
          label: 'meal',
          revision: 2,
          excludedSlotIds: ['meal:1']),
    );
    expect(saved.revision, 2);
    expect(saved.batchRevisions, {'b': 1});
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    final allocations = _allocations(batch);
    expect(allocations.map((allocation) => allocation['id']),
        ['plan-0', 'plan-1', 'plan-2']);
    expect(
        allocations
            .where((allocation) => allocation['status'] == 'consumed')
            .single['id'],
        'plan-1');
    final receiptIds = (await db.select(db.appliedCommands).get())
        .map((row) => row.requestId);
    expect(
        receiptIds.any((id) => id.startsWith('batch-release:plan-release:')),
        isFalse);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('a meal on an excluded slot is rejected without writes', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final service = _service(db);
    await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        for (var index = 0; index < 2; index++)
          _meal('meal:$index', '2026-11-${10 + index}', recipe, '1')
      ],
      metadata: _planMetadata(days: 2, label: 'meal'),
    );
    final outcome = await _outcome(service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        _meal('meal:0', '2026-11-10', recipe, '1'),
        _meal('meal:1', '2026-11-11', recipe, '1'),
      ],
      metadata: _planMetadata(
          days: 2,
          label: 'meal',
          revision: 2,
          excludedSlotIds: ['meal:1']),
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) =>
                    (error.cause! as List<Object?>).contains('SLOT_MISMATCH'),
                'violations',
                isTrue));
    expect((await service.load())!.revision, 1);
    expect(await _planReceipts(db), 1);
  });

  test('invalid excluded slot ids fail closed and roll back', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final service = _service(db);
    final meals = [
      for (var index = 0; index < 2; index++)
        _meal('meal:$index', '2026-11-${10 + index}', recipe, '1')
    ];
    await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: meals,
      metadata: _planMetadata(days: 2, label: 'meal'),
    );

    Future<void> rejects(Object? excluded, String requestId) async {
      final metadata = _planMetadata(days: 2, label: 'meal', revision: 2);
      (metadata['schedule']! as Map<String, Object?>)['excludedSlotIds'] =
          excluded;
      await expectLater(
          service.save(
              requestId: requestId,
              expectedPlanRevision: 1,
              meals: meals,
              metadata: metadata),
          _planError('PLAN_CONTEXT_INVALID'));
      expect((await service.load())!.revision, 1);
    }

    await rejects(['meal:0', 'meal:0'], 'duplicate');
    await rejects(['meal:2'], 'out-of-range');
    await rejects(['other:0'], 'foreign-label');
    await rejects([1], 'non-string');
    await rejects('meal:0', 'non-list');
    await rejects(null, 'null');
    await rejects([''], 'empty-string');
    expect(await _planReceipts(db), 1);
  });

  test('invalid exclusions roll back a release staged for the removed meal',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b', recipe: recipe, available: '600', finishedWeight: '600');
    final service = _service(db);
    final meals = [
      _meal('meal:0', '2026-11-10', recipe, '1',
          batchId: 'b', allocationId: 'plan-0'),
      _meal('meal:1', '2026-11-11', recipe, '1',
          batchId: 'b', allocationId: 'plan-1'),
    ];
    final first = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: meals,
      metadata: _planMetadata(days: 2, label: 'meal'),
    );
    expect(first.batchRevisions, {'b': 3});

    final rejected = await _outcome(service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [meals.last],
      metadata: _planMetadata(
          days: 2,
          label: 'meal',
          revision: 2,
          excludedSlotIds: ['meal:0', 'meal:0']),
    ));
    expect(
        rejected,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONTEXT_INVALID'));
    expect((await service.load())!.revision, 1);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 3);
    expect(_allocations(batch).map((allocation) => allocation['id']),
        ['plan-0', 'plan-1']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('legacy plans load unchanged and exclusions need a new revision',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    final schedule = <String, Object?>{
      'startDate': '2026-11-10',
      'days': 2,
      'label': 'meal',
      'portions': [Exact.one.toJson()],
    };
    await _seedPlan(db, meals: [
      _meal('meal:0', '2026-11-10', recipe, '1'),
      _meal('meal:1', '2026-11-11', recipe, '1'),
    ], extra: {
      'schedule': schedule,
      'constraints': <String, Object?>{
        'maximumMinutes': null,
        'maximumRepeats': null,
        'energyMinimum': null,
        'energyMaximum': null,
      },
      'constraintRevision': 1,
      'acceptedRelaxations': <Object?>[],
    });
    final service = _service(db);
    final loaded = await service.load();
    expect(
        (loaded!.document['schedule']! as Map<String, Object?>)
            .containsKey('excludedSlotIds'),
        isFalse);

    // Rewriting the legacy schedule unchanged keeps revision 1: absent
    // exclusions and an explicit empty list are the same reviewed schedule.
    final unchanged = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: loaded.meals,
      metadata: {'schedule': schedule},
    );
    expect(unchanged.revision, 2);
    expect(
        (unchanged.document['schedule']! as Map<String, Object?>)
            .containsKey('excludedSlotIds'),
        isFalse);

    final explicitEmpty = await service.save(
      requestId: 'save-2',
      expectedPlanRevision: 2,
      meals: loaded.meals,
      metadata: {
        'schedule': {...schedule, 'excludedSlotIds': <String>[]},
      },
    );
    expect(explicitEmpty.revision, 3);

    Future<Object?> attempt(String requestId, int expectedRevision,
            Map<String, Object?> metadata, List<PlannedMeal> meals) =>
        _outcome(service.save(
            requestId: requestId,
            expectedPlanRevision: expectedRevision,
            meals: meals,
            metadata: metadata));

    final noBump = await attempt('save-3', 3, {
      'schedule': {
        ...schedule,
        'excludedSlotIds': <String>['meal:0'],
      },
    }, [loaded.meals.last]);
    expect(
        noBump,
        isA<PlanException>().having(
            (error) => error.code, 'code', 'PLAN_CONSTRAINT_REVISION_REQUIRED'));
    expect((await service.load())!.revision, 3);

    final excluded = await service.save(
      requestId: 'save-4',
      expectedPlanRevision: 3,
      meals: [loaded.meals.last],
      metadata: {
        'schedule': {
          ...schedule,
          'excludedSlotIds': <String>['meal:0'],
        },
        'constraintRevision': 2,
      },
    );
    expect(excluded.revision, 4);

    // Replacing the excluded schedule without naming the reviewed exclusions
    // is not an explicit reset, even with a newer revision.
    final implicitReset = await attempt('save-5', 4, {
      'schedule': schedule,
      'constraintRevision': 3,
    }, [loaded.meals.last]);
    expect(
        implicitReset,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONTEXT_INVALID'));
    expect((await service.load())!.revision, 4);

    final reset = await service.save(
      requestId: 'save-6',
      expectedPlanRevision: 4,
      meals: loaded.meals,
      metadata: {
        'schedule': {...schedule, 'excludedSlotIds': <String>[]},
        'constraintRevision': 3,
      },
    );
    expect(reset.revision, 5);
  });

  test('an empty effective schedule is valid only when every slot is excluded',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final service = _service(db);
    final meals = [
      for (var index = 0; index < 2; index++)
        _meal('meal:$index', '2026-11-${10 + index}', recipe, '1')
    ];
    await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: meals,
      metadata: _planMetadata(days: 2, label: 'meal'),
    );

    final rejected = await _outcome(service.save(
      requestId: 'empty-without-exclusions',
      expectedPlanRevision: 1,
      meals: const [],
      metadata: _planMetadata(days: 2, label: 'meal', revision: 2),
    ));
    expect(
        rejected,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('UNRESOLVED_SLOTS'),
                'violations',
                isTrue));
    expect((await service.load())!.revision, 1);

    final empty = await service.save(
      requestId: 'empty-with-exclusions',
      expectedPlanRevision: 1,
      meals: const [],
      metadata: _planMetadata(
          days: 2,
          label: 'meal',
          revision: 2,
          excludedSlotIds: ['meal:0', 'meal:1']),
    );
    expect(empty.revision, 2);
    expect(empty.meals, isEmpty);
    final loaded = await service.load();
    expect(loaded!.meals, isEmpty);
    final schedule = loaded.document['schedule']! as Map<String, Object?>;
    expect(schedule['excludedSlotIds'], ['meal:0', 'meal:1']);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('plan schedule helper exposes effective slots without renumbering', () {
    final schedule = PlanSchedule.fromMetadata(<String, Object?>{
      'startDate': '2026-11-10',
      'days': 3,
      'label': 'dinner',
      'excludedSlotIds': ['dinner:2', 'dinner:0'],
    })!;
    expect(schedule.generatedSlotIds,
        ['dinner:0', 'dinner:1', 'dinner:2']);
    expect(schedule.slots.map((slot) => slot.id), ['dinner:1']);
    expect(schedule.slots.single.date, '2026-11-11');
    expect(schedule.excludedSlotIds, ['dinner:2', 'dinner:0']);
    expect(schedule.hasRetainedSlots, isTrue);
    expect(
        PlanSchedule.fromMetadata(<String, Object?>{
          'startDate': '2026-11-10',
          'days': 1,
          'label': 'dinner',
          'excludedSlotIds': ['dinner:0'],
        })!
            .hasRetainedSlots,
        isFalse);
  });

  test('plan save fails closed on stale or missing recipe revisions',
      () async {
    final db = _freshDb();
    final version1 = _recipe('r1');
    final version2 = _recipe('r1', revision: 2);
    await _seedRecipe(db, version1);
    await _seedRecipe(db, version2);
    final service = _service(db);
    final stale = await _outcome(service.save(
      requestId: 'stale-recipe',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', version1, '1')],
      metadata: _planMetadata(label: 'meal'),
    ));
    expect(
        stale,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('RECIPE_REVISION_MISMATCH'),
                'violations',
                isTrue));
    expect(await service.load(), isNull);

    final missing = await _outcome(service.save(
      requestId: 'missing-recipe',
      expectedPlanRevision: 0,
      meals: [
        _meal('meal:0', '2026-11-10', _recipe('r-missing'), '1')
      ],
      metadata: _planMetadata(label: 'meal'),
    ));
    expect(
        missing,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('RECIPE_REVISION_MISMATCH'),
                'violations',
                isTrue));
    expect(await service.load(), isNull);

    final current = await service.save(
      requestId: 'current-recipe',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', version2, '1')],
      metadata: _planMetadata(label: 'meal'),
    );
    expect(current.revision, 1);
  });

  test('plan save fails closed when a binding range lacks nutrient data',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final outcome = await _outcome(_service(db).save(
      requestId: 'range',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
      metadata: _planMetadata(
        label: 'meal',
        energyMinimum: Exact.parse('100'),
        energyMaximum: Exact.parse('500'),
      ),
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONSTRAINT_CONFLICT')
            .having(
                (error) => (error.cause! as List<Object?>)
                    .contains('INSUFFICIENT_NUTRIENT_DATA'),
                'violations',
                isTrue));
    expect(await _service(db).load(), isNull);
  });

  test('a schedule edit cannot silently retain an invalid exclusion', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(db, recipe);
    final service = _service(db);
    await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        for (var index = 0; index < 3; index++)
          _meal('meal:$index', '2026-11-${10 + index}', recipe, '1')
      ],
      metadata: _planMetadata(days: 3, label: 'meal'),
    );
    final excluded = await service.save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        _meal('meal:0', '2026-11-10', recipe, '1'),
        _meal('meal:1', '2026-11-11', recipe, '1'),
      ],
      metadata: _planMetadata(
          days: 3, label: 'meal', revision: 2, excludedSlotIds: ['meal:2']),
    );
    expect(excluded.revision, 2);

    final shrunk = await _outcome(service.save(
      requestId: 'save-3',
      expectedPlanRevision: 2,
      meals: [
        _meal('meal:0', '2026-11-10', recipe, '1'),
        _meal('meal:1', '2026-11-11', recipe, '1'),
      ],
      metadata: _planMetadata(
          days: 2, label: 'meal', revision: 3, excludedSlotIds: ['meal:2']),
    ));
    expect(
        shrunk,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'PLAN_CONTEXT_INVALID'));
    expect((await service.load())!.revision, 2);
  });

  test('backup restore preserves reservations and plan retry receipts',
      () async {
    final source = _freshDb();
    final restored = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(source, id: 'b', recipe: recipe);
    final original = await _service(source).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(original.revision, 1);
    final archive = await ArchiveService(source).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);

    final restoredPlan = await _service(restored).load();
    expect(restoredPlan!.revision, 1);
    expect(restoredPlan.meals.single.batchUse!.allocationId, 'plan-1');
    expect(restoredPlan.meals.single.batchUse!.batchRevision, 2);

    final replay = await _service(restored).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-1')
      ],
    );
    expect(replay.revision, 1);
    expect((await LocalWorkspace(restored).read('batch', 'b'))!.revision, 2);
    expect(
        _allocations((await LocalWorkspace(restored).read('batch', 'b'))!),
        hasLength(1));

    final cleared = await _service(restored)
        .save(requestId: 'save-2', expectedPlanRevision: 1, meals: const []);
    expect(cleared.revision, 2);
    expect((await LocalWorkspace(restored).read('batch', 'b'))!.revision, 3);
    expect(_allocations((await LocalWorkspace(restored).read('batch', 'b'))!),
        isEmpty);
    expect(await restored.select(restored.logEntries).get(), isEmpty);
  });

  test('restore and identical retry preserve excluded schedule slots',
      () async {
    final source = _freshDb();
    final restored = _freshDb();
    final recipe = _recipe('r1');
    await _seedRecipe(source, recipe);
    final metadata =
        _planMetadata(days: 2, label: 'meal', excludedSlotIds: ['meal:0']);
    final original = await _service(source).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [_meal('meal:1', '2026-11-11', recipe, '1')],
      metadata: metadata,
    );
    expect(original.revision, 1);
    final archive = await ArchiveService(source).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);

    final restoredPlan = await _service(restored).load();
    expect(restoredPlan!.revision, 1);
    expect(restoredPlan.meals.single.slot.id, 'meal:1');
    final schedule =
        restoredPlan.document['schedule']! as Map<String, Object?>;
    expect(schedule['excludedSlotIds'], ['meal:0']);

    final replay = await _service(restored).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [_meal('meal:1', '2026-11-11', recipe, '1')],
      metadata: metadata,
    );
    expect(replay.revision, 1);
    expect(replay.document['schedule'], metadata['schedule']);

    // The retry receipt covers the reviewed exclusions: reusing the request id
    // with a different exclusion list is not an identical retry.
    final reused = await _outcome(_service(restored).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [_meal('meal:1', '2026-11-11', recipe, '1')],
      metadata:
          _planMetadata(days: 2, label: 'meal', excludedSlotIds: ['meal:1']),
    ));
    expect(
        reused,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'REQUEST_ID_REUSED'));

    final reset = await _service(restored).save(
      requestId: 'save-2',
      expectedPlanRevision: 1,
      meals: [
        _meal('meal:0', '2026-11-10', recipe, '1'),
        _meal('meal:1', '2026-11-11', recipe, '1'),
      ],
      metadata: _planMetadata(
          days: 2, label: 'meal', revision: 2, excludedSlotIds: []),
    );
    expect(reset.revision, 2);
  });

  test('simultaneous plan saves reserve stock exactly once', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db, id: 'b', recipe: recipe);
    final service = _service(db);
    final first = _outcome(service.save(
      requestId: 'save-a',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-a')
      ],
    ));
    final second = _outcome(service.save(
      requestId: 'save-b',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-b')
      ],
    ));
    final outcomes = await Future.wait([first, second]);
    expect(outcomes.whereType<PlanSaveResult>(), hasLength(1));
    final failures = outcomes.whereType<PlanException>().toList();
    expect(failures, hasLength(1));
    expect(
        const ['STALE_PLAN', 'STALE_BATCH', 'BATCH_OVERALLOCATED'],
        contains(failures.single.code));
    final plan = await service.load();
    expect(plan!.revision, 1);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 2);
    final allocations = _allocations(batch);
    expect(allocations, hasLength(1));
    expect(_amountOf(allocations.single), Exact.parse('400'));
    expect(await db.select(db.logEntries).get(), isEmpty);
    expect(await _planReceipts(db), 2);
  });

  test('serving batches reserve exact recipe portions without guessing grams',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving');
    final service = _service(db);
    final saved = await service.save(
      requestId: 'save-s',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(saved.revision, 1);
    expect(saved.batchRevisions, {'b': 2});
    expect(saved.meals.single.batchUse!.allocationId, 'plan-s');
    expect(saved.meals.single.batchUse!.batchRevision, 2);

    final doc = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(doc.revision, 2);
    expect(doc.data['unit'], 'serving');
    final allocation = _allocations(doc).single;
    expect(allocation['id'], 'plan-s');
    expect(allocation['status'], 'planned');
    // Two planned recipe portions are two servings, never a gram guess.
    expect(_amountOf(allocation), Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), isEmpty);

    final plan = (await service.load())!;
    expect(plan.meals.single.batchUse!.allocationId, 'plan-s');
    expect(plan.meals.single.portions, Exact.parse('2'));

    // Reloading and saving the same allocation counts the stock once.
    final again = await service.save(
        requestId: 'save-s-2', expectedPlanRevision: 1, meals: plan.meals);
    expect(again.batchRevisions, {'b': 2});
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 2);
    expect(_allocations((await LocalWorkspace(db).read('batch', 'b'))!),
        hasLength(1));
    expect(_amountOf(_allocations(
            (await LocalWorkspace(db).read('batch', 'b'))!)
        .single),
        Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), isEmpty);

    // Serving stock is finite: the batch cannot hold more than it provides.
    final over = await _outcome(service.save(
      requestId: 'save-over',
      expectedPlanRevision: 2,
      meals: [
        ...plan.meals,
        _meal('d2', '2026-11-11', recipe, '3',
            batchId: 'b', allocationId: 'plan-over', batchRevision: 2),
      ],
    ));
    expect(
        over,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'BATCH_OVERALLOCATED'));
    expect((await service.load())!.revision, 2);
    final after = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(after.revision, 2);
    expect(_allocations(after), hasLength(1));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('serving batches without a measured yield reserve exact portions',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    // Serving stock is counted in portions, so no gram yield is required.
    await _seedRawBatch(db,
        id: 'b',
        recipe: recipe,
        available: '2',
        finishedWeight: null,
        unit: 'serving');
    final saved = await _service(db).save(
      requestId: 'save-yield',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(saved.revision, 1);
    expect(saved.batchRevisions, {'b': 2});
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 2);
    expect(batch.data['finishedWeightG'], isNull);
    expect(_amountOf(_allocations(batch).single), Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('identical serving retries replay and conflicting reuse is rejected',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving');
    final service = _service(db);
    final first = await service.save(
      requestId: 'retry-s',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(first.revision, 1);

    final retried = await service.save(
      requestId: 'retry-s',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(retried.revision, 1);
    expect(retried.batchRevisions, {'b': 2});
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 2);
    expect(_allocations((await LocalWorkspace(db).read('batch', 'b'))!),
        hasLength(1));
    expect(_amountOf(_allocations(
            (await LocalWorkspace(db).read('batch', 'b'))!)
        .single),
        Exact.parse('2'));

    await expectLater(
        service.save(
            requestId: 'retry-s', expectedPlanRevision: 1, meals: const []),
        _planError('REQUEST_ID_REUSED'));
    await expectLater(
        service.save(
          requestId: 'retry-s',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-s')
          ],
        ),
        _planError('REQUEST_ID_REUSED'));
    expect((await service.load())!.revision, 1);

    // Resizing a kept serving allocation is not silently converted; the old
    // reservation must be released and re-reserved explicitly.
    final resized = await _outcome(service.save(
      requestId: 'resize-s',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '1',
            batchId: 'b', allocationId: 'plan-s')
      ],
    ));
    expect(
        resized,
        isA<PlanException>().having(
            (error) => error.code, 'code', 'PLAN_BATCH_ALLOCATION_MISMATCH'));
    expect((await service.load())!.revision, 1);
    expect((await LocalWorkspace(db).read('batch', 'b'))!.revision, 2);
    expect(_amountOf(_allocations(
            (await LocalWorkspace(db).read('batch', 'b'))!)
        .single),
        Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('simultaneous serving plan saves reserve stock exactly once', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '3',
        finishedWeight: '600',
        unit: 'serving');
    final service = _service(db);
    final outcomes = await Future.wait([
      _outcome(service.save(
        requestId: 'save-a',
        expectedPlanRevision: 0,
        meals: [
          _meal('d1', '2026-11-10', recipe, '2',
              batchId: 'b', allocationId: 'plan-a')
        ],
      )),
      _outcome(service.save(
        requestId: 'save-b',
        expectedPlanRevision: 0,
        meals: [
          _meal('d1', '2026-11-10', recipe, '2',
              batchId: 'b', allocationId: 'plan-b')
        ],
      )),
    ]);
    expect(outcomes.whereType<PlanSaveResult>(), hasLength(1));
    final failures = outcomes.whereType<PlanException>().toList();
    expect(failures, hasLength(1));
    expect(
        const ['STALE_PLAN', 'STALE_BATCH', 'BATCH_OVERALLOCATED'],
        contains(failures.single.code));
    final plan = await service.load();
    expect(plan!.revision, 1);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 2);
    final allocations = _allocations(batch);
    expect(allocations, hasLength(1));
    expect(_amountOf(allocations.single), Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), isEmpty);
    expect(await _planReceipts(db), 2);
  });

  test('a failed serving reservation rolls back earlier reservations and the plan',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b1',
        recipe: recipe,
        available: '3',
        finishedWeight: '600',
        unit: 'serving');
    await _seedBatch(db,
        id: 'b2',
        recipe: recipe,
        available: '1',
        finishedWeight: '600',
        unit: 'serving');
    final outcome = await _outcome(_service(db).save(
      requestId: 'rollback-s',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b1', allocationId: 'plan-1'),
        _meal('d2', '2026-11-11', recipe, '2',
            batchId: 'b2', allocationId: 'plan-2'),
      ],
    ));
    expect(
        outcome,
        isA<PlanException>()
            .having((error) => error.code, 'code', 'BATCH_OVERALLOCATED'));
    expect(await _service(db).load(), isNull);
    for (final id in ['b1', 'b2']) {
      final batch = (await LocalWorkspace(db).read('batch', id))!;
      expect(batch.revision, 1);
      expect(_allocations(batch), isEmpty);
    }
    expect(await _planReceipts(db), 0);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('consumed serving allocations stay accounted exactly once', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving',
        allocations: [
          _alloc('plan-s', '2', 'consumed', intakeRequestId: 'meal-s')
        ]);
    await _seedPlan(db, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-s')
    ]);
    final service = _service(db);
    final kept = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(kept.revision, 2);
    expect(kept.batchRevisions, {'b': 1});
    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch).single['status'], 'consumed');
    expect(_amountOf(_allocations(batch).single), Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), isEmpty);

    // Dropping the consumed use never releases eaten stock.
    final dropped = await service.save(
        requestId: 'save-2', expectedPlanRevision: 2, meals: const []);
    expect(dropped.revision, 3);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch).single['status'], 'consumed');
    expect(_amountOf(_allocations(batch).single), Exact.parse('2'));
    final receiptIds =
        (await db.select(db.appliedCommands).get()).map((row) => row.requestId);
    expect(receiptIds.any((id) => id.startsWith('batch-release:plan-release:')),
        isFalse);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('a serving reservation consumed through intake stays accounted once',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving');
    final service = _service(db);
    final saved = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(saved.revision, 1);

    final entry = await BatchService(
            db, const SystemClock(), SequentialIdGenerator())
        .consumeAmount(
            requestId: 'meal-s',
            batchId: 'b',
            expectedRevision: 2,
            amount: Exact.parse('2'),
            unit: FoodUnit.serving,
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'plan-s');
    expect(entry.items, isNotEmpty);
    final source = entry.items.single.sourceSnapshot!;
    expect(source['consumedBatchUnit'], 'serving');
    expect(
        Exact.fromJson(
            Map<String, Object?>.from(source['consumedBatchServings']! as Map)),
        Exact.parse('2'));
    expect(source.containsKey('consumedBatchGrams'), isFalse);
    expect(source['reservedAllocationId'], 'plan-s');

    var batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 3);
    expect(_allocations(batch).single['status'], 'consumed');
    expect(_allocations(batch).single['intakeRequestId'], 'meal-s');

    // The plan keeps the eaten allocation exactly once; no second reservation
    // and no release of consumed stock.
    final kept = await service.save(
        requestId: 'save-2',
        expectedPlanRevision: 1,
        meals: saved.meals);
    expect(kept.revision, 2);
    expect(kept.batchRevisions, {'b': 3});
    expect(kept.meals.single.batchUse!.allocationId, 'plan-s');
    expect(kept.meals.single.batchUse!.batchRevision, 3);
    batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 3);
    expect(_allocations(batch), hasLength(1));
    expect(_allocations(batch).single['status'], 'consumed');
    expect(_amountOf(_allocations(batch).single), Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });

  test('a new plan use cannot claim a consumed serving allocation', () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving',
        allocations: [
          _alloc('plan-s', '2', 'consumed', intakeRequestId: 'meal-s')
        ]);
    await expectLater(
        _service(db).save(
          requestId: 'save-1',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-s')
          ],
        ),
        _planError('PLAN_BATCH_USE_CONSUMED'));
    expect(await _service(db).load(), isNull);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch).single['status'], 'consumed');
    expect(await _planReceipts(db), 0);
    expect(await db.select(db.logEntries).get(), isEmpty);
  });

  test('legacy re-keyed serving consumption reconciles from a frozen snapshot',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r1');
    await _seedBatch(db,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving',
        allocations: [_alloc('meal-legacy', '2', 'consumed')]);
    await _seedIntake(db,
        entryId: 'entry-s',
        requestId: 'meal-legacy',
        batchId: 'b',
        reservedAllocationId: 'plan-s',
        servings: '2',
        unit: 'serving');
    await _seedPlan(db, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-s')
    ]);
    final service = _service(db);
    final reconciled = await service.save(
      requestId: 'save-1',
      expectedPlanRevision: 1,
      meals: [
        _meal('d1', '2026-11-10', recipe, '2',
            batchId: 'b', allocationId: 'plan-s')
      ],
    );
    expect(reconciled.revision, 2);
    expect(reconciled.meals.single.batchUse!.allocationId, 'meal-legacy');
    expect(reconciled.meals.single.batchUse!.batchRevision, 1);
    final batch = (await LocalWorkspace(db).read('batch', 'b'))!;
    expect(batch.revision, 1);
    expect(_allocations(batch), hasLength(1));
    expect(_allocations(batch).single['id'], 'meal-legacy');
    expect(_amountOf(_allocations(batch).single), Exact.parse('2'));
    expect(await db.select(db.logEntries).get(), hasLength(1));
    expect((await service.load())!.meals.single.batchUse!.allocationId,
        'meal-legacy');
  });

  test('serving legacy reconciliation rejects gram or unstated units',
      () async {
    final recipe = _recipe('r1');
    final gramSnapshot = _freshDb();
    await _seedBatch(gramSnapshot,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving',
        allocations: [_alloc('meal-legacy', '2', 'consumed')]);
    // A legacy gram snapshot has no explicit unit and cannot prove servings.
    await _seedIntake(gramSnapshot,
        entryId: 'entry-g',
        requestId: 'meal-legacy',
        batchId: 'b',
        reservedAllocationId: 'plan-s',
        grams: '400');
    await _seedPlan(gramSnapshot, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-s')
    ]);
    await expectLater(
        _service(gramSnapshot).save(
          requestId: 'save-g',
          expectedPlanRevision: 1,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-s')
          ],
        ),
        _planError('PLAN_BATCH_ALLOCATION_MISSING'));
    expect((await _service(gramSnapshot).load())!.revision, 1);
    expect((await LocalWorkspace(gramSnapshot).read('batch', 'b'))!.revision,
        1);

    final wrongUnit = _freshDb();
    await _seedBatch(wrongUnit,
        id: 'b',
        recipe: recipe,
        available: '4',
        finishedWeight: '600',
        unit: 'serving',
        allocations: [_alloc('meal-legacy', '2', 'consumed')]);
    await _seedIntake(wrongUnit,
        entryId: 'entry-u',
        requestId: 'meal-legacy',
        batchId: 'b',
        reservedAllocationId: 'plan-s',
        servings: '2',
        unit: 'g');
    await _seedPlan(wrongUnit, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-s')
    ]);
    await expectLater(
        _service(wrongUnit).save(
          requestId: 'save-u',
          expectedPlanRevision: 1,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-s')
          ],
        ),
        _planError('PLAN_BATCH_ALLOCATION_MISSING'));
    expect((await _service(wrongUnit).load())!.revision, 1);
    expect((await LocalWorkspace(wrongUnit).read('batch', 'b'))!.revision, 1);
  });

  test('missing, mismatched and unsupported reservations fail closed', () async {
    final recipe = _recipe('r1');
    final unsupportedDb = _freshDb();
    await _seedRawBatch(unsupportedDb,
        id: 'b', recipe: recipe, unit: 'ml', available: '3');
    await expectLater(
        _service(unsupportedDb).save(
          requestId: 'unsupported',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-s')
          ],
        ),
        _planError('BATCH_UNIT_MISMATCH'));
    expect(await _service(unsupportedDb).load(), isNull);
    expect(
        (await LocalWorkspace(unsupportedDb).read('batch', 'b'))!.revision, 1);
    expect(_allocations((await LocalWorkspace(unsupportedDb).read('batch', 'b'))!),
        isEmpty);
    expect(await _planReceipts(unsupportedDb), 0);

    final itemDb = _freshDb();
    await _seedRawBatch(itemDb,
        id: 'b', recipe: recipe, unit: 'item', available: '3');
    await expectLater(
        _service(itemDb).save(
          requestId: 'item',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '1',
                batchId: 'b', allocationId: 'plan-i')
          ],
        ),
        _planError('BATCH_UNIT_MISMATCH'));
    expect(await _service(itemDb).load(), isNull);
    expect((await LocalWorkspace(itemDb).read('batch', 'b'))!.revision, 1);

    final mismatchDb = _freshDb();
    await _seedBatch(mismatchDb, id: 'b', recipe: _recipe('r1'));
    await expectLater(
        _service(mismatchDb).save(
          requestId: 'recipe',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', _recipe('r2'), '1',
                batchId: 'b', allocationId: 'plan-x')
          ],
        ),
        _planError('PLAN_BATCH_RECIPE_MISMATCH'));
    expect(await _service(mismatchDb).load(), isNull);

    final amountDb = _freshDb();
    await _seedBatch(amountDb,
        id: 'b', recipe: recipe, allocations: [_alloc('plan-a', '100', 'planned')]);
    await expectLater(
        _service(amountDb).save(
          requestId: 'amount',
          expectedPlanRevision: 0,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-a')
          ],
        ),
        _planError('PLAN_BATCH_ALLOCATION_MISMATCH'));
    expect(await _service(amountDb).load(), isNull);

    final missingDb = _freshDb();
    await _seedBatch(missingDb, id: 'b', recipe: recipe);
    await _seedPlan(missingDb, meals: [
      _meal('d1', '2026-11-10', recipe, '2',
          batchId: 'b', allocationId: 'plan-gone')
    ]);
    await expectLater(
        _service(missingDb).save(
          requestId: 'missing',
          expectedPlanRevision: 1,
          meals: [
            _meal('d1', '2026-11-10', recipe, '2',
                batchId: 'b', allocationId: 'plan-gone')
          ],
        ),
        _planError('PLAN_BATCH_ALLOCATION_MISSING'));
    expect((await _service(missingDb).load())!.revision, 1);
    expect((await LocalWorkspace(missingDb).read('batch', 'b'))!.revision, 1);
  });

  test('catalogue ingredient revision or removal fails closed at save',
      () async {
    final db = _freshDb();
    final recipe = _recipe('food-1', catalogue: true);
    final food = recipe.ingredients.single.food;
    await _seedCatalogueFood(db, food);
    await _seedRecipe(db, recipe);
    final first = await _service(db).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
      metadata: _planMetadata(label: 'meal'),
    );
    expect(first.revision, 1);

    await _seedCatalogueFood(db, _foodWithAllergens(food, const {'milk'}));
    await expectLater(
      _service(db).save(
        requestId: 'save-2',
        expectedPlanRevision: 1,
        meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
        metadata: _planMetadata(label: 'meal'),
      ),
      _planError('PLAN_CONSTRAINT_CONFLICT'),
    );
    expect((await _service(db).load())!.revision, 1);

    await (db.delete(db.catalogFoods)
          ..where((t) => t.id.equals(food.id)))
        .go();
    await expectLater(
      _service(db).save(
        requestId: 'save-3',
        expectedPlanRevision: 1,
        meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
        metadata: _planMetadata(label: 'meal'),
      ),
      _planError('PLAN_CONSTRAINT_CONFLICT'),
    );
    expect((await _service(db).load())!.revision, 1);
  });

  test(
      'active custom record changes and deletion fail closed at save',
      () async {
    final db = _freshDb();
    final recipe = _recipe('local-1');
    final food = recipe.ingredients.single.food;
    await _seedCatalogueFood(db, food);
    await _seedRecipe(db, recipe);
    final first = await _service(db).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
      metadata: _planMetadata(label: 'meal'),
    );
    expect(first.revision, 1);

    // A present record is current for every provenance, including a custom
    // user-authored row: changing its allergens must not be masked by the old
    // recipe snapshot.
    await _seedCatalogueFood(db, _foodWithAllergens(food, const {'milk'}));
    await expectLater(
      _service(db).save(
        requestId: 'save-2',
        expectedPlanRevision: 1,
        meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
        metadata: _planMetadata(label: 'meal'),
      ),
      _planError('PLAN_CONSTRAINT_CONFLICT'),
    );
    expect((await _service(db).load())!.revision, 1);

    // Deleting the only active row leaves no non-spoofable ownership record.
    // The recipe's provenance strings are not accepted as proof, so the save
    // must fail closed instead of trusting the old snapshot.
    await (db.delete(db.catalogFoods)
          ..where((t) => t.id.equals(food.id)))
        .go();
    await expectLater(
      _service(db).save(
        requestId: 'save-3',
        expectedPlanRevision: 1,
        meals: [_meal('meal:0', '2026-11-10', recipe, '1')],
        metadata: _planMetadata(label: 'meal'),
      ),
      _planError('PLAN_CONSTRAINT_CONFLICT'),
    );
    expect((await _service(db).load())!.revision, 1);
  });

  test('declared conditions require and persist matching plan inputs',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r-conditions');
    await _seedRecipe(db, recipe);
    await _writeDeclaration(db, {'diabetes': true},
        requestId: 'declaration-1');
    final metadata = _planMetadata(label: 'Dinner');
    final meals = [
      _meal('Dinner:0', '2026-11-10', recipe, '1'),
    ];

    // A plan must not silently omit a declared condition.
    await expectLater(
      _service(db).save(
          requestId: 'save-1',
          expectedPlanRevision: 0,
          meals: meals,
          metadata: metadata),
      _planError('PLAN_CONDITION_INPUT_REQUIRED'),
    );
    expect(await _service(db).load(), isNull);

    final input = await _service(db).readConditionGuidanceInput();
    expect(input.declared, {PlanningCondition.diabetes});
    expect(input.absent, isEmpty);
    final saved = await _service(db).save(
      requestId: 'save-2',
      expectedPlanRevision: 0,
      meals: meals,
      metadata: {...metadata, 'conditionGuidance': input.toJson()},
    );
    expect(saved.conditionGuidance!.declared,
        {PlanningCondition.diabetes});
    expect(saved.conditionGuidance!.fingerprint, input.fingerprint);

    final loaded = await _service(db).load();
    expect(loaded!.conditionGuidance!.fingerprint, input.fingerprint);
    expect(loaded.conditionGuidance!.policyVersion,
        ConditionGuidancePolicy.version);
  });

  test('condition edits make an old plan input stale and require a repair',
      () async {
    final db = _freshDb();
    final recipe = _recipe('r-stale-conditions');
    await _seedRecipe(db, recipe);
    await _writeDeclaration(db, {'diabetes': true},
        requestId: 'declaration-1');
    final metadata = _planMetadata(label: 'Dinner');
    final meals = [
      _meal('Dinner:0', '2026-11-10', recipe, '1'),
    ];
    final before = await _service(db).readConditionGuidanceInput();
    await _service(db).save(
      requestId: 'save-1',
      expectedPlanRevision: 0,
      meals: meals,
      metadata: {...metadata, 'conditionGuidance': before.toJson()},
    );

    await _writeDeclaration(db, {'highCholesterol': true},
        requestId: 'declaration-2');
    final after = await _service(db).readConditionGuidanceInput();
    expect(after.declared, {PlanningCondition.highCholesterol});
    expect(after.sameDeclaration(before), isFalse);

    await expectLater(
      _service(db).save(
        requestId: 'save-2',
        expectedPlanRevision: 1,
        meals: meals,
        metadata: {...metadata, 'conditionGuidance': before.toJson()},
      ),
      _planError('PLAN_CONDITION_INPUT_STALE'),
    );
    expect((await _service(db).load())!.revision, 1);

    final repaired = await _service(db).save(
      requestId: 'save-3',
      expectedPlanRevision: 1,
      meals: meals,
      metadata: {...metadata, 'conditionGuidance': after.toJson()},
    );
    expect(repaired.revision, 2);
    expect(repaired.conditionGuidance!.declared,
        {PlanningCondition.highCholesterol});
  });

  test('an old condition guidance policy version is rejected', () async {
    final db = _freshDb();
    final recipe = _recipe('r-policy');
    await _seedRecipe(db, recipe);
    await _writeDeclaration(db, {'diabetes': true},
        requestId: 'declaration-1');
    final input = await _service(db).readConditionGuidanceInput();
    final metadata = _planMetadata(label: 'Dinner');
    await expectLater(
      _service(db).save(
        requestId: 'save-1',
        expectedPlanRevision: 0,
        meals: [_meal('Dinner:0', '2026-11-10', recipe, '1')],
        metadata: {
          ...metadata,
          'conditionGuidance': {
            ...input.toJson(),
            'policyVersion': 'condition-guidance-substituted-v0',
          },
        },
      ),
      _planError('PLAN_CONDITION_POLICY_MISMATCH'),
    );
    expect(await _service(db).load(), isNull);
  });

  test('malformed declaration documents fail closed before planning',
      () async {
    final db = _freshDb();
    await db.into(db.userDocuments).insertOnConflictUpdate(
        UserDocumentsCompanion.insert(
            collection: 'health-declaration',
            id: 'current',
            revision: 1,
            payload: jsonEncode({
              'schemaVersion': 1,
              'conditions': 'not-a-condition-map',
            })));
    await expectLater(_service(db).readConditionGuidanceInput(),
        _planError('PLAN_CONDITION_INVALID'));

    final recipe = _recipe('r-malformed-declaration');
    await _seedRecipe(db, recipe);
    await expectLater(
      _service(db).save(
        requestId: 'save-1',
        expectedPlanRevision: 0,
        meals: [_meal('Dinner:0', '2026-11-10', recipe, '1')],
        metadata: _planMetadata(label: 'Dinner'),
      ),
      _planError('PLAN_CONDITION_INVALID'),
    );
    expect(await _service(db).load(), isNull);
  });
}

Future<void> _writeDeclaration(
    AppDatabase db, Map<String, bool?> conditions,
    {required String requestId}) async {
  final prior = await LocalWorkspace(db).read('health-declaration', 'current');
  await LocalWorkspace(db).put(
    requestId: requestId,
    collection: 'health-declaration',
    id: 'current',
    expectedRevision: prior?.revision ?? 0,
    data: {
      'schemaVersion': 1,
      'goal': 'notDeclared',
      'conditions': <String, Object?>{
        for (final condition in PlanningCondition.values)
          condition.name: conditions[condition.name],
      },
      'guidancePolicy': ConditionGuidancePolicy.version,
    },
  );
}

AppDatabase _freshDb() {
  final db = AppDatabase.memory();
  addTearDown(db.close);
  return db;
}

PlanService _service(AppDatabase db) =>
    PlanService(db, const SystemClock(), SequentialIdGenerator());

RecipeVersion _recipe(String id,
        {int revision = 1,
        int minutes = 10,
        Set<String>? allergens,
        bool catalogue = false}) =>
    RecipeVersion(
      id: id,
      revision: revision,
      name: 'Soup $id',
      servings: Exact.parse('3'),
      minutes: minutes,
      allergens: allergens,
      ingredients: [
        RecipeIngredient(
            Food(
                id: catalogue ? 'usda-fdc:$id' : 'custom:$id',
                name: 'Ingredient $id',
                per100g: NutrientProfile(
                    {NutrientKey.proteinG: NutrientReported(60)}),
                source: FoodSource(
                    dataset: catalogue ? 'usda-fdc' : 'custom-user-entry',
                    datasetId: id),
                quality: catalogue
                    ? DataQuality.imported
                    : DataQuality.userEntered,
                allergens: allergens),
            Exact.parse('100'))
      ],
    );

Future<void> _seedCatalogueFood(AppDatabase db, Food food) =>
    DriftFoodRepository(db).replaceCatalogueBatch([food]);

Food _foodWithAllergens(Food food, Set<String>? allergens) => Food(
      id: food.id,
      name: food.name,
      per100g: food.per100g,
      source: food.source,
      quality: food.quality,
      allergens: allergens,
      preparation: food.preparation,
      basisUnit: food.basisUnit,
      basisValue: food.basisValue,
    );

Map<String, Object?> _planMetadata({
  String startDate = '2026-11-10',
  int days = 1,
  String label = 'Dinner',
  List<Exact>? portions,
  List<String>? excludedSlotIds,
  List<String>? unavailableFoodIds,
  int revision = 1,
  int? maximumMinutes,
  int? maximumRepeats,
  Exact? energyMinimum,
  Exact? energyMaximum,
}) =>
    {
      'schedule': <String, Object?>{
        'startDate': startDate,
        'days': days,
        'label': label,
        'portions': [for (final value in portions ?? [Exact.one]) value.toJson()],
        if (excludedSlotIds != null) 'excludedSlotIds': excludedSlotIds,
      },
      'constraints': <String, Object?>{
        'maximumMinutes': maximumMinutes,
        'maximumRepeats': maximumRepeats,
        'energyMinimum': energyMinimum?.toJson(),
        'energyMaximum': energyMaximum?.toJson(),
        if (unavailableFoodIds != null) 'unavailableFoodIds': unavailableFoodIds,
      },
      'constraintRevision': revision,
      'acceptedRelaxations': <Object?>[],
    };

PlannedMeal _meal(
  String slot,
  String date,
  RecipeVersion recipe,
  String portions, {
  String? batchId,
  String? allocationId,
  int batchRevision = 1,
  bool pinned = false,
}) {
  if (batchId != null && allocationId == null) {
    throw ArgumentError('allocationId is required with batchId');
  }
  return PlannedMeal(
    MealSlot(slot, date, 'Dinner'),
    recipe,
    Exact.parse(portions),
    pinned: pinned,
    batchUse: batchId == null
        ? null
        : PlannedBatchUse(
            batchId,
            batchRevision,
            allocationId ?? (throw ArgumentError('allocationId is required')),
          ),
  );
}

Future<void> _seedBatch(
  AppDatabase db, {
  String id = 'b',
  required RecipeVersion recipe,
  String available = '600',
  String finishedWeight = '600',
  String unit = 'g',
  List<Map<String, Object?>> allocations = const [],
}) async {
  await _seedRecipe(db, recipe);
  await LocalWorkspace(db).put(
    requestId: 'seed-batch-$id',
    collection: 'batch',
    id: id,
    expectedRevision: 0,
    data: {
      'recipe': recipeSnapshot(recipe),
      'available': Exact.parse(available).toJson(),
      'finishedWeightG': Exact.parse(finishedWeight).toJson(),
      'unit': unit,
      'allocations': allocations,
    },
  );
}

Future<void> _seedRawBatch(
  AppDatabase db, {
  String id = 'b',
  required RecipeVersion recipe,
  required String unit,
  String available = '600',
  String? finishedWeight = '600',
  List<Map<String, Object?>> allocations = const [],
}) async {
  await _seedRecipe(db, recipe);
  await db.into(db.userDocuments).insertOnConflictUpdate(
      UserDocumentsCompanion.insert(
          collection: 'batch',
          id: id,
          revision: 1,
          payload: jsonEncode({
            'recipe': recipeSnapshot(recipe),
            'available': Exact.parse(available).toJson(),
            'finishedWeightG': finishedWeight == null
                ? null
                : Exact.parse(finishedWeight).toJson(),
            'unit': unit,
            'allocations': allocations,
          })));
}

Future<void> _seedRecipe(AppDatabase db, RecipeVersion recipe) async {
  // Plan saves validate against real catalog_foods rows; fixtures must not rely
  // on test/fixture provenance. Seed the active definition for every
  // ingredient, then the immutable recipe revision.
  for (final ingredient in recipe.ingredients) {
    await _seedCatalogueFood(db, ingredient.food);
  }
  final id = '${recipe.id}:${recipe.revision}';
  final workspace = LocalWorkspace(db);
  if ((await workspace.read('recipe', id)) != null) return;
  await workspace.put(
    requestId: 'seed-recipe-$id',
    collection: 'recipe',
    id: id,
    expectedRevision: 0,
    data: recipeSnapshot(recipe),
  );
}

Future<void> _seedPlan(
  AppDatabase db, {
  required List<PlannedMeal> meals,
  String requestId = 'seed-plan',
  int expectedRevision = 0,
  Map<String, Object?> extra = const {},
}) async {
  for (final meal in meals) {
    await _seedRecipe(db, meal.recipe);
  }
  await LocalWorkspace(db).put(
    requestId: requestId,
    collection: 'plan',
    id: 'current',
    expectedRevision: expectedRevision,
    data: {
      'seed': 7,
      'policyVersion': 'planner-v2',
      ...extra,
      'meals': [for (final meal in meals) _mealJson(meal)],
    },
  );
}

Future<void> _seedIntake(
  AppDatabase db, {
  required String entryId,
  required String requestId,
  required String batchId,
  required String reservedAllocationId,
  String? grams,
  String? servings,
  String? unit,
}) async {
  if ((grams == null) == (servings == null)) {
    throw ArgumentError('Pass exactly one of grams or servings');
  }
  final now = DateTime.utc(2026, 1, 1);
  await DriftEntryRepository(db).append(LoggedEntry(
    id: entryId,
    requestId: requestId,
    diaryDate: DiaryDate(2026, 1, 1),
    stamp: EventStamp(instant: now, offsetMinutes: 0),
    channel: EntryChannel.manual,
    recordedAt: now,
    items: [
      LoggedItem(
        name: 'Soup',
        grams: grams == null ? null : Exact.parse(grams).toDouble(),
        nutrients: NutrientProfile({}),
        sourceSnapshot: {
          'batchId': batchId,
          'recipeId': 'r1',
          'recipeRevision': 1,
          if (grams != null) 'finishedWeightG': Exact.parse('600').toJson(),
          if (servings != null) 'recipeServings': Exact.parse('3').toJson(),
          'allocationScale': (grams != null
                  ? Exact.one
                  : Exact.parse(servings!) / Exact.parse('3'))
              .toJson(),
          if (grams != null) 'consumedBatchGrams': Exact.parse(grams).toJson(),
          if (servings != null)
            'consumedBatchServings': Exact.parse(servings).toJson(),
          if (unit != null) 'consumedBatchUnit': unit,
          'reservedAllocationId': reservedAllocationId,
          'quantityBasis': 'raw-edible-ingredient-allocation',
        },
      )
    ],
  ));
}

Map<String, Object?> _alloc(
  String id,
  String grams,
  String status, {
  String? intakeRequestId,
}) =>
    {
      'id': id,
      'amount': Exact.parse(grams).toJson(),
      'status': status,
      if (intakeRequestId != null) 'intakeRequestId': intakeRequestId,
    };

Map<String, Object?> _mealJson(PlannedMeal meal) => {
      'slot': meal.slot.id,
      'date': meal.slot.date,
      'label': meal.slot.label,
      'recipe': recipeSnapshot(meal.recipe),
      'portions': meal.portions.toJson(),
      'pinned': meal.pinned,
      if (meal.batchUse != null)
        'batchUse': {
          'batchId': meal.batchUse!.batchId,
          'batchRevision': meal.batchUse!.batchRevision,
          'allocationId': meal.batchUse!.allocationId,
        },
    };

List<Map<String, Object?>> _allocations(StoredDocument doc) => [
      for (final raw in doc.data['allocations']! as List<Object?>)
        Map<String, Object?>.from(raw! as Map)
    ];

Exact _amountOf(Map<String, Object?> allocation) =>
    Exact.fromJson(Map<String, Object?>.from(allocation['amount']! as Map));

Matcher _planError(String code) => throwsA(
    isA<PlanException>().having((error) => error.code, 'code', code));

Future<Object?> _outcome(Future<PlanSaveResult> future) async {
  try {
    return await future;
  } on Object catch (error) {
    return error;
  }
}

Future<int> _planReceipts(AppDatabase db) async {
  final rows = await db.select(db.appliedCommands).get();
  return rows
      .where((row) =>
          row.requestId.startsWith('plan-save:') ||
          row.requestId.startsWith('batch-reserve:plan-reserve:') ||
          row.requestId.startsWith('batch-release:plan-release:'))
      .length;
}
