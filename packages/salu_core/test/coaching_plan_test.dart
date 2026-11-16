import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

LoggedEntry entry(
    String id, DiaryDate date, EntryChannel channel, int revision) {
  final time = DateTime.utc(2026, 1, 10, 12);
  return LoggedEntry(
      id: id,
      requestId: id,
      diaryDate: date,
      stamp: EventStamp(instant: time, offsetMinutes: 0),
      channel: channel,
      recordedAt: time,
      revision: revision,
      items: [
        LoggedItem(
            name: 'food',
            grams: 100,
            nutrients: const NutrientProfile.empty())
      ]);
}

CoachingFinding findingFor(CheckInResult result, String ruleId) =>
    result.findings.singleWhere((finding) => finding.ruleId == ruleId);

void main() {
  final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 3));

  test('date-level plan records below the slot count ask for better data', () {
    final result = const CoachingService().checkIn(
        const SafetyProfile(),
        [
          const CoachingDay(
              date: '2026-01-01',
              revision: 1,
              completeness: DiaryCompleteness.userDeclaredComplete),
          const CoachingDay(
              date: '2026-01-02',
              revision: 1,
              completeness: DiaryCompleteness.userDeclaredComplete),
          const CoachingDay(
              date: '2026-01-03',
              revision: 1,
              completeness: DiaryCompleteness.confirmedNoIntake),
        ],
        window: window,
        plannedSlots: [
          CoachingPlanSlot(
              slotId: 'dinner:0', date: '2026-01-01', revision: 4),
          CoachingPlanSlot(
              slotId: 'dinner:1', date: '2026-01-02', revision: 5),
        ],
        entries: [
          entry('plan-1', DiaryDate(2026, 1, 1), EntryChannel.plan, 2),
          entry('manual-1', DiaryDate(2026, 1, 2), EntryChannel.manual, 3),
        ]);
    final finding = findingFor(result, 'plan-recording-gaps');
    expect(finding.action, CoachingAction.improveData);
    expect(finding.window.bounded, isTrue);
    expect(finding.window.start, window.start);
    expect(finding.window.end, window.end);
    expect(finding.evaluatedDates,
        unorderedEquals(['2026-01-01', '2026-01-02']));
    expect(finding.inputRevisions, {
      'plan:dinner:0': 4,
      'plan:dinner:1': 5,
      'entry:plan-1': 2,
    });
    expect(finding.message, contains('2 meal slot(s)'));
    expect(finding.message, contains('1 separate plan-origin'));
    expect(finding.caveats, contains(CoachingCaveat.planNotIntake));
    expect(finding.caveats, contains(CoachingCaveat.planDateLevelOnly));
    expect(finding.caveats, contains(CoachingCaveat.unrecordedUnknown));
    expect(finding.evidence, contains('plan slot dinner:1 on 2026-01-02 '
        '(revision 5)'));
    expect(result.planInputRevisions, {'dinner:0': 4, 'dinner:1': 5});
    expect(result.entryInputRevisions, {'plan-1': 2, 'manual-1': 3});
  });

  test('enough separate plan-origin records hold without claiming adherence',
      () {
    final result = const CoachingService().checkIn(
        const SafetyProfile(),
        [
          const CoachingDay(
              date: '2026-01-01',
              revision: 1,
              completeness: DiaryCompleteness.userDeclaredComplete),
        ],
        window: window,
        plannedSlots: [
          CoachingPlanSlot(
              slotId: 'lunch:0', date: '2026-01-01', revision: 1),
        ],
        entries: [
          entry('plan-a', DiaryDate(2026, 1, 1), EntryChannel.plan, 1),
          entry('plan-b', DiaryDate(2026, 1, 1), EntryChannel.plan, 1),
        ]);
    final finding = findingFor(result, 'plan-recording');
    expect(finding.action, CoachingAction.hold);
    expect(finding.message, contains('2 separate plan-origin'));
    expect(finding.caveats, contains(CoachingCaveat.unrecordedUnknown));
    expect(finding.message, isNot(contains('adherence')));
  });

  test('manual, imported and natural-language entries do not count as plan',
      () {
    final result = const CoachingService().checkIn(
        const SafetyProfile(), [], window: window,
        plannedSlots: [
          CoachingPlanSlot(
              slotId: 'breakfast:0', date: '2026-01-01', revision: 1),
        ],
        entries: [
          entry('manual', DiaryDate(2026, 1, 1), EntryChannel.manual, 1),
          entry('imported', DiaryDate(2026, 1, 1), EntryChannel.imported, 1),
          entry('language', DiaryDate(2026, 1, 1),
              EntryChannel.naturalLanguage, 1),
        ]);
    final finding = findingFor(result, 'plan-recording-gaps');
    expect(finding.message, contains('0 separate plan-origin'));
    expect(result.entryInputRevisions,
        equals({'manual': 1, 'imported': 1, 'language': 1}));
  });

  test('a plan-origin entry outside the window cannot fill a slot', () {
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window,
        plannedSlots: [
          CoachingPlanSlot(slotId: 's', date: '2026-01-01', revision: 1),
        ],
        entries: [
          entry('outside', DiaryDate(2026, 1, 8), EntryChannel.plan, 1),
        ]);
    final finding = findingFor(result, 'plan-recording-gaps');
    expect(finding.message, contains('0 separate plan-origin'));
  });

  test('backdated plan entry uses its recorded diary date and revision', () {
    final backdated = LoggedEntry(
        id: 'backdated',
        requestId: 'backdated',
        diaryDate: DiaryDate(2026, 1, 2),
        stamp: EventStamp(
            instant: DateTime.utc(2025, 11, 1, 12), offsetMinutes: 0),
        channel: EntryChannel.plan,
        recordedAt: DateTime.utc(2026, 1, 3, 9),
        revision: 6,
        items: const [
          LoggedItem(
              name: 'food',
              grams: 100,
              nutrients: NutrientProfile.empty())
        ]);
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window,
        plannedSlots: [
          CoachingPlanSlot(slotId: 's', date: '2026-01-02', revision: 1),
        ],
        entries: [backdated]);
    final finding = findingFor(result, 'plan-recording');
    expect(finding.inputRevisions, {'plan:s': 1, 'entry:backdated': 6});
    expect(finding.evidence,
        contains('plan-origin entry backdated on 2026-01-02 (revision 6)'));
  });

  test('plan inputs require a bounded window and valid unique slots', () {
    const service = CoachingService();
    final slot =
        CoachingPlanSlot(slotId: 's', date: '2026-01-01', revision: 1);
    expect(
        () => service.checkIn(const SafetyProfile(), [], plannedSlots: [slot]),
        throwsArgumentError);
    expect(
        () => service.checkIn(const SafetyProfile(), [],
            window: window, plannedSlots: [slot, slot]),
        throwsArgumentError);
    expect(
        () => service.checkIn(const SafetyProfile(), [],
            window: window,
            plannedSlots: [
              CoachingPlanSlot(
                  slotId: 'outside', date: '2026-01-04', revision: 1)
            ]),
        throwsArgumentError);
    expect(
        () => CoachingPlanSlot(
            slotId: 'bad', date: '2026-02-30', revision: 1),
        throwsArgumentError);
    expect(
        () => CoachingPlanSlot(
            slotId: 'bad', date: '2026-1-1', revision: 1),
        throwsArgumentError);
    expect(
        () => CoachingPlanSlot(slotId: '', date: '2026-01-01', revision: 1),
        throwsArgumentError);
    expect(
        () => CoachingPlanSlot(slotId: 's', date: '2026-01-01', revision: 0),
        throwsArgumentError);
  });

  test('no plan slots means no plan finding and no plan revisions', () {
    final result =
        const CoachingService().checkIn(const SafetyProfile(), [], window: window);
    expect(result.findings.any((f) => f.ruleId.startsWith('plan-')), isFalse);
    expect(result.planInputRevisions, isEmpty);
  });
}
