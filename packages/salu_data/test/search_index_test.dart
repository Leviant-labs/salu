import 'dart:io';

import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:salu_data/src/catalogue/search_index.dart';
import 'package:test/test.dart';

Food _food(
  String id,
  String name, {
  String dataset = 'fixture',
  String? datasetId,
  String? datasetVersion,
}) =>
    Food(
      id: id,
      name: name,
      per100g: const NutrientProfile.empty(),
      source: FoodSource(
        dataset: dataset,
        datasetId: datasetId ?? id.split(':').last,
        datasetVersion: datasetVersion,
      ),
    );

void main() {
  test('index metadata persists and incremental food is immediately searchable',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final index = SearchIndex(db);
    await index.ensureReady();
    final food = _food('fixture:late', 'Late indexed chickpeas');
    await DriftFoodRepository(db).replaceCatalogueBatch([food]);
    expect(
      await SearchIndex(db).searchIds('chickpeas'),
      contains('fixture:late'),
    );
    expect(
      (await LocalDocumentStore(db).read('search-index-state'))!.data['format'],
      searchIndexVersion,
    );
  });

  test('reopening a file database preserves FTS rowids without rebuilding',
      () async {
    final dir = await Directory.systemTemp.createTemp('salu_search_index_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}catalogue.sqlite');

    Future<Map<String, int>> readRowIds(AppDatabase db) async {
      final rows =
          await db.customSelect('SELECT rowid, food_id FROM food_names').get();
      return {
        for (final row in rows)
          row.read<String>('food_id'): row.read<int>('rowid'),
      };
    }

    final db1 = AppDatabase(NativeDatabase(file));
    await DriftFoodRepository(db1).replaceCatalogueBatch([
      _food('fixture:1', 'Alpha lentils'),
      _food('fixture:2', 'Beta quinoa'),
    ]);
    await SearchIndex(db1).ensureReady();
    // Delete row 1 and re-insert so rowids are non-contiguous (2 and 3).
    // A rebuild would renumber them to 1 and 2.
    await DriftFoodRepository(db1).replaceCatalogueBatch([
      _food('fixture:1', 'Alpha lentils updated'),
    ]);
    final before = await readRowIds(db1);
    expect(before['fixture:1'], greaterThan(before['fixture:2']!));
    await db1.close();

    final db2 = AppDatabase(NativeDatabase(file));
    addTearDown(db2.close);
    expect(await SearchIndex(db2).ensureReady(), isTrue);
    final after = await readRowIds(db2);
    expect(after, equals(before));
    expect(await SearchIndex(db2).searchIds('lentils'), contains('fixture:1'));
  });

  test('interrupted rebuild rollback leaves no search-index-state', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftFoodRepository(db);
    await repo.replaceCatalogueBatch([
      _food('fixture:1', 'Oats'),
    ]);
    // Simulate a failing transaction during rebuild by creating a regular table
    // with a failing BEFORE INSERT trigger (so CREATE VIRTUAL TABLE IF NOT EXISTS
    // is a no-op and INSERT aborts).
    await db.customStatement('DROP TABLE IF EXISTS food_names');
    await db.customStatement(
      'CREATE TABLE food_names (food_id TEXT, search_text TEXT)',
    );
    await db.customStatement(
      "CREATE TRIGGER fail_index BEFORE INSERT ON food_names "
      "BEGIN SELECT RAISE(ABORT, 'simulated failure'); END",
    );

    await expectLater(SearchIndex(db).ensureReady(), throwsA(anything));
    expect(await LocalDocumentStore(db).read('search-index-state'), isNull);
  });

  test('pack replacement and dataset removal update index atomically',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftFoodRepository(db);
    final index = SearchIndex(db);
    await index.ensureReady();

    await repo.installEdition('pack_a', '2026-01', [
      _food('pack_a:1', 'Roasted almonds',
          dataset: 'pack_a', datasetVersion: '2026-01'),
    ]);
    expect(await index.searchIds('almonds'), contains('pack_a:1'));

    await repo.installEdition('pack_a', '2026-02', [
      _food('pack_a:2', 'Toasted hazelnuts',
          dataset: 'pack_a', datasetVersion: '2026-02'),
    ]);
    expect(await index.searchIds('almonds'), isEmpty);
    expect(await index.searchIds('hazelnuts'), contains('pack_a:2'));

    await db.transaction(() async {
      await index.removeDataset('pack_a');
    });
    expect(await index.searchIds('hazelnuts'), isEmpty);
  });

  test('stale format version triggers rebuild', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftFoodRepository(db);
    await repo.replaceCatalogueBatch([
      _food('fixture:1', 'Pao de queijo'),
    ]);
    final index = SearchIndex(db);
    await index.ensureReady();

    // Corrupt index content and downgrade persisted format.
    await db.customStatement('DELETE FROM food_names');
    final docs = LocalDocumentStore(db);
    final current = await docs.read('search-index-state');
    await docs.put('search-index-state', current!.revision, {'format': 0});

    expect(await index.ensureReady(), isTrue);
    expect(await index.searchIds('queijo'), contains('fixture:1'));
    expect(
      (await docs.read('search-index-state'))!.data['format'],
      searchIndexVersion,
    );
  });

  test('forceFallback scans past row 512 using keyset pagination', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final foods = [
      for (var i = 0; i < 600; i++)
        _food(
          'fixture:${i.toString().padLeft(4, '0')}',
          i == 580 ? 'Rare dragonfruit puree' : 'Standard item $i',
        ),
    ];
    await DriftFoodRepository(db).replaceCatalogueBatch(foods);

    final fallback = SearchIndex(db, forceFallback: true);
    expect(await fallback.ensureReady(), isFalse);
    final ids = await fallback.searchIds('dragonfruit');
    expect(ids, contains('fixture:0580'));
  });
}
