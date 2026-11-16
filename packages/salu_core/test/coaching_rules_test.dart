import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

LoggedEntry entry(
    String id,
    DiaryDate date,
    EntryChannel channel,
    int revision, {
    NutrientValue? fibre,
  }) {
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
            nutrients: fibre == null
                ? const NutrientProfile.empty()
                : NutrientProfile({NutrientKey.fiberG: fibre}))
      ]);
}

CoachingFinding findingFor(CheckInResult result, String ruleId) =>
    result.findings.singleWhere((finding) => finding.ruleId == ruleId);

CheckInResult richCheckIn() {
  final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 7));
  return const CoachingService().checkIn(
      const SafetyProfile(clinicalNeed: true, symptoms: true),
      [
        const CoachingDay(
            date: '2026-01-01',
            revision: 7,
            completeness: DiaryCompleteness.userDeclaredComplete),
        const CoachingDay(
            date: '2026-01-02',
            revision: 8,
            completeness: DiaryCompleteness.partial),
        const CoachingDay(
            date: '2026-01-03',
            revision: 9,
            completeness: DiaryCompleteness.unknown),
      ],
      window: window,
      weights: [
        CoachingWeight(
            id: 'w1',
            revision: 2,
            stamp: EventStamp(
                instant: DateTime.utc(2026, 1, 1, 9), offsetMinutes: 0),
            kilograms: Exact.parse('70')),
        CoachingWeight(
            id: 'w2',
            revision: 3,
            stamp: EventStamp(
                instant: DateTime.utc(2026, 1, 6, 9), offsetMinutes: 0),
            kilograms: Exact.parse('69.5')),
      ],
      entries: [
        entry('plan-1', DiaryDate(2026, 1, 1), EntryChannel.plan, 3,
            fibre: const NutrientUnknown()),
        entry('manual-1', DiaryDate(2026, 1, 2), EntryChannel.manual, 4,
            fibre: NutrientReported(2)),
        entry('outside', DiaryDate(2026, 1, 8), EntryChannel.manual, 1,
            fibre: NutrientReported(9)),
      ],
      plannedSlots: [
        CoachingPlanSlot(slotId: 'dinner:0', date: '2026-01-01', revision: 5),
        CoachingPlanSlot(slotId: 'dinner:1', date: '2026-01-02', revision: 6),
      ]);
}

