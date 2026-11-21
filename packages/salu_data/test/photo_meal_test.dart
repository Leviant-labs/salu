import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

final _date = DiaryDate.parse('2026-11-18');

PhotoMeal _lunch() => PhotoMeal(
      id: 'lunch-1',
      date: _date,
      slot: MealSlot.lunch,
      caption: 'This was my lunch today',
      createdAt: DateTime.utc(2026, 11, 18, 12),
      photoPath: '/photos/lunch.jpg',
      items: [
        PhotoMealItem(
          name: 'Soup',
          portion: MealPortion(250, MealUnit.millilitres),
          nutrients: NutrientProfile({
            NutrientKey.energyKcal: NutrientEstimated(130, basis: 'photo'),
          }),
        ),
        PhotoMealItem(
          name: 'Kefir',
          portion: MealPortion(150, MealUnit.millilitres),
          nutrients: NutrientProfile({NutrientKey.fiberG: NutrientReported(0)}),
          labelPath: '/photos/label.jpg',
        ),
        PhotoMealItem(name: 'Unidentified side'),
      ],
    );

void main() {
  test('v2 photo evidence remains after migration and has stable legacy IDs',
      () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (db) => db.execute('''
      PRAGMA user_version=2;
      CREATE TABLE photo_meals (id TEXT NOT NULL PRIMARY KEY, diary_date TEXT NOT NULL,
        slot TEXT NOT NULL, caption TEXT NOT NULL, created_at_ms INTEGER NOT NULL,
        revision INTEGER NOT NULL, photo_path TEXT, items_json TEXT NOT NULL);
      INSERT INTO photo_meals VALUES ('p','2026-11-18','lunch','Photo meal',0,2,'/photo',
        '[{"name":"Soup","labelPath":"/label","nutrients":{}}]');
    ''')));
    addTearDown(db.close);
    final store = DriftPhotoMealRepository(db);
    final meal = (await store.watchFor(_date).first).single;
    expect(meal.estimateStatus, MealEstimateStatus.none);
    expect(meal.items.single.labelPaths, ['/label']);
    expect(
        await store.replace(
            meal.copyWith(
                items: [meal.items.single.copyWith(labelPath: '/other')]),
            2),
        isTrue);
    final updated = (await store.listFor(_date)).single;
    expect(updated.items.single.id, meal.items.single.id);
    expect(updated.items.single.labelPaths, ['/label', '/other']);
    expect(updated.items.single.reviewIssues, isEmpty);
  });

  test('round trips item reviewIssues and defaults missing key to empty',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = DriftPhotoMealRepository(db);
    const issues = [
      NutritionIssue(
        code: 'absoluteLimit',
        nutrient: NutrientKey.energyKcal,
        blocksAutomaticUse: true,
      ),
      NutritionIssue(
        code: 'macroEnergyMismatch',
        nutrient: NutrientKey.energyKcal,
        blocksAutomaticUse: false,
      ),
    ];
    final meal = PhotoMeal(
      id: 'reviewed-1',
      date: _date,
      slot: MealSlot.dinner,
      caption: 'Flagged dinner',
      createdAt: DateTime.utc(2026, 11, 18, 19),
      items: [
        PhotoMealItem(
          name: 'Soup',
          portion: MealPortion(250, MealUnit.grams),
          nutrients: NutrientProfile({
            NutrientKey.proteinG:
                NutrientEstimated(12, basis: 'ai-meal-estimate'),
          }),
          source: 'ai-meal-estimate',
          reviewIssues: issues,
        ),
        PhotoMealItem(name: 'Bread'),
      ],
    );

    expect(await store.saveNew(meal), isTrue);
    final loaded = (await store.listFor(_date)).single;
    expect(loaded.items.first.reviewIssues, issues);
    expect(loaded.items.first.nutrients[NutrientKey.energyKcal],
        const NutrientUnknown());
    expect(loaded.items.first.nutrients[NutrientKey.proteinG].numericValue, 12);
    expect(loaded.items.last.reviewIssues, isEmpty);
  });

  test(
      'round trips meal evidence and estimates, ignores duplicate and stale writes',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = DriftPhotoMealRepository(db);
    final lunch = _lunch();
    final attempts =
        await Future.wait([store.saveNew(lunch), store.saveNew(lunch)]);
    expect(attempts.where((applied) => applied), hasLength(1));
    final stored = (await store.listFor(_date)).single;
    expect(stored.slot, MealSlot.lunch);
    expect(stored.photoPath, lunch.photoPath);
    expect(stored.items.first.nutrients[NutrientKey.energyKcal],
        lunch.items.first.nutrients[NutrientKey.energyKcal]);
    expect(stored.items[1].portion?.amount, 150);
    expect(stored.items[1].portion?.unit, MealUnit.millilitres);
    expect(stored.items[1].labelPath, '/photos/label.jpg');
    expect(stored.items[1].nutrients[NutrientKey.fiberG], NutrientReported(0));
    expect(stored.items.last.nutrients[NutrientKey.energyKcal],
        NutrientValue.unknown);
    expect(await store.listFor(_date.addDays(1)), isEmpty);

    expect(await store.replace(stored.copyWith(items: [stored.items.first]), 1),
        isTrue);
    expect(await store.replace(stored.copyWith(caption: 'Stale'), 1), isFalse);
    final corrected = (await store.listFor(_date)).single;
    expect(corrected.revision, 2);
    expect(corrected.caption, stored.caption);
    expect(corrected.items, hasLength(1));
  });

  test('v1 diary snapshots survive migration and can coexist with photo meals',
      () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (db) {
      db.execute('''
        PRAGMA user_version = 1;
        CREATE TABLE log_entries (
          id TEXT PRIMARY KEY NOT NULL, request_id TEXT NOT NULL,
          diary_date TEXT NOT NULL, instant_utc_ms INTEGER NOT NULL,
          offset_minutes INTEGER NOT NULL, channel TEXT NOT NULL,
          recorded_at_ms INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 1, note TEXT
        );
        CREATE TABLE log_entry_items (
          id TEXT PRIMARY KEY NOT NULL,
          entry_id TEXT REFERENCES log_entries(id) ON DELETE CASCADE,
          food_id TEXT, name TEXT NOT NULL, grams REAL NOT NULL,
          nutrients_json TEXT NOT NULL, position INTEGER NOT NULL
        );
        INSERT INTO log_entries VALUES ('v1', 'old', '2026-11-18', 1795003200000, 0, 'search', 1795003200000, 1, 'unchanged');
        INSERT INTO log_entry_items VALUES ('v1-0', 'v1', NULL, 'Soup', 150.0,
          '{"energy_kcal":{"state":"measured","value":55.5}}', 0);
      ''');
    }));
    addTearDown(db.close);
    final legacy = DriftEntryRepository(db);
    final store = DriftPhotoMealRepository(db);
    expect(await store.saveNew(_lunch()), isTrue);
    final old = (await legacy.entriesFor(_date)).single;
    expect(old.note, 'unchanged');
    expect(old.items.single.grams, 150);
    expect(old.items.single.nutrients[NutrientKey.energyKcal],
        NutrientMeasured(55.5));
    expect((await store.listFor(_date)).single.id, 'lunch-1');
  });
}
