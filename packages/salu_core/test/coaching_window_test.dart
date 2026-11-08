import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('window counts absent dates without inventing intake', () {
    final window =
        CoachingWindow(DiaryDate(2026, 1, 30), DiaryDate(2026, 2, 2));
    final result = const CoachingService().checkIn(
      const SafetyProfile(clinicalNeed: true),
      [
        const CoachingDay(
            date: '2026-01-30',
            revision: 3,
            completeness: DiaryCompleteness.userDeclaredComplete),
        const CoachingDay(
            date: '2026-02-01',
            revision: 4,
            completeness: DiaryCompleteness.confirmedNoIntake),
        const CoachingDay(
            date: '2026-02-02',
            revision: 5,
            completeness: DiaryCompleteness.partial),
      ],
      window: window,
    );
    expect(result.quality.expectedDays, 4);
    expect(result.quality.completeDays, 1);
    expect(result.quality.confirmedNoIntakeDays, 1);
    expect(result.quality.partialDays, 1);
    expect(result.quality.missingDates, ['2026-01-31']);
    expect(result.inputRevisions,
        {'2026-01-30': 3, '2026-02-01': 4, '2026-02-02': 5});
    expect(result.findings.first.action, CoachingAction.seekAdvice);
    expect(result.findings.last.action, CoachingAction.improveData);
    expect(result.findings.last.evidence,
        containsAll(['2026-01-31', '2026-02-02']));
    expect(result.adaptationStatus, 'disabled');
    expect(() => result.quality.missingDates.add('2026-02-03'),
        throwsUnsupportedError);
  });

  test(
      'invalid intervals, duplicate days and days outside the window are rejected',
      () {
    expect(() => CoachingWindow(DiaryDate(2026, 1, 2), DiaryDate(2026, 1, 1)),
        throwsArgumentError);
    final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 2));
    const day = CoachingDay(
        date: '2026-01-01',
        revision: 1,
        completeness: DiaryCompleteness.unknown);
    expect(
        () => const CoachingService()
            .checkIn(const SafetyProfile(), [day, day], window: window),
        throwsArgumentError);
    expect(
        () => const CoachingService().checkIn(
            const SafetyProfile(),
            [
              const CoachingDay(
                  date: '2026-01-03',
                  revision: 1,
                  completeness: DiaryCompleteness.partial)
            ],
            window: window),
        throwsArgumentError);
  });
}