void main() {
  test('rule library is versioned, unique and deterministic', () {
    expect(CoachingRuleLibrary.version, 'coaching-rules-v5');
    final ids = CoachingRuleLibrary.all.map((rule) => rule.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final rule in CoachingRuleLibrary.all) {
      expect(rule.version, isNotEmpty);
      expect(rule.ruleIdentity, '${rule.id}@${rule.version}');
      expect(rule.priority, greaterThanOrEqualTo(0));
      expect(rule.applicablePopulation, isNotEmpty);
      expect(rule.limitations, isNotEmpty);
      expect(rule.requiredInputs, isNotEmpty);
      expect(rule.caveats, isNotEmpty);
      expect(rule.action,
          isNot(anyOf(CoachingAction.discussTarget, CoachingAction.editPlan)));
    }
    expect(CoachingRuleLibrary.safetyRoute.priority, 0);
    final priorities = [
      for (final rule in CoachingRuleLibrary.all) rule.priority
    ];
    expect(priorities, orderedEquals(priorities.toList()..sort()));
  });

  test('templates render explicitly and refuse missing values', () {
    expect(
        CoachingRuleLibrary.recordCoverage
            .render({'count': 2, 'dates': '2026-01-01, 2026-01-02'}),
        contains('2 day(s)'));
    expect(() => CoachingRuleLibrary.recordCoverage.render({'count': 2}),
        throwsArgumentError);
    expect(
        () => CoachingRuleLibrary.holdCourse
            .render({'count': 1, 'unused': 'x'}),
        returnsNormally);
  });

  test('rich check-in carries scope, evidence, caveats and revisions', () {
    final result = richCheckIn();
    expect(result.findings, isNotEmpty);
    expect(result.primaryFinding, same(result.findings.first));
    expect(result.primaryFinding.ruleId, 'safety-route');
    expect(result.coachingRulesVersion, CoachingRuleLibrary.version);
    expect(result.safety.recordingAllowed, isTrue);
    expect(result.safety.reasonCodes,
        containsAll(['CLINICAL_NUTRITION', 'SYMPTOMS_REVIEW']));

    final ids = result.findings.map((finding) => finding.ruleId).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids, [
      'safety-route',
      'record-coverage',
      'weight-readings',
      'fibre-coverage-gaps',
      'plan-recording-gaps',
    ]);
    final priorities = [
      for (final finding in result.findings) finding.priority
    ];
    expect(priorities, orderedEquals(priorities.toList()..sort()));

    for (final finding in result.findings) {
      expect(finding.rule, isA<CoachingRule>());
      expect(finding.ruleVersion, '1');
      expect(finding.ruleIdentity, '${finding.ruleId}@1');
      expect(finding.rulesVersion, CoachingRuleLibrary.version);
      expect(finding.applicablePopulation, isNotEmpty);
      expect(finding.evidence, isNotEmpty);
      expect(finding.limitations, isNotEmpty);
      expect(finding.caveats, isNotEmpty);
      expect(finding.caveats, contains(CoachingCaveat.unrecordedUnknown));
      expect(finding.window.bounded, isTrue);
      expect(finding.window.start, result.window!.start);
      expect(finding.window.end, result.window!.end);
      expect(finding.evaluatedDates, isNotEmpty);
      expect(finding.inputRevisions, isNotEmpty);
      expect(finding.dataQuality, same(result.quality));
      expect(finding.message, isNotEmpty);
      expect(finding.message, isNot(contains('{')));
      expect(finding.message, isNot(contains('}')));
      expect(finding.action,
          isNot(anyOf(CoachingAction.discussTarget, CoachingAction.editPlan)));
    }

    expect(findingFor(result, 'record-coverage').inputRevisions,
        {'day:2026-01-01': 7, 'day:2026-01-02': 8, 'day:2026-01-03': 9});
    expect(findingFor(result, 'weight-readings').inputRevisions,
        {'weight:w1': 2, 'weight:w2': 3});
    expect(findingFor(result, 'fibre-coverage-gaps').inputRevisions,
        {'entry:plan-1': 3, 'entry:manual-1': 4});
    expect(findingFor(result, 'plan-recording-gaps').inputRevisions, {
      'plan:dinner:0': 5,
      'plan:dinner:1': 6,
      'entry:plan-1': 3,
    });
    expect(result.inputRevisions,
        {'2026-01-01': 7, '2026-01-02': 8, '2026-01-03': 9});
    expect(result.weightInputRevisions, {'w1': 2, 'w2': 3});
    expect(result.entryInputRevisions,
        {'plan-1': 3, 'manual-1': 4});
    expect(result.planInputRevisions,
        {'dinner:0': 5, 'dinner:1': 6});
    expect(result.fibreCoverage!.unknown, 1);
    expect(result.weightObservation!.changeKg, Exact.parse('-0.5'));
  });

  test('unavailable checks state the missing evidence', () {
    final result = richCheckIn();
    final ids = result.unavailableChecks.map((check) => check.id).toList();
    expect(ids, containsAll([
      'weight-trend',
      'possible-progress-plateau',
      'nutrient-adequacy',
      'plan-adherence',
      'notification-cooldown',
    ]));
    expect(ids, isNot(contains('target-adjustment')));
    for (final check in result.unavailableChecks) {
      expect(check.reason, isNotEmpty);
    }
    expect(result.findings.any((finding) => finding.ruleId.contains('plateau')),
        isFalse);
    expect(result.findings.any((finding) => finding.ruleId == 'weight-trend'),
        isFalse);
  });

  test('findings and result collections are immutable', () {
    final result = richCheckIn();
    final finding = result.primaryFinding;
    expect(() => result.findings.add(finding), throwsUnsupportedError);
    expect(() => finding.evidence.add('extra'), throwsUnsupportedError);
    expect(() => finding.evaluatedDates.add('2026-01-07'),
        throwsUnsupportedError);
    expect(() => finding.caveats.add(CoachingCaveat.unrecordedUnknown),
        throwsUnsupportedError);
    expect(() => finding.actionPayload['extra'] = 1, throwsUnsupportedError);
    expect(() => finding.inputRevisions['x'] = 1, throwsUnsupportedError);
    expect(() => result.unavailableChecks.add(
        const CoachingUnavailableCheck('x', 'y')), throwsUnsupportedError);
    expect(() => result.weightInputRevisions['x'] = 1,
        throwsUnsupportedError);
  });

  test('finding and result constructors enforce their invariants', () {
    final result = richCheckIn();
    expect(
        () => CoachingFinding(
            rule: CoachingRuleLibrary.recordCoverage,
            evidence: const [],
            window: result.window,
            evaluatedDates: const [],
            inputRevisions: const {},
            dataQuality: result.quality,
            actionPayload: const {'count': 0, 'dates': 'none'}),
        throwsArgumentError);
    expect(
        () => CoachingFindingWindow(
            dates: const [], start: DiaryDate(2026, 1, 2)),
        throwsArgumentError);
    expect(
        () => CoachingFindingWindow(
            dates: const [],
            start: DiaryDate(2026, 1, 2),
            end: DiaryDate(2026, 1, 1)),
        throwsArgumentError);
    expect(CoachingFindingWindow(dates: const []).bounded, isFalse);
    expect(
        () => CheckInResult(result.safety, const [], const {},
            quality: result.quality),
        throwsArgumentError);
  });

  test('hold-course never claims adequacy or asks for a target change', () {
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
              revision: 1,
              completeness: DiaryCompleteness.confirmedNoIntake),
        ],
        window: window,
        entries: [
          entry('known', DiaryDate(2026, 1, 1), EntryChannel.manual, 1,
              fibre: NutrientReported(4)),
        ]);
    final hold = findingFor(result, 'hold-course');
    expect(hold.action, CoachingAction.hold);
    expect(hold.caveats, contains(CoachingCaveat.declarationsNotAdequacy));
    expect(hold.caveats, contains(CoachingCaveat.backdatedPreserved));
    expect(hold.caveats, isNot(contains(CoachingCaveat.unrecordedUnknown)));
    expect(hold.message, contains('no reason to change targets'));
    expect(hold.message, isNot(contains('adequate')));
    expect(hold.message, isNot(contains('deficit')));
  });
}
