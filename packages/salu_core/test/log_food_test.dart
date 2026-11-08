import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late FakeFoodRepository foods;
  late FakeEntryRepository entries;
  late LogFoodHandler handler;

  setUp(() {
    foods = FakeFoodRepository([chickenBreast(), milk()]);
    entries = FakeEntryRepository();
    handler = LogFoodHandler(
      foods: foods,
      entries: entries,
      clock: FixedClock(DateTime.utc(2026, 11, 8, 12, 30)),
      ids: SequentialIdGenerator(prefix: 'entry'),
    );
  });

  LogFoodCommand command({
    String requestId = 'req-1',
    String foodId = 'food-chicken',
    Quantity? quantity,
    int offsetMinutes = 0,
    DateTime? eatenAt,
  }) =>
      LogFoodCommand(
        requestId: requestId,
        foodId: foodId,
        quantity: quantity ?? MassQuantity(120),
        offsetMinutes: offsetMinutes,
        eatenAt: eatenAt,
      );

  test('applies a mass log and snapshots nutrients for the eaten amount',
      () async {
    final result = await handler.handle(command());

    expect(result, isA<LoggedFood>());
    final applied = result as LoggedFood;
    expect(applied.created, isTrue);
    expect(entries.written, hasLength(1));

    final entry = applied.entry;
    expect(entry.items.single.grams, 120);
    // 165 kcal/100 g at 120 g, measured -> measured.
    expect(
      entry.nutrientSum(NutrientKey.energyKcal).value,
      closeTo(198, 1e-9),
    );
    expect(entry.nutrientSum(NutrientKey.energyKcal).isComplete, isTrue);
    // Fiber was unknown in the source: the total must not claim a number.
    expect(entry.nutrientSum(NutrientKey.fiberG).isComplete, isFalse);
  });

  test('retrying the same request does not duplicate the entry', () async {
    final first = await handler.handle(command()) as LoggedFood;
    final second = await handler.handle(command()) as LoggedFood;

    expect(second.created, isFalse);
    expect(second.entry.id, first.entry.id);
    expect(entries.written, hasLength(1));
  });

  test('a different request for the same food is a separate entry', () async {
    await handler.handle(command(requestId: 'breakfast'));
    await handler.handle(command(requestId: 'lunch'));

    expect(entries.written, hasLength(2));
  });

  test('unknown food is rejected and writes nothing', () async {
    final result = await handler.handle(command(foodId: 'missing'));

    expect(result, isA<LogFoodRejected>());
    expect((result as LogFoodRejected).reason, LogFoodRejection.unknownFood);
    expect(entries.written, isEmpty);
  });

  test('volume without density is rejected with a recoverable message',
      () async {
    final result = await handler.handle(
      command(foodId: 'food-chicken', quantity: VolumeQuantity(200)),
    );

    expect(result, isA<LogFoodRejected>());
    final rejected = result as LogFoodRejected;
    expect(rejected.reason, LogFoodRejection.unresolvableQuantity);
    expect(rejected.message, contains('mass'));
    expect(entries.written, isEmpty);
  });

  test('diary date follows the eating offset, not UTC midnight', () async {
    final result = await handler.handle(
      command(
        eatenAt: DateTime.utc(2026, 11, 8, 23, 40),
        offsetMinutes: 60,
      ),
    ) as LoggedFood;

    expect(result.entry.diaryDate, DiaryDate(2026, 11, 9));
    expect(result.entry.stamp.offsetMinutes, 60);
  });

  test('piece logging uses the declared portion weight', () async {
    final result = await handler.handle(
      command(quantity: PieceQuantity(2)),
    ) as LoggedFood;

    expect(result.entry.items.single.grams, 240);
  });

  test('an empty request id is a programming error', () {
    expect(
      () => LogFoodCommand(
        requestId: ' ',
        foodId: 'food-chicken',
        quantity: MassQuantity(10),
        offsetMinutes: 0,
      ),
      throwsArgumentError,
    );
  });
}
