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
    expect(result.findings.first.ruleId, 'safety-route');
    expect(result.findings.first.window.bounded, isTrue);
    expect(result.findings.first.window.start, window.start);
    expect(result.findings.first.window.end, window.end);
    expect(result.findings.first.message, contains('CLINICAL_NUTRITION'));
    expect(result.findings.last.action, CoachingAction.improveData);
    expect(result.findings.last.ruleId, 'record-coverage');
    expect(result.findings.last.window.bounded, isTrue);
    expect(result.findings.last.window.start, window.start);
    expect(result.findings.last.window.end, window.end);
    expect(result.findings.last.evidence,
        containsAll(['2026-01-31', '2026-02-02']));
    expect(result.findings.last.caveats,
        contains(CoachingCaveat.declarationsNotAdequacy));
    expect(result.findings.last.caveats,
        contains(CoachingCaveat.unrecordedUnknown));
    expect(result.findings.last.dataQuality, same(result.quality));
    expect(result.findings.last.inputRevisions,
        {'day:2026-01-30': 3, 'day:2026-02-01': 4, 'day:2026-02-02': 5});
    expect(result.findings.last.message, contains('2 day(s)'));
    expect(result.findings.last.message, isNot(contains('{')));
    expect(result.primaryFinding, same(result.findings.first));
    expect(result.coachingRulesVersion, 'coaching-rules-v5');
    expect(() => result.quality.missingDates.add('2026-02-03'),
        throwsUnsupportedError);
  });

  test('complete declarations produce a neutral hold-course finding', () {
    final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 2));
    final result = const CoachingService().checkIn(
        const SafetyProfile(),
        [
          const CoachingDay(
              date: '2026-01-01',
              revision: 1,
              completeness: DiaryCompleteness.userDeclaredComplete),
          const CoachingDay(
              date: '2026-01-02',
              revision: 2,
              completeness: DiaryCompleteness.confirmedNoIntake),
        ],
        window: window);
    expect(result.findings.single.ruleId, 'hold-course');
    expect(result.findings.single.action, CoachingAction.hold);
    expect(result.findings.single.evaluatedDates, window.dates);
    expect(result.findings.single.caveats,
        isNot(contains(CoachingCaveat.unrecordedUnknown)));
    expect(result.findings.single.message, contains('2 considered day(s)'));
  });

  test('without a window the evaluated day declarations are explicit', () {
    final result = const CoachingService().checkIn(
        const SafetyProfile(),
        [
          const CoachingDay(
              date: '2026-01-01',
              revision: 7,
              completeness: DiaryCompleteness.unknown)
        ]);
    final finding = result.findings.single;
    expect(finding.window.bounded, isFalse);
    expect(finding.window.start, isNull);
    expect(finding.evaluatedDates, ['2026-01-01']);
    expect(finding.inputRevisions, {'day:2026-01-01': 7});
    expect(finding.evidence, contains('2026-01-01'));
    expect(finding.evidence.any((line) => line.contains('unknown')), isTrue);
    expect(result.quality.expectedDays, 1);
  });

  test('an empty check-in still states its evidence and empty scope', () {
    final result =
        const CoachingService().checkIn(const SafetyProfile(), []);
    final finding = result.findings.single;
    expect(finding.ruleId, 'record-coverage');
    expect(finding.evaluatedDates, isEmpty);
    expect(finding.window.bounded, isFalse);
    expect(finding.window.start, isNull);
    expect(finding.evidence,
        ['No day declarations were supplied for this check-in.']);
    expect(finding.message, contains('none supplied'));
  });

  test(
      'invalid intervals, duplicate days and days outside the window are rejected',
      () {
    expect(() => CoachingWindow(DiaryDate(2026, 1, 2), DiaryDate(2026, 1, 1)),
        throwsArgumentError);
    expect(() => CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2027, 1, 2)),
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
    expect(
        () => const CoachingService().checkIn(
            const SafetyProfile(),
            [
              const CoachingDay(
                  date: '2026-01-01',
                  revision: -1,
                  completeness: DiaryCompleteness.partial)
            ],
            window: window),
        throwsArgumentError);
  });
}
