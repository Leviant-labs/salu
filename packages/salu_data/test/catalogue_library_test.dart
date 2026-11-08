import 'dart:convert';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

final class TestClock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 11, 8, 12);
}

Food food(
        {String id = 'test:apple',
        String name = 'Maçã',
        String version = '1',
        List<String> aliases = const ['apple'],
        List<String> barcodes = const ['4006381333931']}) =>
    Food(
        id: id,
        name: name,
        per100g: NutrientProfile({
          NutrientKey.energyKcal: NutrientReported.exact(Exact.parse('52'))
        }),
        source: FoodSource(
            dataset: 'test',
            datasetId: id,
            datasetVersion: version,
            licence: 'fixture-only'),
        aliases: aliases,
        barcodes: barcodes,
        regions: const ['PT'],
        preparation: Preparation.raw);
void main() {
  late AppDatabase db;
  late DriftFoodRepository foods;
  late FoodLibraryService library;
  setUp(() {
    db = AppDatabase.memory();
    foods = DriftFoodRepository(db);
    library = FoodLibraryService(db, TestClock(), SequentialIdGenerator());
  });
  tearDown(() => db.close());
  test(
      'accent and alias search, barcode, preparation and index updates work offline',
      () async {
    await foods.replaceCatalogueBatch([food()]);
    expect((await foods.search('maca')).single.id, 'test:apple');
    expect((await foods.search('apple')).single.name, 'Maçã');
    expect(await foods.search('" OR * --'), isEmpty);
    expect(
        await foods.searchCatalogue(
            CatalogueQuery('apple', preparation: Preparation.cooked)),
        isEmpty);
    expect(
        (await foods.findByBarcode(ProductBarcode('4006381333931'))).single.id,
        'test:apple');
    await foods.replaceCatalogueBatch([
      food(name: 'Pera', aliases: ['pear'], barcodes: [])
    ]);
    expect(await foods.search('apple'), isEmpty);
    expect((await foods.search('pear')).single.name, 'Pera');
    db.ftsAvailable = false;
    expect((await foods.search('pera')).single.id, 'test:apple');
  });
  test(
      'favorite retry checks original payload, preserves newer state and retired snapshot',
      () async {
    await foods.replaceCatalogueBatch([food()]);
    final first = SetFavoriteFoodCommand(
        requestId: 'fav1', foodId: 'test:apple', favorite: true);
    await library.setFavorite(first);
    await library.setFavorite(SetFavoriteFoodCommand(
        requestId: 'fav2', foodId: 'test:apple', favorite: false));
    await library.setFavorite(first);
    expect(await library.favorites(), isEmpty);
    await expectLater(
        library.setFavorite(SetFavoriteFoodCommand(
            requestId: 'fav1', foodId: 'different', favorite: true)),
        throwsStateError);
    await library.setFavorite(SetFavoriteFoodCommand(
        requestId: 'fav3', foodId: 'test:apple', favorite: true));
    await db.delete(db.catalogFoods).go();
    expect((await foods.search('maca')).single.name, 'Maçã');
    expect((await library.favorites()).single.source.licence, 'fixture-only');
  });
  test(
      'saved meals freeze values and require confirmation; exact repeat/time/retry survives archive',
      () async {
    await foods.replaceCatalogueBatch([food()]);
    final handler = LogFoodHandler(
        foods: foods,
        entries: DriftEntryRepository(db),
        clock: TestClock(),
        ids: SequentialIdGenerator(prefix: 'original'));
    await handler.handle(LogFoodCommand(
        requestId: 'original',
        foodId: 'test:apple',
        quantity: MassQuantity(33.333),
        exactQuantity: FoodAmount('33.333', FoodUnit.g),
        offsetMinutes: 60,
        eatenAt: DateTime.utc(2025, 3, 30, 0, 15),
        diaryDate: DiaryDate(2025, 3, 29)));
    await library.saveMeal(SaveMealCommand(
        requestId: 'meal', entryRequestId: 'original', name: 'Breakfast'));
    await foods.replaceCatalogueBatch([food(name: 'Changed')]);
    LogSavedMealCommand command(bool confirmed) => LogSavedMealCommand(
        requestId: 'repeat',
        mealId: 'meal',
        confirmed: confirmed,
        multiplier: Exact.parse('0.5'),
        stamp: EventStamp(
            instant: DateTime.utc(2025, 3, 30, 0, 30), offsetMinutes: 60),
        diaryDate: DiaryDate(2025, 3, 29));
    await expectLater(library.logSavedMeal(command(false)), throwsStateError);
    final entry = await library.logSavedMeal(command(true));
    expect(entry.items.single.name, 'Maçã');
    expect(entry.items.single.quantity!.value, Exact.parse('16.6665'));
    expect(entry.diaryDate, DiaryDate(2025, 3, 29));
    expect(entry.stamp.offsetMinutes, 60);
    expect((await library.logSavedMeal(command(true))).id, entry.id);
    final archive = await ArchiveService(db).exportJson();
    await ArchiveService(db).restoreJson(archive, confirmed: true);
    expect((await library.workspace.list('saved-meal')).single.data['name'],
        'Breakfast');
    expect((await library.recent()).single.id, 'test:apple');
  });
  test('dataset activation is review gated, atomic and preserves user/history',
      () async {
    await foods.replaceCatalogueBatch([
      Food(
          id: 'custom:one',
          name: 'My food',
          per100g: NutrientProfile({}),
          source: FoodSource(dataset: 'custom-user-entry', datasetId: 'one'))
    ]);
    final pack = CataloguePack(
        dataset: 'test',
        version: '1',
        licence: 'fixture-only',
        attribution: 'Test fixture, not production data',
        foods: [food()]);
    await expectLater(
        CatalogueInstallService(db).activate(pack, confirmed: true),
        throwsStateError);
    final installer = CatalogueInstallService(db, approvedReviews: [
      const DatasetReview(
          dataset: 'test',
          version: '1',
          licence: 'fixture-only',
          reviewId: 'test-review')
    ]);
    await expectLater(
        installer.activate(pack, confirmed: false), throwsStateError);
    await installer.activate(CataloguePack.decode(pack.encode()),
        confirmed: true);
    expect(await foods.findById('custom:one'), isNotNull);
    expect((await db.select(db.catalogDatasets).get()).single.reviewId,
        'test-review');
    final invalid = CataloguePack(
        dataset: 'test',
        version: '1',
        licence: 'fixture-only',
        attribution: 'Fixture',
        foods: [
          food(barcodes: ['invalid'])
        ]);
    await expectLater(
        installer.activate(invalid, confirmed: true), throwsFormatException);
    expect(await foods.findById('test:apple'), isNotNull);
  });
  test('time corrections move diary day while preserving nutrient snapshots',
      () async {
    await foods.replaceCatalogueBatch([food()]);
    final entries = DriftEntryRepository(db);
    final result = await LogFoodHandler(
            foods: foods,
            entries: entries,
            clock: TestClock(),
            ids: SequentialIdGenerator())
        .handle(LogFoodCommand(
            requestId: 'time-source',
            foodId: 'test:apple',
            quantity: MassQuantity(100),
            offsetMinutes: 60,
            eatenAt: DateTime.utc(2025, 3, 29, 23, 15),
            diaryDate: DiaryDate(2025, 3, 29))) as LoggedFood;
    final before = result.entry.items.single.nutrients.toJson();
    final corrected = EventStamp(
        instant: DateTime.utc(2025, 3, 30, 1, 15), offsetMinutes: 120);
    await entries.revise(ReviseEntryCommand(
        requestId: 'correct-time',
        entryId: result.entry.id,
        expectedRevision: 1,
        recordedAt: TestClock().nowUtc(),
        stamp: corrected,
        diaryDate: DiaryDate(2025, 3, 30)));
    expect(await entries.entriesFor(DiaryDate(2025, 3, 29)), isEmpty);
    final updated = (await entries.entriesFor(DiaryDate(2025, 3, 30))).single;
    expect(updated.stamp, corrected);
    expect(updated.items.single.nutrients.toJson(), before);
    expect(
        (await LocalWorkspace(db).list('entry-revision')).single.data['entry'],
        isA<Map<String, Object?>>());
  });
  test(
      'nutrient definition provenance survives catalogue, diary, recipe and archive',
      () async {
    final observations = [
      NutrientObservation(
          nutrient: const NutrientIdentity(
              'carbohydrate_g', 'g', 'us_total_including_fibre'),
          basis: FoodAmount('100', FoodUnit.g),
          qualifier: ObservationQualifier.reported,
          sourceId: 'source',
          sourceVersion: 'v1',
          origin: 'label',
          amount: '12.345')
    ];
    final f = Food(
        id: 'defined',
        name: 'Defined label',
        per100g: projectObservations(observations,
            basis: FoodAmount('100', FoodUnit.g)),
        source: const FoodSource(
            dataset: 'custom',
            datasetId: 'source',
            datasetVersion: 'v1',
            licence: 'personal-label'),
        observations: observations);
    await foods.replaceCatalogueBatch([f]);
    final result = await LogFoodHandler(
            foods: foods,
            entries: DriftEntryRepository(db),
            clock: TestClock(),
            ids: SequentialIdGenerator())
        .handle(LogFoodCommand(
            requestId: 'defined-log',
            foodId: f.id,
            quantity: MassQuantity(50),
            offsetMinutes: 0)) as LoggedFood;
    expect(result.entry.items.single.nutrients[NutrientKey.carbohydrateG],
        isA<NutrientUnknown>());
    expect(
        (result.entry.items.single.sourceSnapshot!['observations']! as List)
            .single,
        observations.single.toJson());
    final recipe = RecipeVersion(
        id: 'recipe',
        revision: 1,
        name: 'Recipe',
        servings: Exact.one,
        minutes: 1,
        ingredients: [RecipeIngredient(f, Exact.parse('50'))]);
    expect(
        recipeFromSnapshot(recipeSnapshot(recipe))
            .ingredients
            .single
            .food
            .observations
            .single
            .amount,
        Exact.parse('12.345'));
    final archive = await ArchiveService(db).exportJson();
    await ArchiveService(db).restoreJson(archive, confirmed: true);
    expect(
        (await foods.findById(f.id))!.observations.single.nutrient.definition,
        'us_total_including_fibre');
    final bad = jsonDecode(archive) as Map;
    final rows = (bad['tables'] as Map)['catalog_foods'] as List;
    final details =
        jsonDecode((rows.single as Map)['details_json'] as String) as Map;
    details['barcodes'] = ['invalid'];
    (rows.single as Map)['details_json'] = jsonEncode(details);
    await expectLater(
        ArchiveService(db).restoreJson(jsonEncode(bad), confirmed: true),
        throwsFormatException);
    expect(await ArchiveService(db).exportJson(), archive);
  });
  test('exact count-based label logs without inventing a mass conversion',
      () async {
    final observation = NutrientObservation(
        nutrient:
            const NutrientIdentity('energy_kcal', 'kcal', 'declared_energy'),
        basis: FoodAmount('1', FoodUnit.item, measureId: 'piece'),
        qualifier: ObservationQualifier.reported,
        sourceId: 'item',
        sourceVersion: '1',
        origin: 'label',
        amount: '26');
    await foods.replaceCatalogueBatch([
      Food(
          id: 'item',
          name: 'One item',
          per100g: projectObservations([observation], basis: observation.basis),
          source: const FoodSource(dataset: 'custom', datasetId: 'item'),
          basisValue: '1',
          basisUnit: FoodUnit.item,
          observations: [observation])
    ]);
    final result = await LogFoodHandler(
            foods: foods,
            entries: DriftEntryRepository(db),
            clock: TestClock(),
            ids: SequentialIdGenerator())
        .handle(LogFoodCommand(
            requestId: 'item-log',
            foodId: 'item',
            quantity: PieceQuantity(0.5),
            exactQuantity: FoodAmount('0.5', FoodUnit.item, measureId: 'piece'),
            offsetMinutes: 0)) as LoggedFood;
    expect(result.entry.items.single.grams, isNull);
    expect(
        result
            .entry.items.single.nutrients[NutrientKey.energyKcal].numericValue,
        13);
  });
  test('version 2 archives restore with defaults and rebuild searchable index',
      () async {
    await foods.replaceCatalogueBatch([food()]);
    final root = jsonDecode(await ArchiveService(db).exportJson()) as Map;
    root['version'] = 2;
    final tables = root['tables'] as Map;
    tables.remove('catalog_datasets');
    for (final row in tables['catalog_foods'] as List) {
      (row as Map).remove('details_json');
      row.remove('search_aliases');
    }
    await ArchiveService(db).restoreJson(jsonEncode(root), confirmed: true);
    expect((await foods.search('maca')).single.name, 'Maçã');
    expect((await foods.findById('test:apple'))!.aliases, isEmpty);
  });
  test('real schema 2 SQLite upgrades with original columns unchanged',
      () async {
    final root = jsonDecode(await ArchiveService(db).exportJson()) as Map;
    final raw = sqlite.sqlite3.openInMemory();
    for (final row in await db
        .customSelect(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name IN ('catalog_foods','log_entries','log_entry_items','user_documents','applied_commands')")
        .get()) {
      var sql = row.read<String>('sql');
      if (sql.contains('catalog_foods')) {
        sql =
            "CREATE TABLE catalog_foods(id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL,source TEXT NOT NULL,source_id TEXT NOT NULL,source_version TEXT,per100g_json TEXT NOT NULL,portion_grams REAL,density_g_per_ml REAL,quality TEXT NOT NULL,allergens_json TEXT,dietary_tags_json TEXT NOT NULL DEFAULT '[]',preparation TEXT NOT NULL,imported_at INTEGER NOT NULL,basis_unit TEXT NOT NULL DEFAULT 'g',basis_value TEXT NOT NULL DEFAULT '100')";
      }
      raw.execute(sql);
    }
    // Assert fixture is genuinely v2 before invoking the new migration.
    expect(raw.select('PRAGMA table_info(catalog_foods)').map((r) => r['name']),
        isNot(contains('details_json')));
    raw.execute(
        "INSERT INTO catalog_foods(id,name,source,source_id,per100g_json,quality,preparation,imported_at) VALUES('old','Maçã','legacy','old','{}','imported','raw',0)");
    raw.execute('PRAGMA user_version=2');
    final before = Map<String, Object?>.from(
        raw.select('SELECT * FROM catalog_foods').single);
    final upgraded = AppDatabase(NativeDatabase.opened(raw));
    try {
      final after = (await upgraded
              .customSelect('SELECT * FROM catalog_foods')
              .getSingle())
          .data;
      for (final key in before.keys) {
        expect(after[key], before[key]);
      }
      expect((await DriftFoodRepository(upgraded).search('maca')).single.id,
          'old');
      expect((root['tables'] as Map).containsKey('catalog_datasets'), isTrue);
    } finally {
      await upgraded.close();
    }
  });
}
