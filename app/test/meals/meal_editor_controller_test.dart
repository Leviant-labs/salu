import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/assistant/operation_fence.dart';
import 'package:salu/src/data_transfer/data_write_gate.dart';
import 'package:salu/src/features/meals/meal_editor_controller.dart';
import 'package:salu/src/media/managed_media_store.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

final class _SeqIdGenerator implements IdGenerator {
  int _n = 0;
  @override
  String next() => 'id-${++_n}';
}

final class _FixedClock implements Clock {
  const _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now;
}

void main() {
  late AppDatabase db;
  late DriftPhotoMealRepository repo;
  late MealMutationRepository mutations;
  late Directory tempDir;
  late ManagedMediaStore media;
  final date = DiaryDate(2026, 11, 21);

  setUp(() async {
    db = AppDatabase.memory();
    repo = DriftPhotoMealRepository(db);
    mutations = MealMutationRepository(
      db,
      clock: _FixedClock(DateTime.utc(2026, 11, 21, 12)),
    );
    tempDir = await Directory.systemTemp.createTemp('salu_ctrl_test_');
    media = ManagedMediaStore(
      directory: () async => tempDir,
      newId: _SeqIdGenerator().next,
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('saveNew saves once and duplicate requestId returns alreadySaved',
      () async {
    final controller = MealEditorController(
      repository: repo,
      mutations: mutations,
      assistant: SaluAssistant(),
      media: media,
      clock: _FixedClock(DateTime.utc(2026, 11, 21, 12)),
      ids: _SeqIdGenerator(),
    );
    addTearDown(controller.dispose);

    final first = await controller.saveNew(
      requestId: 'req-1',
      date: date,
      slot: MealSlot.lunch,
      caption: 'Soup',
      photoPath: null,
      items: [PhotoMealItem(name: 'Soup')],
      recordedOffsetMinutes: 0,
      withEstimate: false,
    );
    expect(first, isA<SaveNewSaved>());

    final second = await controller.saveNew(
      requestId: 'req-1',
      date: date,
      slot: MealSlot.lunch,
      caption: 'Soup',
      photoPath: null,
      items: [PhotoMealItem(name: 'Soup')],
      recordedOffsetMinutes: 0,
      withEstimate: false,
    );
    expect(second, isA<SaveNewAlreadySaved>());
    expect(await repo.listFor(date), hasLength(1));
  });

  test('saveChanges reports stale revision conflict', () async {
    final original = PhotoMeal(
      id: 'meal-1',
      date: date,
      slot: MealSlot.lunch,
      caption: 'Soup',
      createdAt: DateTime.utc(2026, 11, 21, 12),
      recordedOffsetMinutes: 0,
      items: [PhotoMealItem(id: 'i1', name: 'Soup')],
    );
    await repo.saveNew(original);
    // Advance revision behind controller's back.
    await repo.replace(original.copyWith(caption: 'Updated externally'), 1);

    final controller = MealEditorController(
      repository: repo,
      mutations: mutations,
      assistant: SaluAssistant(),
      media: media,
      clock: _FixedClock(DateTime.utc(2026, 11, 21, 12)),
      ids: _SeqIdGenerator(),
    );
    addTearDown(controller.dispose);

    final outcome = await controller.saveChanges(
      original: original, // stale revision 1 (db is at 2)
      date: date,
      today: date,
      slot: MealSlot.lunch,
      caption: 'My edit',
      photoPath: null,
      items: original.items,
      requestId: 'edit-1',
    );
    expect(outcome, isA<SaveChangesConflict>());
    expect(controller.conflict, isTrue);
  });

  test('write gate blocks saveNew while exclusive operation is active',
      () async {
    final gate = DataWriteGate();
    final blocker = Completer<void>();
    final gateEntered = Completer<void>();
    final exclusive = gate.exclusive(() async {
      gateEntered.complete();
      await blocker.future;
    });
    await gateEntered.future;

    final controller = MealEditorController(
      repository: repo,
      mutations: mutations,
      assistant: SaluAssistant(),
      media: media,
      gate: gate,
      fence: OperationFence(),
      clock: _FixedClock(DateTime.utc(2026, 11, 21, 12)),
      ids: _SeqIdGenerator(),
    );
    addTearDown(controller.dispose);

    final blocked = await controller.saveNew(
      requestId: 'req-gated',
      date: date,
      slot: MealSlot.dinner,
      caption: 'Salad',
      photoPath: null,
      items: [PhotoMealItem(name: 'Salad')],
      recordedOffsetMinutes: 0,
      withEstimate: false,
    );
    expect(blocked, isA<SaveNewFailed>());

    blocker.complete();
    await exclusive;
    final after = await controller.saveNew(
      requestId: 'req-gated',
      date: date,
      slot: MealSlot.dinner,
      caption: 'Salad',
      photoPath: null,
      items: [PhotoMealItem(name: 'Salad')],
      recordedOffsetMinutes: 0,
      withEstimate: false,
    );
    expect(after, isA<SaveNewSaved>());
  });
}
