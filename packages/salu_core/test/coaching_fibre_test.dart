import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

LoggedEntry entry(
    String id, DiaryDate date, List<NutrientValue> values, int revision) {
  final time = DateTime.utc(2026, 1, 2, 12);
  return LoggedEntry(
      id: id,
      requestId: id,
      diaryDate: date,
      stamp: EventStamp(instant: time, offsetMinutes: 0),
      channel: EntryChannel.manual,
      recordedAt: time,
      revision: revision,
      items: [
        for (final value in values)
          LoggedItem(
              name: 'food',
              grams: 100,
              nutrients: NutrientProfile({NutrientKey.fiberG: value}))
      ]);
}

CoachingFinding findingFor(CheckInResult result, String ruleId) =>
    result.findings.singleWhere((finding) => finding.ruleId == ruleId);

void main() {
  final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 7));
  test('coverage distinguishes zeros, estimates, traces, unknown and dates',
      () {
    final inside = entry('inside', DiaryDate(2026, 1, 2), [
      NutrientReported(0),
      NutrientEstimated(3, basis: 'user'),
      const NutrientTrace(),
      const NutrientUnknown()
    ], 2);
    final outside = entry(
        'outside', DiaryDate(2026, 1, 8), [NutrientReported(9)], 2);
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window, entries: [inside, outside]);
    final coverage = result.fibreCoverage!;
    expect([
      coverage.reported,
      coverage.estimated,
      coverage.trace,
      coverage.unknown,
      coverage.known,
      coverage.total
    ], [1, 1, 1, 1, 2, 4]);
    expect(result.entryInputRevisions, {'inside': 2});

    final finding = findingFor(result, 'fibre-coverage-gaps');
    expect(finding.action, CoachingAction.improveData);
    expect(finding.window.bounded, isTrue);
    expect(finding.window.start, window.start);
    expect(finding.window.end, window.end);
    expect(finding.evaluatedDates, ['2026-01-02']);
    expect(finding.inputRevisions, {'entry:inside': 2});
    expect(finding.caveats,
        contains(CoachingCaveat.fibreCoverageNotAdequacy));
    expect(finding.caveats, contains(CoachingCaveat.unrecordedUnknown));
    expect(finding.caveats, contains(CoachingCaveat.backdatedPreserved));
    expect(finding.message, contains('1 of 4'));
    expect(finding.message, isNot(contains('{')));
    expect(finding.limitations, isNotEmpty);
    expect(finding.dataQuality, same(result.quality));
  });

  test('fully explicit fibre states hold instead of asking for data', () {
    final inside = entry('inside', DiaryDate(2026, 1, 2), [
      NutrientReported(2),
      NutrientReported(1),
      NutrientEstimated(3, basis: 'label'),
      const NutrientTrace()
    ], 4);
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
        window: window,
        entries: [inside]);
    final finding = findingFor(result, 'fibre-coverage');
    expect(finding.action, CoachingAction.hold);
    expect(finding.message, contains('2 reported'));
    expect(finding.caveats, contains(CoachingCaveat.unrecordedUnknown));
  });

  test('measured fibre counts as reported numeric coverage', () {
    final measured =
        entry('measured', DiaryDate(2026, 1, 2), [NutrientMeasured(2.5)], 1);
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window, entries: [measured]);
    expect(result.fibreCoverage!.reported, 1);
    expect(result.fibreCoverage!.unknown, 0);
    final finding = findingFor(result, 'fibre-coverage');
    expect(finding.action, CoachingAction.hold);
    expect(finding.message, contains('1 reported'));
  });

  test('empty entries do not imply a zero fibre total', () {
    final result = const CoachingService()
        .checkIn(const SafetyProfile(), [], window: window);
    expect(result.fibreCoverage, isNull);
    expect(result.entryInputRevisions, isEmpty);
    expect(result.findings.any((f) => f.ruleId.startsWith('fibre-')), isFalse);
  });

  test('duplicate IDs and unbounded observations are rejected', () {
    final item = entry('same', DiaryDate(2026, 1, 1), [NutrientReported(2)], 1);
    expect(
        () => const CoachingService().checkIn(const SafetyProfile(), [],
            window: window, entries: [item, item]),
        throwsArgumentError);
    expect(
        () => const CoachingService()
            .checkIn(const SafetyProfile(), [], entries: [item]),
        throwsArgumentError);
    expect(
        () => const CoachingService().checkIn(const SafetyProfile(), [],
            window: window,
            entries: [
              entry('bad', DiaryDate(2026, 1, 1), [NutrientReported(2)], 0)
            ]),
        throwsArgumentError);
  });

  test('entry diary date, not recording stamp, selects the window', () {
    final backdated = LoggedEntry(
        id: 'backdated',
        requestId: 'backdated',
        diaryDate: DiaryDate(2026, 1, 6),
        stamp: EventStamp(
            instant: DateTime.utc(2025, 12, 1, 12), offsetMinutes: 0),
        channel: EntryChannel.manual,
        recordedAt: DateTime.utc(2026, 1, 7, 9),
        revision: 3,
        items: [
          LoggedItem(
              name: 'food',
              grams: 50,
              nutrients: NutrientProfile(
                  {NutrientKey.fiberG: const NutrientUnknown()}))
        ]);
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window, entries: [backdated]);
    expect(result.entryInputRevisions, {'backdated': 3});
    expect(findingFor(result, 'fibre-coverage-gaps').evaluatedDates,
        ['2026-01-06']);
  });
}
