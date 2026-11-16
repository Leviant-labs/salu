import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

/// Clock pinned to one instant; the core ships its own fake for core tests only.
final class FixedClock implements Clock {
  FixedClock(this.instant);

  final DateTime instant;

  @override
  DateTime nowUtc() => instant.toUtc();
}

void main() {
  late AppDatabase db;
  late DriftFoodRepository foods;
  late DriftEntryRepository entries;
  late LogFoodHandler handler;

  setUp(() async {
    db = AppDatabase.memory();
    foods = DriftFoodRepository(db);
    entries = DriftEntryRepository(db);
    await foods.replaceCatalogueBatch(developmentCatalogue());
    handler = LogFoodHandler(
      foods: foods,
      entries: entries,
      clock: FixedClock(DateTime.utc(2026, 11, 8, 12, 30)),
      ids: SequentialIdGenerator(prefix: 'entry'),
    );
  });

  tearDown(() => db.close());

  test('schema opens at version 3 with foreign keys enforced', () async {
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 3);

    final pragma = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(pragma.read<int>('foreign_keys'), 1);
  });

  test('a logged entry round-trips through SQLite with its snapshot', () async {
    final result = await handler.handle(
      LogFoodCommand(
        requestId: 'req-1',
        foodId: 'dev-chicken-breast',
        quantity: MassQuantity(150),
        offsetMinutes: 0,
      ),
    ) as LoggedFood;

    final stored = await entries.findByRequestId('req-1');
    expect(stored, isNotNull);
    expect(stored!.id, result.entry.id);
    expect(stored.items.single.grams, 150);
    expect(
      stored.nutrientSum(NutrientKey.energyKcal).value,
      closeTo(247.5, 1e-9),
    );
    expect(stored.diaryDate, DiaryDate(2026, 11, 8));

    final forDate = await entries.entriesFor(DiaryDate(2026, 11, 8));
    expect(forDate, hasLength(1));
  });

  test('nutrient state survives the database round trip', () async {
    // The fixture has a measured fiber value; ask for a nutrient it does not
    // carry and confirm the read reports "unknown", not zero.
    await handler.handle(
      LogFoodCommand(
        requestId: 'req-fiber',
        foodId: 'dev-chicken-breast',
        quantity: MassQuantity(100),
        offsetMinutes: 0,
      ),
    );

    final stored = (await entries.findByRequestId('req-fiber'))!;
    expect(stored.nutrientSum(NutrientKey.sodiumMg).isComplete, isFalse);
    expect(stored.nutrientSum(NutrientKey.fiberG).value, 0);
    expect(stored.nutrientSum(NutrientKey.fiberG).isComplete, isTrue);
  });

  test('retrying a request writes nothing new', () async {
    LogFoodCommand command() => LogFoodCommand(
          requestId: 'req-retry',
          foodId: 'dev-apple',
          quantity: MassQuantity(100),
          offsetMinutes: 0,
        );

    final first = await handler.handle(command()) as LoggedFood;
    final second = await handler.handle(command()) as LoggedFood;

    expect(second.created, isFalse);
    expect(second.entry.id, first.entry.id);
    expect(await entries.entriesFor(DiaryDate(2026, 11, 8)), hasLength(1));
  });

  test('the unique index refuses a duplicate request id at the DB level',
      () async {
    final entry = (await handler.handle(
      LogFoodCommand(
        requestId: 'req-dup',
        foodId: 'dev-apple',
        quantity: MassQuantity(100),
        offsetMinutes: 0,
      ),
    ) as LoggedFood)
        .entry;

    // Bypass the application check, as a racing writer or retried queue item
    // would, and confirm the schema itself is the backstop.
    await expectLater(entries.append(entry), throwsA(isA<Exception>()));
  });

  test('a catalogue update does not rewrite logged history', () async {
    await handler.handle(
      LogFoodCommand(
        requestId: 'req-stable',
        foodId: 'dev-apple',
        quantity: MassQuantity(100),
        offsetMinutes: 0,
      ),
    );

    final before = (await entries.findByRequestId('req-stable'))!;

    final original = developmentCatalogue().firstWhere(
      (food) => food.id == 'dev-apple',
    );
    final corrected = Food(
      id: original.id,
      name: 'Apple, corrected name',
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(999),
      }),
      source: const FoodSource(
        dataset: 'dev-fixture',
        datasetId: 'fixture',
        datasetVersion: 'v2',
      ),
    );
    await foods.replaceCatalogueBatch([corrected]);

    final after = (await entries.findByRequestId('req-stable'))!;
    expect(after.items.single.name, 'Apple, with skin');
    expect(
      after.nutrientSum(NutrientKey.energyKcal).value,
      closeTo(before.nutrientSum(NutrientKey.energyKcal).value, 1e-9),
    );
    // The catalogue itself did change, which is the point of the separation.
    expect((await foods.findById('dev-apple'))!.name, 'Apple, corrected name');
  });

  test('deleting an entry cascades to its items', () async {
    final entry = (await handler.handle(
      LogFoodCommand(
        requestId: 'req-delete',
        foodId: 'dev-egg',
        quantity: PieceQuantity(2),
        offsetMinutes: 0,
      ),
    ) as LoggedFood)
        .entry;

    await entries.deleteEntry(entry.id);

    final itemCount = await db
        .customSelect('SELECT COUNT(*) AS c FROM log_entry_items')
        .getSingle();
    expect(itemCount.read<int>('c'), 0);
  });

  test('foreign key enforcement rejects an orphan item', () async {
    await expectLater(
      db.customStatement(
        "INSERT INTO log_entry_items (id, entry_id, name, grams, nutrients_json, position) "
        "VALUES ('orphan', 'nope', 'ghost', 1, '{}', 0)",
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('the development catalogue seeds once', () async {
    final seededAgain = await seedDevelopmentCatalogue(db);
    expect(seededAgain, 0);
    expect(await foods.search(''), isNotEmpty);
  });

  test('explicit recipe log time and date are durable idempotency inputs',
      () async {
    final food = developmentCatalogue().first;
    final recipe = RecipeVersion(
      id: 'timed-recipe', revision: 1, name: 'Timed meal',
      ingredients: [RecipeIngredient(food, Exact.parse('100'))],
      servings: Exact.one, minutes: 10,
    );
    final recipeHandler = LogRecipeHandler(entries,
        FixedClock(DateTime.utc(2026, 11, 8, 12)),
        SequentialIdGenerator(prefix: 'timed'));
    final stamp = EventStamp(instant: DateTime.utc(2026, 11, 7, 23),
        offsetMinutes: 60);
    LogRecipeCommand command({EventStamp? at, DiaryDate? date}) =>
        LogRecipeCommand(requestId: 'timed-request', recipe: recipe,
            portions: Exact.one, offsetMinutes: 60, confirmed: true,
            occurredAt: at ?? stamp,
            assignedDiaryDate: date ?? DiaryDate(2026, 11, 7));
    final first = await recipeHandler.handle(command());
    await entries.revise(ReviseEntryCommand(
        requestId: 'timed-correction', entryId: first.id,
        expectedRevision: 1, recordedAt: DateTime.utc(2026, 11, 8),
        multiplier: Exact.parse('2')));
    final replay = await recipeHandler.handle(command());
    expect(replay.id, first.id);
    expect(replay.revision, 2);
    await expectLater(
        recipeHandler.handle(command(at: EventStamp(
            instant: DateTime.utc(2026, 11, 7, 22), offsetMinutes: 60))),
        _stateError('REQUEST_ID_REUSED'));
    await expectLater(
        recipeHandler.handle(command(date: DiaryDate(2026, 11, 8))),
        _stateError('REQUEST_ID_REUSED'));
    await expectLater(
        recipeHandler.handle(LogRecipeCommand(
            requestId: 'timed-request', recipe: recipe, portions: Exact.one,
            offsetMinutes: 60, confirmed: true)),
        _stateError('REQUEST_ID_REUSED'));
    expect(await db.select(db.logEntries).get(), hasLength(1));
  });

  test('equal stored positions use the same item order for review and edit',
      () async {
    final entry = await _logTwoItemRecipe(entries);
    await db.customStatement(
        'UPDATE log_entry_items SET position = 0 WHERE entry_id = ?', [entry.id]);
    final before = (await entries.findByRequestId('recipe-log'))!;
    await entries.revise(ReviseEntryCommand(
        requestId: 'same-position-edit',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        itemIndex: 1,
        multiplier: Exact.parse('2')));
    final after = (await entries.findByRequestId('recipe-log'))!;
    expect(after.items[0].name, before.items[0].name);
    expect(after.items[0].quantity!.value, before.items[0].quantity!.value);
    expect(after.items[1].name, before.items[1].name);
    expect(after.items[1].quantity!.value,
        before.items[1].quantity!.value * Exact.parse('2'));
  });

  test('per-item correction scales exactly the chosen frozen item', () async {
    final entry = await _logTwoItemRecipe(entries);
    final before = (await entries.findByRequestId('recipe-log'))!;
    expect(before.items, hasLength(2));
    final otherBefore = before.items[1];
    final dayBefore = await LocalWorkspace(db).read('day', '2026-11-08');
    expect(dayBefore!.revision, 1);
    await LocalWorkspace(db).put(
        requestId: 'seed-checkin',
        collection: 'checkin',
        id: 'week',
        expectedRevision: 0,
        data: {'summary': 'before correction'});
    // A later catalogue edit must not influence the corrected snapshot.
    await foods.replaceCatalogueBatch([
      Food(
          id: 'dev-chicken-breast',
          name: 'Chicken, re-analysed',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(999)}),
          source: const FoodSource(dataset: 'changed', datasetId: 'changed')),
    ]);
    expect(
        (await foods.findById('dev-chicken-breast'))!.name,
        'Chicken, re-analysed');

    final command = ReviseEntryCommand(
        requestId: 'correct-item',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        itemIndex: 0,
        multiplier: Exact.parse('1.5'));
    expect(await entries.revise(command), 2);

    final corrected = (await entries.findByRequestId('recipe-log'))!;
    expect(corrected.revision, 2);
    expect(corrected.items[0].quantity!.value, Exact.parse('150'));
    expect(corrected.items[0].nutrients.toJson(),
        before.items[0].nutrients.scaledExact(Exact.parse('1.5')).toJson());
    expect(
        Exact.fromJson(Map<String, Object?>.from(
            corrected.items[0].sourceSnapshot!['allocationScale']! as Map)),
        Exact.parse('1.5'));
    expect(corrected.items[0].sourceSnapshot!['rawEdibleGrams'],
        before.items[0].sourceSnapshot!['rawEdibleGrams']);
    // The other frozen item keeps its amount, nutrients and provenance.
    expect(corrected.items[1].grams, otherBefore.grams);
    expect(corrected.items[1].quantity!.value, otherBefore.quantity!.value);
    expect(corrected.items[1].sourceSnapshot, otherBefore.sourceSnapshot);
    expect(
        corrected.items[1].nutrients.toJson(), otherBefore.nutrients.toJson());
    // The day rollup for the entry's date is invalidated for recalculation.
    final dayAfter = await LocalWorkspace(db).read('day', '2026-11-08');
    expect(dayAfter!.revision, 2);
    // Derived check-in results are discarded so they cannot outlive the input.
    expect(await LocalWorkspace(db).list('checkin'), isEmpty);

    // An identical retry resolves from the receipt without scaling twice.
    expect(await entries.revise(command), 2);
    expect((await entries.findByRequestId('recipe-log'))!.items[0]
        .quantity!.value, Exact.parse('150'));
    expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));

    // Reusing the request id for a different item or factor is refused.
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'correct-item',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 1,
            multiplier: Exact.parse('1.5'))),
        _stateError('REQUEST_ID_REUSED'));
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'stale-item',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 0,
            multiplier: Exact.parse('2'))),
        _stateError('STALE_ENTRY'));
    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'missing-item',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            itemIndex: 9,
            multiplier: Exact.parse('2'))),
        _stateError('ITEM_INDEX_OUT_OF_RANGE'));
    expect((await entries.findByRequestId('recipe-log'))!.revision, 2);
    expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));
    expect(
        await (db.select(db.appliedCommands)
              ..where((t) => t.requestId.equals('missing-item')))
            .getSingleOrNull(),
        isNull);
  });

  test('substitution replaces one frozen item and keeps the rest intact',
      () async {
    final entry = await _logTwoItemRecipe(entries);
    final before = (await entries.findByRequestId('recipe-log'))!;
    final otherBefore = before.items[1];
    final apple =
        developmentCatalogue().firstWhere((food) => food.id == 'dev-apple');
    final rice = developmentCatalogue()
        .firstWhere((food) => food.id == 'dev-rice-white');
    final dayBefore = await LocalWorkspace(db).read('day', '2026-11-08');
    await LocalWorkspace(db).put(
        requestId: 'seed-checkin',
        collection: 'checkin',
        id: 'week',
        expectedRevision: 0,
        data: {'summary': 'before substitution'});

    final command = SubstituteEntryItemCommand(
        requestId: 'substitute-item',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        itemIndex: 0,
        replacement: apple,
        amount: FoodAmount('120', FoodUnit.g));
    expect(await entries.substituteItem(command), 2);

    final substituted = (await entries.findByRequestId('recipe-log'))!;
    expect(substituted.revision, 2);
    // The entry itself keeps its consumed instant and diary assignment.
    expect(substituted.diaryDate, before.diaryDate);
    expect(substituted.stamp.instantUtc, before.stamp.instantUtc);
    expect(substituted.items[0].name, apple.name);
    expect(substituted.items[0].foodId, apple.id);
    expect(substituted.items[0].grams, 120);
    expect(substituted.items[0].quantity!.value, Exact.parse('120'));
    expect(substituted.items[0].quantity!.unit, FoodUnit.g);
    expect(substituted.items[0].nutrients.toJson(),
        apple.per100g.scaledExact(Exact.parse('1.2')).toJson());
    expect(substituted.items[0].sourceSnapshot!['dataset'],
        apple.source.dataset);
    expect(substituted.items[0].sourceSnapshot!['id'], apple.source.datasetId);
    expect(substituted.items[0].sourceSnapshot!['basisValue'], '100');
    // The other frozen item keeps its amount, nutrients and provenance.
    expect(substituted.items[1].name, otherBefore.name);
    expect(substituted.items[1].grams, otherBefore.grams);
    expect(substituted.items[1].quantity!.value, otherBefore.quantity!.value);
    expect(substituted.items[1].sourceSnapshot!, otherBefore.sourceSnapshot);
    expect(
        substituted.items[1].nutrients.toJson(), otherBefore.nutrients.toJson());

    // The pre-substitution revision is retained, not rewritten.
    final history = await LocalWorkspace(db).list('entry-revision');
    expect(history, hasLength(1));
    expect(history.single.id, '${entry.id}:1');
    final retained = Map<String, Object?>.from(
        (history.single.data['items']! as List).first as Map);
    expect(retained['name'], before.items[0].name);
    expect(history.single.data['itemIndex'], 0);
    expect(Map<String, Object?>.from(
        history.single.data['replacement']! as Map)['foodId'], apple.id);

    // The day rollup is invalidated and derived check-ins are discarded.
    final dayAfter = await LocalWorkspace(db).read('day', '2026-11-08');
    expect(dayAfter!.revision, dayBefore!.revision + 1);
    expect(await LocalWorkspace(db).list('checkin'), isEmpty);

    // A later catalogue edit cannot rewrite the frozen replacement.
    final changedApple = Food(
        id: 'dev-apple',
        name: 'Apple, re-analysed',
        per100g:
            NutrientProfile({NutrientKey.energyKcal: NutrientReported(999)}),
        source: const FoodSource(dataset: 'changed', datasetId: 'changed'));
    await foods.replaceCatalogueBatch([changedApple]);
    final frozen = (await entries.findByRequestId('recipe-log'))!;
    expect(frozen.items[0].name, apple.name);
    expect(frozen.items[0].nutrients.toJson(),
        apple.per100g.scaledExact(Exact.parse('1.2')).toJson());

    // An identical retry resolves from the receipt instead of writing again.
    expect(await entries.substituteItem(command), 2);
    expect((await entries.findByRequestId('recipe-log'))!.items[0].name,
        apple.name);
    expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));

    // The same request id and food id with a different reviewed snapshot is a
    // different payload: the frozen nutrients/source would change, so it is
    // refused instead of replayed silently.
    await expectLater(
        entries.substituteItem(SubstituteEntryItemCommand(
            requestId: 'substitute-item',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 0,
            replacement: changedApple,
            amount: FoodAmount('120', FoodUnit.g))),
        _stateError('REQUEST_ID_REUSED'));
    final stillFrozen = (await entries.findByRequestId('recipe-log'))!;
    expect(stillFrozen.items[0].name, apple.name);
    expect(stillFrozen.items[0].nutrients.toJson(),
        apple.per100g.scaledExact(Exact.parse('1.2')).toJson());
    expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));

    // Reusing the request id for another replacement is refused.
    await expectLater(
        entries.substituteItem(SubstituteEntryItemCommand(
            requestId: 'substitute-item',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 0,
            replacement: rice,
            amount: FoodAmount('120', FoodUnit.g))),
        _stateError('REQUEST_ID_REUSED'));
    // A stale review and a missing item write nothing.
    await expectLater(
        entries.substituteItem(SubstituteEntryItemCommand(
            requestId: 'stale-substitution',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 1,
            replacement: rice,
            amount: FoodAmount('50', FoodUnit.g))),
        _stateError('STALE_ENTRY'));
    await expectLater(
        entries.substituteItem(SubstituteEntryItemCommand(
            requestId: 'missing-item-substitution',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            itemIndex: 9,
            replacement: rice,
            amount: FoodAmount('50', FoodUnit.g))),
        _stateError('ITEM_INDEX_OUT_OF_RANGE'));
    // A unit the replacement food does not declare is refused, not guessed.
    await expectLater(
        entries.substituteItem(SubstituteEntryItemCommand(
            requestId: 'incompatible-substitution',
            entryId: entry.id,
            expectedRevision: 2,
            recordedAt: DateTime.utc(2026),
            itemIndex: 1,
            replacement: rice,
            amount: FoodAmount('50', FoodUnit.ml))),
        _stateError('INCOMPATIBLE_SUBSTITUTION_AMOUNT'));
    expect((await entries.findByRequestId('recipe-log'))!.revision, 2);
    expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));
    for (final requestId in [
      'stale-substitution',
      'missing-item-substitution',
      'incompatible-substitution'
    ]) {
      expect(
          await (db.select(db.appliedCommands)
                ..where((t) => t.requestId.equals(requestId)))
              .getSingleOrNull(),
          isNull);
    }
  });

  test('substitution freezes the reviewed food across a catalogue change',
      () async {
    final entry = await _logTwoItemRecipe(entries);
    final apple =
        developmentCatalogue().firstWhere((food) => food.id == 'dev-apple');
    final command = SubstituteEntryItemCommand(
        requestId: 'reviewed-snapshot',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        itemIndex: 0,
        replacement: apple,
        amount: FoodAmount('120', FoodUnit.g));
    // The catalogue row with the same id changes after review. The write must
    // freeze what the user reviewed rather than silently adopting this row.
    await foods.replaceCatalogueBatch([
      Food(
          id: 'dev-apple',
          name: 'Apple, re-analysed',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(999)}),
          source: const FoodSource(dataset: 'changed', datasetId: 'changed'))
    ]);

    expect(await entries.substituteItem(command), 2);
    final stored = (await entries.findByRequestId('recipe-log'))!;
    expect(stored.items[0].name, apple.name);
    expect(stored.items[0].nutrients.toJson(),
        apple.per100g.scaledExact(Exact.parse('1.2')).toJson());
    expect(stored.items[0].sourceSnapshot!['dataset'], apple.source.dataset);
    expect(stored.items[0].sourceSnapshot!['id'], apple.source.datasetId);
  });

  test('cooked-batch portions refuse substitution without touching stock',
      () async {
    final catalogue = {for (final f in developmentCatalogue()) f.id: f};
    final recipe = RecipeVersion(
        id: 'batch-recipe',
        revision: 1,
        name: 'Chicken and rice batch',
        ingredients: [
          RecipeIngredient(
              catalogue['dev-chicken-breast']!, Exact.parse('100')),
          RecipeIngredient(catalogue['dev-rice-white']!, Exact.parse('50')),
        ],
        servings: Exact.one,
        minutes: 10);
    final workspace = LocalWorkspace(db);
    await workspace.put(
        requestId: 'create-batch',
        collection: 'batch',
        id: 'batch',
        expectedRevision: 0,
        data: {
          'recipe': recipeSnapshot(recipe),
          'available': Exact.parse('600').toJson(),
          'finishedWeightG': Exact.parse('600').toJson(),
          'unit': 'g',
          'allocations': <Object?>[]
        });
    final service = BatchService(
        db,
        FixedClock(DateTime.utc(2026, 11, 8, 12, 30)),
        SequentialIdGenerator(prefix: 'batch'));
    final entry = await service.consumeAmount(
        requestId: 'batch-meal',
        batchId: 'batch',
        expectedRevision: 1,
        amount: Exact.parse('300'),
        unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    final before = (await entries.findByRequestId('batch-meal'))!;
    final batchBefore = (await workspace.read('batch', 'batch'))!;

    await expectLater(
        entries.substituteItem(SubstituteEntryItemCommand(
            requestId: 'batch-substitution',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 0,
            replacement: catalogue['dev-apple']!,
            amount: FoodAmount('100', FoodUnit.g))),
        _stateError('BATCH_ITEM_SUBSTITUTION_UNSUPPORTED'));

    final after = (await entries.findByRequestId('batch-meal'))!;
    expect(after.revision, 1);
    expect(
        after.items[0].nutrients.toJson(), before.items[0].nutrients.toJson());
    expect(
        after.items[1].nutrients.toJson(), before.items[1].nutrients.toJson());
    expect(after.items[0].name, before.items[0].name);
    final batchAfter = (await workspace.read('batch', 'batch'))!;
    expect(batchAfter.revision, batchBefore.revision);
    expect(batchAfter.data['allocations'], batchBefore.data['allocations']);
    expect(await workspace.list('entry-revision'), isEmpty);
    expect(
        await (db.select(db.appliedCommands)
              ..where((t) => t.requestId.equals('batch-substitution')))
            .getSingleOrNull(),
        isNull);
  });

  test('finite-batch multi-item entries reject per-item correction safely',
      () async {
    final catalogue = {for (final f in developmentCatalogue()) f.id: f};
    final recipe = RecipeVersion(
        id: 'batch-recipe',
        revision: 1,
        name: 'Chicken and rice batch',
        ingredients: [
          RecipeIngredient(
              catalogue['dev-chicken-breast']!, Exact.parse('100')),
          RecipeIngredient(catalogue['dev-rice-white']!, Exact.parse('50')),
        ],
        servings: Exact.one,
        minutes: 10);
    final workspace = LocalWorkspace(db);
    await workspace.put(
        requestId: 'create-batch',
        collection: 'batch',
        id: 'batch',
        expectedRevision: 0,
        data: {
          'recipe': recipeSnapshot(recipe),
          'available': Exact.parse('600').toJson(),
          'finishedWeightG': Exact.parse('600').toJson(),
          'unit': 'g',
          'allocations': <Object?>[]
        });
    final service = BatchService(
        db,
        FixedClock(DateTime.utc(2026, 11, 8, 12, 30)),
        SequentialIdGenerator(prefix: 'batch'));
    final entry = await service.consumeAmount(
        requestId: 'batch-meal',
        batchId: 'batch',
        expectedRevision: 1,
        amount: Exact.parse('300'),
        unit: FoodUnit.g,
        offsetMinutes: 0,
        confirmed: true);
    expect(entry.items, hasLength(2));
    final before = (await entries.findByRequestId('batch-meal'))!;
    final batchBefore = (await workspace.read('batch', 'batch'))!;

    await expectLater(
        entries.revise(ReviseEntryCommand(
            requestId: 'batch-item',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 0,
            multiplier: Exact.parse('1.5'))),
        _stateError('BATCH_ITEM_CORRECTION_UNSUPPORTED'));

    final after = (await entries.findByRequestId('batch-meal'))!;
    expect(after.revision, 1);
    expect(
        after.items[0].nutrients.toJson(), before.items[0].nutrients.toJson());
    expect(
        after.items[1].nutrients.toJson(), before.items[1].nutrients.toJson());
    final batchAfter = (await workspace.read('batch', 'batch'))!;
    expect(batchAfter.revision, batchBefore.revision);
    expect(batchAfter.data['allocations'], batchBefore.data['allocations']);
    expect(await workspace.list('entry-revision'), isEmpty);
    expect(
        await (db.select(db.appliedCommands)
              ..where((t) => t.requestId.equals('batch-item')))
            .getSingleOrNull(),
        isNull);

    // The whole-portion correction remains exact and updates the allocation in
    // the same transaction as the entry revision.
    expect(
        await entries.revise(ReviseEntryCommand(
            requestId: 'batch-whole',
            entryId: entry.id,
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            multiplier: Exact.parse('1.5'))),
        2);
    final corrected = (await entries.findByRequestId('batch-meal'))!;
    for (final item in corrected.items) {
      expect(
          Exact.fromJson(Map<String, Object?>.from(
              item.sourceSnapshot!['consumedBatchGrams']! as Map)),
          Exact.parse('450'));
    }
    final stock = (await workspace.read('batch', 'batch'))!;
    expect(stock.revision, 3);
    final allocation = (stock.data['allocations']! as List).single as Map;
    expect(
        Exact.fromJson(
            Map<String, Object?>.from(allocation['amount']! as Map)),
        Exact.parse('450'));
  });

  test('correction receipts written before item selection remain replayable',
      () async {
    final logged = await handler.handle(LogFoodCommand(
      requestId: 'legacy-log',
      foodId: 'dev-apple',
      quantity: MassQuantity(100),
      offsetMinutes: 0,
    )) as LoggedFood;
    final command = ReviseEntryCommand(
        requestId: 'legacy-correction',
        entryId: logged.entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        multiplier: Exact.parse('2'));
    expect(await entries.revise(command), 2);

    // Rewrite the stored receipt to the shape written before item selection
    // existed: the fingerprint has no `itemIndex` key.
    final stored = (await (db.select(db.appliedCommands)
              ..where((t) => t.requestId.equals('legacy-correction')))
            .getSingle())
        .resultJson;
    final result = Map<String, Object?>.from(jsonDecode(stored) as Map);
    final fingerprint = Map<String, Object?>.from(
        jsonDecode(result['fingerprint']! as String) as Map)
      ..remove('itemIndex');
    result['fingerprint'] = jsonEncode(fingerprint);
    await db.customStatement(
        'UPDATE applied_commands SET result_json = ? WHERE request_id = ?',
        [jsonEncode(result), 'legacy-correction']);

    expect(await entries.revise(command), 2);
    final corrected = (await entries.findByRequestId('legacy-log'))!;
    expect(corrected.revision, 2);
    // A replay never applies the exact multiplier a second time.
    expect(corrected.items.single.quantity!.value, Exact.parse('200'));
  });
}

Matcher _stateError(String message) => throwsA(
    isA<StateError>().having((error) => error.message, 'message', message));

Future<LoggedEntry> _logTwoItemRecipe(DriftEntryRepository entries) {
  final catalogue = {for (final f in developmentCatalogue()) f.id: f};
  final recipe = RecipeVersion(
      id: 'recipe-two',
      revision: 1,
      name: 'Chicken and rice',
      ingredients: [
        RecipeIngredient(catalogue['dev-chicken-breast']!, Exact.parse('100')),
        RecipeIngredient(catalogue['dev-rice-white']!, Exact.parse('50')),
      ],
      servings: Exact.one,
      minutes: 10);
  return LogRecipeHandler(
          entries,
          FixedClock(DateTime.utc(2026, 11, 8, 12, 30)),
          SequentialIdGenerator(prefix: 'recipe'))
      .handle(LogRecipeCommand(
          requestId: 'recipe-log',
          recipe: recipe,
          portions: Exact.one,
          offsetMinutes: 0,
          confirmed: true));
}
