import 'dart:convert';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('v1 SQLite migration preserves all existing diary and catalogue values',
      () async {
    final raw = sqlite.sqlite3.openInMemory();
    raw.execute(
        'CREATE TABLE catalog_foods(id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL,source TEXT NOT NULL,source_id TEXT NOT NULL,source_version TEXT,per100g_json TEXT NOT NULL,portion_grams REAL,density_g_per_ml REAL,quality TEXT NOT NULL,allergens_json TEXT,dietary_tags_json TEXT NOT NULL DEFAULT \'[]\',preparation TEXT NOT NULL,imported_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE log_entries(id TEXT PRIMARY KEY NOT NULL,request_id TEXT NOT NULL UNIQUE,diary_date TEXT NOT NULL,instant_utc_ms INTEGER NOT NULL,offset_minutes INTEGER NOT NULL,channel TEXT NOT NULL,recorded_at_ms INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 1,note TEXT)');
    raw.execute(
        'CREATE TABLE log_entry_items(id TEXT PRIMARY KEY NOT NULL,entry_id TEXT NOT NULL REFERENCES log_entries(id) ON DELETE CASCADE,food_id TEXT,name TEXT NOT NULL,grams REAL NOT NULL,nutrients_json TEXT NOT NULL,position INTEGER NOT NULL)');
    raw.execute(
        "INSERT INTO log_entries VALUES ('e','request','2025-03-30',1743296400000,60,'manual',1743296400000,1,'DST history')");
    raw.execute('INSERT INTO log_entry_items VALUES (?,?,?,?,?,?,?)', [
      'i',
      'e',
      null,
      'Historical meal',
      150.25,
      '{"protein_g":{"state":"measured","value":15}}',
      0
    ]);
    raw.execute('PRAGMA user_version=1');
    final before = Map<String, Object?>.from(
        raw.select('SELECT * FROM log_entry_items').single);
    final db = AppDatabase(NativeDatabase.opened(raw));
    try {
      final after =
          (await db.customSelect('SELECT * FROM log_entry_items').getSingle())
              .data;
      for (final key in before.keys) {
        expect(after[key], before[key]);
      }
      final entry =
          (await DriftEntryRepository(db).findByRequestId('request'))!;
      expect(entry.diaryDate.toIso(), '2025-03-30');
      expect(entry.stamp.offsetMinutes, 60);
      expect(entry.items.single.grams, 150.25);
      expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          3);
    } finally {
      await db.close();
    }
  });
  test('archives round trip every table; malformed restore is atomic',
      () async {
    final a = AppDatabase.memory();
    final b = AppDatabase.memory();
    try {
      final w = LocalWorkspace(a);
      await w.put(
          requestId: 'prefs',
          collection: 'preferences',
          id: 'app',
          expectedRevision: 0,
          data: {'language': 'pt-PT', 'support': true});
      await w.reward('return:2026-11-08');
      final archive = await ArchiveService(a).exportJson();
      await ArchiveService(b).restoreJson(archive, confirmed: true);
      expect(await ArchiveService(b).exportJson(), archive);
      final invalid = Map<String, Object?>.from(jsonDecode(archive) as Map);
      final tables = invalid['tables']! as Map;
      (tables['user_documents']! as List).add({'bad': 'row'});
      await expectLater(
          ArchiveService(b).restoreJson(jsonEncode(invalid), confirmed: true),
          throwsA(anything));
      expect(await ArchiveService(b).exportJson(), archive);
      expect(archive, isNot(contains('api_key')));
      await ArchiveService(b).deleteLocalData(confirmed: true);
      expect(await LocalWorkspace(b).list('preferences'), isEmpty);
    } finally {
      await a.close();
      await b.close();
    }
  });
  test(
      'document writes are idempotent, revision checked, rewards survive restore',
      () async {
    final db = AppDatabase.memory();
    try {
      final w = LocalWorkspace(db);
      Future<int> put(String id, int rev, int v) => w.put(
          requestId: id,
          collection: 'preferences',
          id: 'app',
          expectedRevision: rev,
          data: {'v': v});
      expect(await put('r', 0, 1), 1);
      expect(await put('r', 0, 1), 1);
      await expectLater(put('r', 0, 2), throwsStateError);
      await expectLater(put('next', 0, 2), throwsStateError);
      await w.reward('engagement');
      await w.reward('engagement');
      expect(await w.list('reward'), hasLength(1));
      await expectLater(
          w.put(
              requestId: 'secret',
              collection: 'credentials',
              id: 'key',
              expectedRevision: 0,
              data: {'key': 'no'}),
          throwsArgumentError);
    } finally {
      await db.close();
    }
  });
  test(
      'native-volume log snapshots no invented grams; correction retains source',
      () async {
    final db = AppDatabase.memory();
    try {
      final foods = DriftFoodRepository(db);
      final entries = DriftEntryRepository(db);
      await foods.replaceCatalogueBatch([
        Food(
            id: 'drink',
            name: 'Drink',
            per100g:
                NutrientProfile({NutrientKey.energyKcal: NutrientReported(40)}),
            source: const FoodSource(
                dataset: 'custom', datasetId: 'drink', datasetVersion: '1'),
            basisUnit: FoodUnit.ml)
      ]);
      final handler = LogFoodHandler(
          foods: foods,
          entries: entries,
          clock: const SystemClock(),
          ids: SequentialIdGenerator());
      final logged = await handler.handle(LogFoodCommand(
          requestId: 'log',
          foodId: 'drink',
          quantity: VolumeQuantity(250),
          offsetMinutes: 60)) as LoggedFood;
      expect(logged.entry.items.single.grams, isNull);
      expect(logged.entry.nutrientSum(NutrientKey.energyKcal).value, 100);
      final stored = (await entries.findByRequestId('log'))!;
      expect(stored.items.single.quantity!.unit, FoodUnit.ml);
      expect(stored.items.single.sourceSnapshot!['dataset'], 'custom');
      final command = ReviseEntryCommand(
          requestId: 'edit',
          entryId: stored.id,
          expectedRevision: 1,
          recordedAt: DateTime.utc(2026),
          multiplier: Exact.parse('0.5'));
      expect(await entries.revise(command), 2);
      expect(await entries.revise(command), 2);
      final corrected = (await entries.findByRequestId('log'))!;
      expect(corrected.items.single.quantity!.value, Exact.parse('125'));
      expect(corrected.nutrientSum(NutrientKey.energyKcal).value, 50);
      expect(corrected.diaryDate, stored.diaryDate);
      expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));
    } finally {
      await db.close();
    }
  });
}
