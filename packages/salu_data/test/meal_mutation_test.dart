import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

final class _FakeClock implements Clock {
  _FakeClock(this._now);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void advance(Duration delta) {
    _now = _now.add(delta);
  }
}

void main() {
  final today = DiaryDate.parse('2026-11-19');

  test('move keeps identity and delete undo advances revision', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final createdAt = DateTime.utc(2026, 11, 19, 12, 30);
    await meals.saveNew(PhotoMeal(
      id: 'meal',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Soup',
      createdAt: createdAt,
      recordedOffsetMinutes: -300,
      photoPath: 'media:photo',
      items: [
        PhotoMealItem(
          id: 'item-1',
          name: 'Tomato soup',
          labelPath: 'media:label-1',
        ),
      ],
    ));

    final moved = await mutations.apply(MoveMeal(
      requestId: 'move',
      mealId: 'meal',
      expectedRevision: 1,
      date: today.addDays(-1),
      today: today,
    ));
    expect(moved.status, MutationStatus.applied);
    expect(moved.meal!.id, 'meal');
    expect(moved.meal!.date, today.addDays(-1));
    expect(moved.meal!.createdAt, createdAt);
    expect(moved.meal!.recordedOffsetMinutes, -300);
    expect(moved.meal!.photoPath, 'media:photo');
    expect(moved.meal!.items.single.labelPaths, ['media:label-1']);
    expect(await meals.listFor(today), isEmpty);
    expect((await meals.listFor(today.addDays(-1))).single.id, 'meal');

    final deleted = await mutations.apply(DeleteMeal(
      requestId: 'delete',
      mealId: 'meal',
      expectedRevision: moved.meal!.revision,
    ));
    expect(deleted.status, MutationStatus.applied);
    expect(deleted.undoToken, isNotNull);
    expect(await meals.listFor(today.addDays(-1)), isEmpty);

    final undone = await mutations.apply(UndoMeal(
      requestId: 'undo',
      undoToken: deleted.undoToken!,
    ));
    expect(undone.status, MutationStatus.applied);
    expect(undone.meal!.revision, greaterThan(moved.meal!.revision));
    expect(undone.meal!.photoPath, 'media:photo');
    expect(undone.meal!.createdAt, createdAt);
    expect(undone.meal!.recordedOffsetMinutes, -300);
    expect(undone.meal!.items.single.labelPaths, ['media:label-1']);
  });

  test('move rejects future date with invalidDate', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    await meals.saveNew(PhotoMeal(
      id: 'meal-future',
      date: today,
      slot: MealSlot.dinner,
      caption: 'Pasta',
      createdAt: DateTime.utc(2026, 11, 19),
    ));

    final result = await mutations.apply(MoveMeal(
      requestId: 'move-future',
      mealId: 'meal-future',
      expectedRevision: 1,
      date: today.addDays(1),
      today: today,
    ));
    expect(result.status, MutationStatus.invalidDate);
    expect((await meals.listFor(today)).single.date, today);
  });

  test('late pre-deletion estimate cannot overwrite undone meal', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final estimateStore = MealEstimateStatusStore(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final original = PhotoMeal(
      id: 'meal-est',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Bowl',
      createdAt: DateTime.utc(2026, 11, 19),
      estimateStatus: MealEstimateStatus.pending,
    );
    await meals.saveNew(original);

    final deleted = await mutations.apply(const DeleteMeal(
      requestId: 'del-est',
      mealId: 'meal-est',
      expectedRevision: 1,
    ));
    expect(deleted.status, MutationStatus.applied);

    // Late estimate arriving while deleted must fail.
    final lateWhileDeleted = await estimateStore.finish(
      original.copyWith(estimateStatus: MealEstimateStatus.complete),
      1,
    );
    expect(lateWhileDeleted, isFalse);

    final undone = await mutations.apply(UndoMeal(
      requestId: 'undo-est',
      undoToken: deleted.undoToken!,
    ));
    expect(undone.status, MutationStatus.applied);
    expect(undone.meal!.revision, greaterThanOrEqualTo(3));

    // Late estimate captured at revision 1 arriving after undo must fail.
    final lateAfterUndo = await estimateStore.finish(
      original.copyWith(
        estimateStatus: MealEstimateStatus.complete,
        items: [PhotoMealItem(name: 'Stale estimate')],
      ),
      1,
    );
    expect(lateAfterUndo, isFalse);
    final stored = (await meals.listFor(today)).single;
    expect(stored.revision, undone.meal!.revision);
    expect(stored.items, isEmpty);
  });

  test(
      'duplicate requestId returns alreadyApplied for identical payload and stale for changed payload',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    await meals.saveNew(PhotoMeal(
      id: 'meal-dup',
      date: today,
      slot: MealSlot.breakfast,
      caption: 'Oats',
      createdAt: DateTime.utc(2026, 11, 19),
    ));

    final cmd = MoveMeal(
      requestId: 'req-1',
      mealId: 'meal-dup',
      expectedRevision: 1,
      date: today.addDays(-1),
      today: today,
    );
    final first = await mutations.apply(cmd);
    expect(first.status, MutationStatus.applied);

    final replay = await mutations.apply(cmd);
    expect(replay.status, MutationStatus.alreadyApplied);
    expect(replay.meal!.date, today.addDays(-1));
    expect(replay.meal!.revision, first.meal!.revision);

    final mutatedReplay = await mutations.apply(MoveMeal(
      requestId: 'req-1',
      mealId: 'meal-dup',
      expectedRevision: 1,
      date: today.addDays(-2),
      today: today,
    ));
    expect(mutatedReplay.status, MutationStatus.stale);
  });

  test('stale revision is rejected and expired undo is rejected via fake clock',
      () async {
    final clock = _FakeClock(DateTime.utc(2026, 11, 19, 10, 0));
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: clock);
    final initial = PhotoMeal(
      id: 'meal-stale',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Salad',
      createdAt: DateTime.utc(2026, 11, 19),
    );
    await meals.saveNew(initial);

    final staleRevise = await mutations.apply(ReviseMeal(
      requestId: 'rev-stale',
      meal: initial.copyWith(caption: 'New'),
      expectedRevision: 99,
    ));
    expect(staleRevise.status, MutationStatus.stale);

    final deleted = await mutations.apply(const DeleteMeal(
      requestId: 'del-exp',
      mealId: 'meal-stale',
      expectedRevision: 1,
    ));
    expect(deleted.status, MutationStatus.applied);

    clock.advance(const Duration(hours: 24, seconds: 1));
    final expiredUndo = await mutations.apply(UndoMeal(
      requestId: 'undo-exp',
      undoToken: deleted.undoToken!,
    ));
    expect(expiredUndo.status, MutationStatus.expired);
    expect(await meals.listFor(today), isEmpty);
  });

  test('removing meal photo does not implicitly remove label evidence',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final initial = PhotoMeal(
      id: 'meal-photo',
      date: today,
      slot: MealSlot.snack,
      caption: 'Yogurt',
      createdAt: DateTime.utc(2026, 11, 19),
      photoPath: 'media:meal-photo-1',
      items: [
        PhotoMealItem(
          id: 'item-yogurt',
          name: 'Greek yogurt',
          labelPath: 'media:label-yogurt-1',
        ),
      ],
    );
    await meals.saveNew(initial);

    final revised = await mutations.apply(ReviseMeal(
      requestId: 'rev-clear-photo',
      meal: initial.copyWith(clearPhoto: true),
      expectedRevision: 1,
    ));
    expect(revised.status, MutationStatus.applied);
    expect(revised.meal!.photoPath, isNull);
    expect(revised.meal!.items.single.labelPaths, ['media:label-yogurt-1']);
  });

  test('deleting a batch-derived meal does not replenish cooked-batches stock',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final docs = LocalDocumentStore(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());

    await docs.put('cooked-batches', 0, <String, Object?>{
      'batches': [
        {
          'id': 'batch-1',
          'name': 'Chili',
          'remainingServings': 3,
        }
      ],
    });
    await meals.saveNew(PhotoMeal(
      id: 'meal-batch',
      date: today,
      slot: MealSlot.dinner,
      caption: 'Chili serving',
      createdAt: DateTime.utc(2026, 11, 19),
      items: [
        PhotoMealItem(
          id: 'item-chili',
          name: 'Chili',
          source: 'batch:batch-1',
        ),
      ],
    ));

    final deleted = await mutations.apply(const DeleteMeal(
      requestId: 'del-batch',
      mealId: 'meal-batch',
      expectedRevision: 1,
    ));
    expect(deleted.status, MutationStatus.applied);

    final batchesDoc = await docs.read('cooked-batches');
    final batches = batchesDoc!.data['batches'] as List;
    expect((batches.single as Map)['remainingServings'], 3);
  });

  test('concurrent edits on same expectedRevision allow only one winner',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final initial = PhotoMeal(
      id: 'meal-race',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Original',
      createdAt: DateTime.utc(2026, 11, 19),
    );
    await meals.saveNew(initial);

    final results = await Future.wait([
      mutations.apply(ReviseMeal(
        requestId: 'race-a',
        meal: initial.copyWith(caption: 'Edit A'),
        expectedRevision: 1,
      )),
      mutations.apply(ReviseMeal(
        requestId: 'race-b',
        meal: initial.copyWith(caption: 'Edit B'),
        expectedRevision: 1,
      )),
    ]);

    final statuses = results.map((r) => r.status).toSet();
    expect(statuses, {MutationStatus.applied, MutationStatus.stale});
  });

  test('referencedMedia keeps unexpired deleted-meal media and drops expired',
      () async {
    final clock = _FakeClock(DateTime.utc(2026, 11, 19, 12, 0));
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: clock);

    await meals.saveNew(PhotoMeal(
      id: 'meal-live',
      date: today,
      slot: MealSlot.breakfast,
      caption: 'Live',
      createdAt: DateTime.utc(2026, 11, 19),
      photoPath: 'media:live-photo',
    ));
    await meals.saveNew(PhotoMeal(
      id: 'meal-del',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Deleted',
      createdAt: DateTime.utc(2026, 11, 19),
      photoPath: 'media:del-photo',
      items: [
        PhotoMealItem(name: 'Bar', labelPath: 'media:del-label'),
      ],
    ));

    await mutations.apply(const DeleteMeal(
      requestId: 'del-media',
      mealId: 'meal-del',
      expectedRevision: 1,
    ));

    // Within 24h: deleted meal's photo and label remain referenced.
    final beforeExpiry = await mutations.referencedMedia(
      clock.nowUtc().add(const Duration(hours: 23)),
    );
    expect(
      beforeExpiry,
      containsAll(['media:live-photo', 'media:del-photo', 'media:del-label']),
    );

    // After 24h: deleted meal's media is no longer referenced.
    final afterExpiry = await mutations.referencedMedia(
      clock.nowUtc().add(const Duration(hours: 25)),
    );
    expect(afterExpiry, {'media:live-photo'});
  });

  test('purgeExpiredUndoStatus removes orphaned estimate status docs after 24h',
      () async {
    final clock = _FakeClock(DateTime.utc(2026, 11, 19, 12, 0));
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final estimateStore = MealEstimateStatusStore(db);
    final docs = LocalDocumentStore(db);
    final mutations = MealMutationRepository(db, clock: clock);

    final meal = PhotoMeal(
      id: 'meal-orphan',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Orphan',
      createdAt: DateTime.utc(2026, 11, 19),
    );
    await meals.saveNew(meal);
    await estimateStore.finish(
      meal.copyWith(estimateStatus: MealEstimateStatus.unavailable),
      1,
      errorCode: 'timeout',
    );
    expect(await docs.read('estimate:meal-orphan'), isNotNull);

    await mutations.apply(const DeleteMeal(
      requestId: 'del-orphan',
      mealId: 'meal-orphan',
      expectedRevision: 2,
    ));

    // Before expiry: still kept.
    expect(
      await mutations.purgeExpiredUndoStatus(
        clock.nowUtc().add(const Duration(hours: 12)),
      ),
      0,
    );
    expect(await docs.read('estimate:meal-orphan'), isNotNull);

    // After expiry: purged.
    expect(
      await mutations.purgeExpiredUndoStatus(
        clock.nowUtc().add(const Duration(hours: 25)),
      ),
      1,
    );
    expect(await docs.read('estimate:meal-orphan'), isNull);
  });

  test(
      'photo_meal_codec round-trips v1, accepts legacy, rejects future versions',
      () {
    final meal = PhotoMeal(
      id: 'meal-codec',
      date: today,
      slot: MealSlot.dinner,
      caption: 'Stew',
      createdAt: DateTime.utc(2026, 11, 19, 18, 0),
      revision: 3,
      photoPath: 'media:stew',
      estimateStatus: MealEstimateStatus.complete,
      recordedOffsetMinutes: 60,
      items: [
        PhotoMealItem(
          id: 'item-1',
          name: 'Beef stew',
          labelPath: 'media:label',
          nutrients: NutrientProfile({
            NutrientKey.energyKcal: NutrientReported(420),
            NutrientKey.proteinG: NutrientEstimated(32, basis: 'photo'),
          }),
          reviewIssues: const [
            NutritionIssue(
              code: 'macroEnergyMismatch',
              nutrient: NutrientKey.energyKcal,
              blocksAutomaticUse: false,
            ),
          ],
        ),
      ],
    );

    final encoded = encodePhotoMeal(meal);
    expect(encoded['version'], 1);
    final decoded = decodePhotoMeal(encoded);
    expect(decoded.id, meal.id);
    expect(decoded.date, meal.date);
    expect(decoded.revision, 3);
    expect(decoded.recordedOffsetMinutes, 60);
    expect(
        decoded.items.single.reviewIssues.single.code, 'macroEnergyMismatch');

    // Legacy unversioned map
    final legacy = Map<String, dynamic>.from(encoded)..remove('version');
    expect(decodePhotoMeal(legacy).id, meal.id);

    // Future version rejected
    final future = Map<String, dynamic>.from(encoded)..['version'] = 2;
    expect(() => decodePhotoMeal(future), throwsFormatException);
  });

  test('schema v1, v2, and v3 fixtures upgrade to v4 preserving existing data',
      () async {
    // v1 -> v4
    final dbV1 = AppDatabase(NativeDatabase.memory(setup: (db) => db.execute('''
      PRAGMA user_version=1;
      CREATE TABLE catalog_foods (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL,
        source TEXT NOT NULL, source_id TEXT NOT NULL, source_version TEXT,
        per100g_json TEXT NOT NULL, portion_grams REAL, density_g_per_ml REAL,
        quality TEXT NOT NULL, allergens_json TEXT, dietary_tags_json TEXT NOT NULL DEFAULT '[]',
        preparation TEXT NOT NULL, imported_at INTEGER NOT NULL);
      CREATE TABLE log_entries (id TEXT NOT NULL PRIMARY KEY, request_id TEXT NOT NULL,
        diary_date TEXT NOT NULL, instant_utc_ms INTEGER NOT NULL, offset_minutes INTEGER NOT NULL,
        channel TEXT NOT NULL, recorded_at_ms INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
        note TEXT);
      CREATE TABLE log_entry_items (id TEXT NOT NULL PRIMARY KEY, entry_id TEXT NOT NULL,
        food_id TEXT, name TEXT NOT NULL, grams REAL NOT NULL, nutrients_json TEXT NOT NULL,
        position INTEGER NOT NULL);
      INSERT INTO log_entries VALUES ('e1','r1','2026-11-18',1000,0,'manual',1000,1,'Legacy note');
    ''')));
    addTearDown(dbV1.close);
    final v1Entries = await DriftEntryRepository(dbV1)
        .entriesFor(DiaryDate.parse('2026-11-18'));
    expect(v1Entries.single.note, 'Legacy note');
    expect(await dbV1.select(dbV1.mealMutations).get(), isEmpty);

    // v2 -> v4
    final dbV2 = AppDatabase(NativeDatabase.memory(setup: (db) => db.execute('''
      PRAGMA user_version=2;
      CREATE TABLE photo_meals (id TEXT NOT NULL PRIMARY KEY, diary_date TEXT NOT NULL,
        slot TEXT NOT NULL, caption TEXT NOT NULL, created_at_ms INTEGER NOT NULL,
        revision INTEGER NOT NULL, photo_path TEXT, items_json TEXT NOT NULL);
      INSERT INTO photo_meals VALUES ('m2','2026-11-18','lunch','V2 meal',5000,2,'media:v2','[]');
    ''')));
    addTearDown(dbV2.close);
    final v2Meal = (await DriftPhotoMealRepository(dbV2)
            .listFor(DiaryDate.parse('2026-11-18')))
        .single;
    expect(v2Meal.caption, 'V2 meal');
    expect(v2Meal.photoPath, 'media:v2');
    expect(await dbV2.select(dbV2.mealMutations).get(), isEmpty);

    // v3 -> v4
    final dbV3 = AppDatabase(NativeDatabase.memory(setup: (db) => db.execute('''
      PRAGMA user_version=3;
      CREATE TABLE photo_meals (id TEXT NOT NULL PRIMARY KEY, diary_date TEXT NOT NULL,
        slot TEXT NOT NULL, caption TEXT NOT NULL, created_at_ms INTEGER NOT NULL,
        revision INTEGER NOT NULL, photo_path TEXT, items_json TEXT NOT NULL,
        estimate_status TEXT NOT NULL DEFAULT 'none', recorded_offset_minutes INTEGER);
      CREATE TABLE local_documents (id TEXT NOT NULL PRIMARY KEY, revision INTEGER NOT NULL,
        payload TEXT NOT NULL);
      CREATE TABLE catalog_barcodes (code TEXT NOT NULL, food_id TEXT NOT NULL,
        dataset TEXT NOT NULL, PRIMARY KEY (dataset, code));
      INSERT INTO photo_meals VALUES ('m3','2026-11-18','dinner','V3 meal',9000,4,'media:v3','[]','complete',-240);
    ''')));
    addTearDown(dbV3.close);
    final v3Meal = (await DriftPhotoMealRepository(dbV3)
            .listFor(DiaryDate.parse('2026-11-18')))
        .single;
    expect(v3Meal.caption, 'V3 meal');
    expect(v3Meal.revision, 4);
    expect(v3Meal.estimateStatus, MealEstimateStatus.complete);
    expect(v3Meal.recordedOffsetMinutes, -240);
    final moveV3 =
        await MealMutationRepository(dbV3, clock: const SystemClock())
            .apply(MoveMeal(
      requestId: 'move-v3',
      mealId: 'm3',
      expectedRevision: 4,
      date: DiaryDate.parse('2026-11-17'),
      today: today,
    ));
    expect(moveV3.status, MutationStatus.applied);
    expect(moveV3.meal!.revision, 5);
  });
}
