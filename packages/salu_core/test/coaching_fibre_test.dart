import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

LoggedEntry entry(String id, DiaryDate date, List<NutrientValue> values) {
  final time = DateTime.utc(2026, 1, 2, 12);
  return LoggedEntry(
      id: id,
      requestId: id,
      diaryDate: date,
      stamp: EventStamp(instant: time, offsetMinutes: 0),
      channel: EntryChannel.manual,
      recordedAt: time,
      revision: 2,
      items: [
        for (final value in values)
          LoggedItem(
              name: 'food',
              grams: 100,
              nutrients: NutrientProfile({NutrientKey.fiberG: value}))
      ]);
}

void main() {
  final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 7));
  test('coverage distinguishes zeros, estimates, traces, unknown and dates',
      () {
    final inside = entry('inside', DiaryDate(2026, 1, 2), [
      NutrientReported(0),
      NutrientEstimated(3, basis: 'user'),
      const NutrientTrace(),
      const NutrientUnknown()
    ]);
    final outside =
        entry('outside', DiaryDate(2026, 1, 8), [NutrientReported(9)]);
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window, entries: [inside, outside]);
    final coverage = result.fibreCoverage!;
    expect([
      coverage.reported,
      coverage.estimated,
      coverage.trace,
      coverage.unknown
    ], [
      1,
      1,
      1,
      1
    ]);
    expect(result.entryInputRevisions, {'inside': 2});
    expect(result.findings.single.action, CoachingAction.improveData);
    expect(result.adaptationStatus, 'disabled');
  });
  test('empty entries do not imply a zero fibre total', () {
    final result = const CoachingService()
        .checkIn(const SafetyProfile(), [], window: window);
    expect(result.fibreCoverage, isNull);
    expect(result.entryInputRevisions, isEmpty);
  });
  test('duplicate IDs and unbounded observations are rejected', () {
    final item = entry('same', DiaryDate(2026, 1, 1), [NutrientReported(2)]);
    expect(
        () => const CoachingService().checkIn(const SafetyProfile(), [],
            window: window, entries: [item, item]),
        throwsArgumentError);
    expect(
        () => const CoachingService()
            .checkIn(const SafetyProfile(), [], entries: [item]),
        throwsArgumentError);
  });
}
