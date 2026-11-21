import 'dart:io';

import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

PhotoMeal _meal({
  String id = 'meal-1',
  int revision = 1,
  MealEstimateStatus estimateStatus = MealEstimateStatus.pending,
  List<PhotoMealItem> items = const [],
}) =>
    PhotoMeal(
      id: id,
      date: DiaryDate.parse('2026-11-19'),
      slot: MealSlot.lunch,
      caption: 'Tomato soup and bread',
      createdAt: DateTime.utc(2026, 11, 19, 12),
      revision: revision,
      estimateStatus: estimateStatus,
      items: items,
    );

void main() {
  test('finish replaces meal and persists safe error code for new revision',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final docs = LocalDocumentStore(db);
    final store = MealEstimateStatusStore(db);

    final initial = _meal(revision: 1);
    expect(await meals.saveNew(initial), isTrue);

    final failed = initial.copyWith(
      estimateStatus: MealEstimateStatus.unavailable,
    );
    expect(
      await store.finish(failed, 1, errorCode: 'quotaExceeded'),
      isTrue,
    );

    final reloaded = (await meals.listFor(initial.date)).single;
    expect(reloaded.revision, 2);
    expect(reloaded.estimateStatus, MealEstimateStatus.unavailable);
    expect(await store.errorFor('meal-1', 2), 'quotaExceeded');
    expect(await store.errorFor('meal-1', 1), isNull);
    expect(await store.errorFor('meal-1', 3), isNull);

    final rawDoc = await docs.read('estimate:meal-1');
    expect(rawDoc, isNotNull);
    expect(rawDoc!.data, {
      'version': 1,
      'revision': 2,
      'errorCode': 'quotaExceeded',
    });
    expect(rawDoc.data.containsKey('message'), isFalse);
    expect(rawDoc.data.containsKey('rawError'), isFalse);
  });

  test(
      'stale expectedRevision writes no status and leaves existing state intact',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final docs = LocalDocumentStore(db);
    final store = MealEstimateStatusStore(db);

    final initial = _meal(revision: 1);
    expect(await meals.saveNew(initial), isTrue);

    // User manually edits the meal before AI returns, advancing revision to 2.
    final userEdit = initial.copyWith(
      items: [PhotoMealItem(name: 'Roll')],
      estimateStatus: MealEstimateStatus.none,
    );
    expect(await meals.replace(userEdit, 1), isTrue);

    // Stale AI completion targeting revision 1 must fail and write no status.
    final staleUpdate = initial.copyWith(
      estimateStatus: MealEstimateStatus.unavailable,
    );
    expect(
      await store.finish(staleUpdate, 1, errorCode: 'timeout'),
      isFalse,
    );

    final reloaded = (await meals.listFor(initial.date)).single;
    expect(reloaded.revision, 2);
    expect(reloaded.items.single.name, 'Roll');
    expect(await docs.read('estimate:meal-1'), isNull);
    expect(await store.errorFor('meal-1', 2), isNull);
  });

  test('finish with null errorCode removes prior status document', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final docs = LocalDocumentStore(db);
    final store = MealEstimateStatusStore(db);

    final initial = _meal(revision: 1);
    expect(await meals.saveNew(initial), isTrue);

    expect(
      await store.finish(
        initial.copyWith(estimateStatus: MealEstimateStatus.unavailable),
        1,
        errorCode: 'notConnected',
      ),
      isTrue,
    );
    expect(await store.errorFor('meal-1', 2), 'notConnected');

    final second = (await meals.listFor(initial.date)).single;
    expect(
      await store.finish(
        second.copyWith(
          items: [PhotoMealItem(name: 'Tomato soup')],
          estimateStatus: MealEstimateStatus.complete,
        ),
        2,
      ),
      isTrue,
    );

    expect(await docs.read('estimate:meal-1'), isNull);
    expect(await store.errorFor('meal-1', 3), isNull);
  });

  test(
      'status survives database reopen across restarts and ignores unknown versions',
      () async {
    final dir = await Directory.systemTemp.createTemp('salu_estimate_status_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dbFile = File('${dir.path}/salu.sqlite');

    var db = AppDatabase(NativeDatabase(dbFile));
    final meals = DriftPhotoMealRepository(db);
    final initial = _meal(revision: 1);
    expect(await meals.saveNew(initial), isTrue);
    expect(
      await MealEstimateStatusStore(db).finish(
        initial.copyWith(estimateStatus: MealEstimateStatus.unavailable),
        1,
        errorCode: 'busy',
      ),
      isTrue,
    );
    await db.close();

    db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    final reopenedStore = MealEstimateStatusStore(db);
    expect(await reopenedStore.errorFor('meal-1', 2), 'busy');
    expect(await reopenedStore.errorFor('meal-1', 1), isNull);

    // Unknown future schema version is safely ignored.
    await LocalDocumentStore(db).put('estimate:meal-2', 0, {
      'version': 99,
      'revision': 2,
      'errorCode': 'futureError',
    });
    expect(await reopenedStore.errorFor('meal-2', 2), isNull);
  });
}
