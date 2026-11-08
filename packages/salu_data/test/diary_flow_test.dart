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
}
