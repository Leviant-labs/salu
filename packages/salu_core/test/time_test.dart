import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  group('DiaryDate.assign', () {
    test('uses the recording offset, not UTC', () {
      // 23:30 UTC is already the next day in WET+1 during summer time.
      final stamp = EventStamp(
        instant: DateTime.utc(2026, 8, 14, 23, 30),
        offsetMinutes: 60,
      );
      expect(DiaryDate.assign(stamp), DiaryDate(2026, 8, 15));

      final sameInstantInUtc = EventStamp(
        instant: DateTime.utc(2026, 8, 14, 23, 30),
        offsetMinutes: 0,
      );
      expect(DiaryDate.assign(sameInstantInUtc), DiaryDate(2026, 8, 14));
    });

    test('a day boundary hour pushes the small hours to the previous day', () {
      final stamp = EventStamp(
        instant: DateTime.utc(2026, 11, 8, 2, 15),
        offsetMinutes: 0,
      );
      expect(DiaryDate.assign(stamp, dayStartHour: 0), DiaryDate(2026, 11, 8));
      expect(DiaryDate.assign(stamp, dayStartHour: 4), DiaryDate(2026, 11, 7));
    });

    test('west-of-UTC offsets can land on the previous UTC date', () {
      final stamp = EventStamp(
        instant: DateTime.utc(2026, 1, 1, 2, 0),
        offsetMinutes: -180,
      );
      expect(DiaryDate.assign(stamp), DiaryDate(2025, 12, 31));
    });

    test('rejects an out-of-range day start', () {
      final stamp =
          EventStamp(instant: DateTime.utc(2026, 1, 1), offsetMinutes: 0);
      expect(
          () => DiaryDate.assign(stamp, dayStartHour: 24), throwsArgumentError);
      expect(
          () => DiaryDate.assign(stamp, dayStartHour: -1), throwsArgumentError);
    });
  });

  group('DiaryDate value semantics', () {
    test('parses and formats the stored form', () {
      final date = DiaryDate.parse('2026-11-08');
      expect(date, DiaryDate(2026, 11, 8));
      expect(date.toIso(), '2026-11-08');
    });

    test('addDays crosses month and year boundaries', () {
      expect(DiaryDate(2026, 12, 31).addDays(1), DiaryDate(2027, 1, 1));
      expect(DiaryDate(2026, 3, 1).addDays(-1), DiaryDate(2026, 2, 28));
      expect(DiaryDate(2024, 2, 28).addDays(1), DiaryDate(2024, 2, 29));
    });

    test('orders chronologically', () {
      final dates = [
        DiaryDate(2026, 11, 8),
        DiaryDate(2026, 1, 2),
        DiaryDate(2025, 12, 31),
      ];
      dates.sort();
      expect(dates.first, DiaryDate(2025, 12, 31));
      expect(dates.last, DiaryDate(2026, 11, 8));
    });

    test('rejects impossible dates', () {
      expect(() => DiaryDate(2026, 2, 30), throwsArgumentError);
      expect(() => DiaryDate(2026, 13, 1), throwsArgumentError);
      expect(() => DiaryDate.parse('2026-11'), throwsFormatException);
    });
  });

  test('EventStamp normalises instants to UTC and keeps the offset', () {
    final stamp = EventStamp(
      instant: DateTime.utc(2026, 11, 8, 12).toLocal(),
      offsetMinutes: 0,
    );
    expect(stamp.instantUtc.isUtc, isTrue);
    expect(stamp.instantUtc, DateTime.utc(2026, 11, 8, 12));
    expect(stamp.offsetMinutes, 0);
  });
}
