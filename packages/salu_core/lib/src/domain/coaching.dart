import 'entry.dart';
import 'nutrients.dart';
import 'nutrition_contract.dart';
import 'policy.dart';
import 'time.dart';

/// An inclusive interval of diary dates. Dates have no timezone conversion.
final class CoachingWindow {
  CoachingWindow(this.start, this.end) {
    final length = DateTime.utc(end.year, end.month, end.day)
            .difference(DateTime.utc(start.year, start.month, start.day))
            .inDays +
        1;
    if (length < 1 || length > 366) {
      throw ArgumentError('Check-in window must contain 1 to 366 days');
    }
    dates = List.unmodifiable(
        List.generate(length, (i) => start.addDays(i).toIso()));
  }

  final DiaryDate start, end;
  late final List<String> dates;
}

/// Describes declarations, never the amount of unrecorded intake.
final class CoachingDataQuality {
  CoachingDataQuality({
    required this.expectedDays,
    required this.completeDays,
    required this.confirmedNoIntakeDays,
    required this.partialDays,
    required this.unknownDays,
    required List<String> missingDates,
  }) : missingDates = List.unmodifiable(missingDates);

  final int expectedDays,
      completeDays,
      confirmedNoIntakeDays,
      partialDays,
      unknownDays;
  final List<String> missingDates;
}

final class CoachingDay {
  const CoachingDay(
      {required this.date, required this.revision, required this.completeness});

  final String date;
  final int revision;
  final DiaryCompleteness completeness;
}

/// A recorded scale reading, separate from target and energy calculations.
final class CoachingWeight {
  CoachingWeight(
      {required this.id,
      required this.revision,
      required this.stamp,
      required this.kilograms}) {
    if (id.isEmpty || revision < 1 || !kilograms.positive) {
      throw ArgumentError('Invalid weight observation');
    }
  }

  final String id;
  final int revision;
  final EventStamp stamp;
  final Exact kilograms;
}

/// Endpoint readings only. Two observations are not a smoothed trend, a
/// plateau, or an estimate of fat loss.
final class WeightObservation {
  const WeightObservation(this.first, this.last, this.count);

  final CoachingWeight first, last;
  final int count;

  Exact get changeKg => last.kilograms - first.kilograms;

  /// Diary date of the first reading, following the recorded offset.
  String get firstDate => DiaryDate.assign(first.stamp).toIso();

  /// Diary date of the last reading, following the recorded offset.
  String get lastDate => DiaryDate.assign(last.stamp).toIso();
}

/// Deterministic ordering for recorded scale readings and the only comparison
/// the domain supports: unique earliest and latest endpoints.
///
/// Readings are ordered by recorded instant, then by id, so equal timestamps
/// never depend on storage order. Endpoint ordering is ambiguous when more than
/// one reading shares the earliest or latest instant; in that case no
/// [observation] is produced rather than choosing one silently. Nothing here
/// smooths, interpolates, or infers a rate, trend, plateau, or cause.
final class WeightReadingLog {
  WeightReadingLog._(this.readings, this.observation, this.ambiguousEndpoints);

  factory WeightReadingLog(Iterable<CoachingWeight> readings) {
    final ordered = readings.toList()
      ..sort((a, b) {
        final byInstant = a.stamp.instantUtc.compareTo(b.stamp.instantUtc);
        return byInstant != 0 ? byInstant : a.id.compareTo(b.id);
      });
    final seen = <String>{};
    for (final reading in ordered) {
      if (!seen.add(reading.id)) {
        throw ArgumentError('Duplicate weight ID');
      }
    }
    final first = ordered.isEmpty ? null : ordered.first;
    final last = ordered.isEmpty ? null : ordered.last;
    var ambiguous = false;
    WeightObservation? observation;
    if (first != null && last != null) {
      final firstRepeated = ordered.length > 1 &&
          ordered[1].stamp.instantUtc == first.stamp.instantUtc;
      final lastRepeated = ordered.length > 1 &&
          ordered[ordered.length - 2].stamp.instantUtc == last.stamp.instantUtc;
      ambiguous = (firstRepeated || lastRepeated) &&
          first.stamp.instantUtc.isBefore(last.stamp.instantUtc);
      if (!ambiguous && first.stamp.instantUtc.isBefore(last.stamp.instantUtc)) {
        observation = WeightObservation(first, last, ordered.length);
      }
    }
    return WeightReadingLog._(
        List<CoachingWeight>.unmodifiable(ordered), observation, ambiguous);
  }

  /// Recorded readings in instant order (equal instants ordered by id).
  final List<CoachingWeight> readings;

  /// Endpoint comparison, present only when two distinct instants exist and
  /// both the earliest and latest instants belong to exactly one reading.
  final WeightObservation? observation;

  /// True when the earliest or latest of two distinct recorded instants is
  /// shared by several readings, so no endpoint order can be claimed. Readings
  /// that all share one instant are not endpoint ambiguity; they simply have no
  /// two distinct times to compare.
  final bool ambiguousEndpoints;

  bool get isEmpty => readings.isEmpty;
}

/// Coverage of fibre values in logged item snapshots, not intake adequacy.
final class FibreCoverage {
  const FibreCoverage(
      {required this.reported,
      required this.estimated,
      required this.trace,
      required this.unknown});

  final int reported, estimated, trace, unknown;

  int get total => reported + estimated + trace + unknown;

  /// Snapshots with a usable numeric value, whether reported or estimated.
  int get known => reported + estimated;
}

enum CoachingAction { hold, improveData, editPlan, discussTarget, seekAdvice }

/// A data-quality limitation attached to a finding.
///
/// These are part of the versioned rule semantics: changing a message requires
/// reviewing the rule-library version that produced it.

enum CoachingCaveat {
  unrecordedUnknown(
      'Unrecorded intake is unknown and is never counted as zero or estimated here.'),
  declarationsNotAdequacy(
      'Day declarations describe recording, not nutritional adequacy, measured requirements, or progress.'),
  spotWeightsNotTrend(
      'Scale readings are spot observations, not a smoothed trend, plateau, fat-loss estimate, or cause.'),
  fibreCoverageNotAdequacy(
      'Fibre coverage describes recorded item snapshots, not intake adequacy or a reference comparison.'),
  planNotIntake(
      'A plan is organization only; planned meals are not intake and never write the diary.'),
  planDateLevelOnly(
      'Plan and intake counts are matched by diary date only; no slot-level confirmation is claimed.'),
  safetyNotDiagnosis(
      'Safety routing is not a diagnosis, treatment plan, medical reassurance, or guaranteed outcome.'),
  backdatedPreserved(
      'Backdated and revised records are used with their recorded diary dates and revisions.');

  const CoachingCaveat(this.message);

  final String message;
}

/// One versioned deterministic rule: identity, suggested action, baseline
/// templated copy, and the caveats that always accompany its findings.
final class CoachingRule {
  const CoachingRule({
    required this.id,
    required this.version,
    required this.action,
    required this.priority,
    required this.applicablePopulation,
    required this.template,
    required this.limitations,
    required this.requiredInputs,
    required this.caveats,
  });

  final String id;
  final String version;
  final CoachingAction action;

  /// Lower values are shown first. Safety routes always keep priority 0.
  final int priority;

  /// Population scope for this rule.
  final String applicablePopulation;
  final String template;
  final String limitations;
  final List<String> requiredInputs;
  final List<CoachingCaveat> caveats;

  /// Renders [template]. Throws instead of returning unresolved placeholders,
  /// so a malformed finding fails deterministically.
  String render(Map<String, Object?> values) {
    final missing = <String>[];
    final rendered = template.replaceAllMapped(_placeholder, (match) {
      final key = match.group(1)!;
      if (!values.containsKey(key)) {
        missing.add(key);
        return match.group(0)!;
      }
      return '${values[key]}';
    });
    if (missing.isNotEmpty) {
      throw ArgumentError(
          'Missing template value(s) for $ruleIdentity: ${missing.join(', ')}');
    }
    return rendered;
  }

  String get ruleIdentity => '$id@$version';

  static final RegExp _placeholder = RegExp(r'\{([A-Za-z0-9_]+)\}');
}

/// A check the app intentionally does not perform because required evidence
/// is absent. Reporting it prevents silent absences.
final class CoachingUnavailableCheck {
  const CoachingUnavailableCheck(this.id, this.reason);

  final String id;
  final String reason;
}

/// The complete versioned library of deterministic check-in rules.
/// No rule compares intake to an invented clinical threshold.
abstract final class CoachingRuleLibrary {
  /// Version of the rule set, caveat wording, and template semantics.
  static const version = 'coaching-rules-v5';

  static const _population = 'declared records only';

  static const safetyRoute = CoachingRule(
    id: 'safety-route',
    version: '1',
    action: CoachingAction.seekAdvice,
    priority: 0,
    applicablePopulation: _population,
    template:
        'Your declarations route this check-in to qualified advice before any automatic energy guidance: {reasons}.',
    limitations:
        'Routing statement only. Recording, manual targets and ordinary app use remain available.',
    requiredInputs: ['safety-profile'],
    caveats: [
      CoachingCaveat.safetyNotDiagnosis,
    ],
  );

  static const recordCoverage = CoachingRule(
    id: 'record-coverage',
    version: '1',
    action: CoachingAction.improveData,
    priority: 10,
    applicablePopulation: _population,
    template:
        'Recording is incomplete for {count} day(s) in this check-in: {dates}. Unrecorded intake is unknown, not zero. Complete a record, estimate explicitly, or take a logging break.',
    limitations:
        'Reports recording gaps only. It does not estimate missing intake, authorize a deficit, or establish nutritional adequacy.',
    requiredInputs: ['diary-day-declarations', 'check-in-window'],
    caveats: [
      CoachingCaveat.unrecordedUnknown,
      CoachingCaveat.declarationsNotAdequacy,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const holdCourse = CoachingRule(
    id: 'hold-course',
    version: '1',
    action: CoachingAction.hold,
    priority: 100,
    applicablePopulation: _population,
    template:
        'All {count} considered day(s) are declared complete or confirmed no-intake. Hold the current approach; this check-in provides no reason to change targets.',
    limitations:
        'Declarations describe recording, not nutritional adequacy or goal progress. Hold-course is neutral and does not certify health.',
    requiredInputs: ['diary-day-declarations'],
    caveats: [
      CoachingCaveat.declarationsNotAdequacy,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const weightReadings = CoachingRule(
    id: 'weight-readings',
    version: '1',
    action: CoachingAction.hold,
    priority: 20,
    applicablePopulation: _population,
    template:
        '{count} recorded weight reading(s), first on {firstDate} and last on {lastDate}, range from {first} kg to {last} kg ({change} kg endpoint difference). No trend or plateau is computed.',
    limitations:
        'Endpoint observations only. Scale noise, hydration and time of day are not modeled. This cannot measure fat loss or explain a cause.',
    requiredInputs: ['weight-readings', 'check-in-window'],
    caveats: [
      CoachingCaveat.spotWeightsNotTrend,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const fibreCoverage = CoachingRule(
    id: 'fibre-coverage',
    version: '1',
    action: CoachingAction.hold,
    priority: 30,
    applicablePopulation: _population,
    template:
        'Fibre values cover {total} recorded item snapshot(s): {reported} reported, {estimated} estimated, {trace} trace, {unknown} unknown. All recorded fibre states are explicit; no adequacy verdict is made.',
    limitations:
        'Coverage of recorded item snapshots only. Missing fibre values are not zero, and no reference comparison or deficiency claim is made.',
    requiredInputs: ['logged-entry-item-nutrients', 'check-in-window'],
    caveats: [
      CoachingCaveat.fibreCoverageNotAdequacy,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const fibreCoverageGaps = CoachingRule(
    id: 'fibre-coverage-gaps',
    version: '1',
    action: CoachingAction.improveData,
    priority: 30,
    applicablePopulation: _population,
    template:
        'Fibre values are unknown for {unknown} of {total} recorded item snapshot(s): {reported} reported, {estimated} estimated, {trace} trace. A numeric total would be incomplete; no adequacy verdict is made.',
    limitations:
        'Reports missing item values, not low intake. Missing fibre values are not zero, and no reference comparison or deficiency claim is made.',
    requiredInputs: ['logged-entry-item-nutrients', 'check-in-window'],
    caveats: [
      CoachingCaveat.fibreCoverageNotAdequacy,
      CoachingCaveat.unrecordedUnknown,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const planRecording = CoachingRule(
    id: 'plan-recording',
    version: '1',
    action: CoachingAction.hold,
    priority: 40,
    applicablePopulation: _population,
    template:
        'The plan schedules {slots} meal slot(s) across {days} day(s); {entries} separate plan-origin intake record(s) fall on those dates.',
    limitations:
        'A plan is organization only. Counts are by diary date; no slot-level match, adherence, or intake claim is made.',
    requiredInputs: [
      'plan-slots',
      'logged-entry-channels',
      'check-in-window'
    ],
    caveats: [
      CoachingCaveat.planNotIntake,
      CoachingCaveat.planDateLevelOnly,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const planRecordingGaps = CoachingRule(
    id: 'plan-recording-gaps',
    version: '1',
    action: CoachingAction.improveData,
    priority: 40,
    applicablePopulation: _population,
    template:
        'The plan schedules {slots} meal slot(s) across {days} day(s), with {entries} separate plan-origin intake record(s) on those dates. If you want plan follow-through in the check-in, confirm consumed plan meals separately; skipping a planned meal is not a failure.',
    limitations:
        'A plan is organization only. Counts are by diary date; no slot-level match, adherence, or intake claim is made.',
    requiredInputs: [
      'plan-slots',
      'logged-entry-channels',
      'check-in-window'
    ],
    caveats: [
      CoachingCaveat.planNotIntake,
      CoachingCaveat.planDateLevelOnly,
      CoachingCaveat.unrecordedUnknown,
      CoachingCaveat.backdatedPreserved,
    ],
  );

  static const all = <CoachingRule>[
    safetyRoute,
    recordCoverage,
    weightReadings,
    fibreCoverage,
    fibreCoverageGaps,
    planRecording,
    planRecordingGaps,
    holdCourse,
  ];

  static const weightTrend = CoachingUnavailableCheck(
      'weight-trend',
      'No trend rule exists; only raw endpoint observations from recorded readings are reported.');
  static const possiblePlateau = CoachingUnavailableCheck(
      'possible-progress-plateau',
      'No plateau window or tolerance exists; spot readings cannot establish a plateau.');
  static const nutrientAdequacy = CoachingUnavailableCheck(
      'nutrient-adequacy',
      'Nutrient adequacy requires reference comparison; only recorded item coverage is reported.');
  static const planAdherence = CoachingUnavailableCheck(
      'plan-adherence',
      'Slot-level plan adherence requires confirmation links; only date-level record counts are reported.');
  static const notificationPolicy = CoachingUnavailableCheck(
      'notification-cooldown',
      'Notification timing: this check-in schedules no notification.');

  static const unavailableChecks = <CoachingUnavailableCheck>[
    weightTrend,
    possiblePlateau,
    nutrientAdequacy,
    planAdherence,
    notificationPolicy,
  ];
}

/// Parses a plan slot date, normalizing malformed input to [ArgumentError].
DiaryDate _parseSlotDate(String value) {
  try {
    return DiaryDate.parse(value);
  } on FormatException {
    throw ArgumentError.value(
        value, 'date', 'must be a canonical yyyy-MM-dd');
  }
}

/// A scheduled plan slot supplied to a check-in. It is scheduling data, not
/// intake; [revision] preserves the version of the plan record it came from.
final class CoachingPlanSlot {
  CoachingPlanSlot({
    required this.slotId,
    required this.date,
    required this.revision,
  }) {
    if (slotId.isEmpty || revision < 1) {
      throw ArgumentError('Invalid plan slot');
    }
    final parsed = _parseSlotDate(date);
    if (parsed.toIso() != date) {
      throw ArgumentError.value(date, 'date', 'must be a canonical yyyy-MM-dd');
    }
  }

  final String slotId;
  final String date;
  final int revision;
}

/// The exact evaluated scope of a finding. [dates] is the bounded check-in
/// window when one was supplied, otherwise the supplied day declarations.
/// [start]/[end] are present only for a bounded window.
final class CoachingFindingWindow {
  CoachingFindingWindow({
    required List<String> dates,
    this.start,
    this.end,
  }) : dates = List.unmodifiable(dates) {
    final windowStart = start;
    final windowEnd = end;
    if ((windowStart == null) != (windowEnd == null)) {
      throw ArgumentError('Finding window bounds must be supplied together');
    }
    if (windowStart != null &&
        windowEnd != null &&
        windowEnd.compareTo(windowStart) < 0) {
      throw ArgumentError('Finding window end precedes its start');
    }
  }

  factory CoachingFindingWindow.of(
          CoachingWindow? window, List<String> suppliedDates) =>
      CoachingFindingWindow(
          dates: window?.dates ?? suppliedDates,
          start: window?.start,
          end: window?.end);

  final List<String> dates;
  final DiaryDate? start, end;

  bool get bounded => start != null && end != null;
}

/// Combines rule caveats with invocation-specific ones and always surfaces
/// incomplete day coverage as an unknown-intake caveat.
List<CoachingCaveat> _findingCaveats(CoachingRule rule,
    List<CoachingCaveat> extra, CoachingDataQuality quality) {
  final values = <CoachingCaveat>{...rule.caveats, ...extra};
  if (quality.missingDates.isNotEmpty ||
      quality.partialDays > 0 ||
      quality.unknownDays > 0) {
    values.add(CoachingCaveat.unrecordedUnknown);
  }
  return values.toList();
}

/// One deterministic finding with an explicit scope, evidence, input revisions,
/// data-quality snapshot, caveats, and versioned templated semantics.
final class CoachingFinding {
  CoachingFinding({
    required this.rule,
    required List<String> evidence,
    required CoachingWindow? window,
    required List<String> evaluatedDates,
    required Map<String, int> inputRevisions,
    required CoachingDataQuality dataQuality,
    List<CoachingCaveat> caveats = const [],
    Map<String, Object?> actionPayload = const {},
  })  : window = CoachingFindingWindow.of(window, evaluatedDates),
        evidence = List.unmodifiable(evidence),
        evaluatedDates = List.unmodifiable(evaluatedDates),
        inputRevisions = Map.unmodifiable(inputRevisions),
        dataQuality = dataQuality,
        caveats = List.unmodifiable(
            _findingCaveats(rule, caveats, dataQuality)),
        actionPayload = Map.unmodifiable(actionPayload) {
    if (evidence.isEmpty) {
      throw ArgumentError('A finding must state its evidence');
    }
  }

  final CoachingRule rule;
  final List<String> evidence;

  /// Always present. It is bounded when the caller supplied a check-in window
  /// and otherwise enumerates the supplied day declarations.
  final CoachingFindingWindow window;

  /// Exact diary dates or record identifiers this rule evaluated. This may be
  /// a subset of [window] (for example, only dates with weight readings).
  final List<String> evaluatedDates;
  final Map<String, int> inputRevisions;
  final CoachingDataQuality dataQuality;
  final List<CoachingCaveat> caveats;
  final Map<String, Object?> actionPayload;

  String get ruleId => rule.id;
  String get ruleVersion => rule.version;
  String get ruleIdentity => rule.ruleIdentity;
  String get rulesVersion => CoachingRuleLibrary.version;
  String get applicablePopulation => rule.applicablePopulation;
  CoachingAction get action => rule.action;
  int get priority => rule.priority;
  String get limitations => rule.limitations;

  /// Baseline templated copy with every placeholder rendered.
  String get message => rule.render(actionPayload);
}

final class CheckInResult {
  CheckInResult(
    this.safety,
    List<CoachingFinding> findings,
    Map<String, int> inputRevisions, {
    required this.quality,
    this.window,
    this.weightObservation,
    Map<String, int> weightInputRevisions = const {},
    this.fibreCoverage,
    Map<String, int> entryInputRevisions = const {},
    Map<String, int> planInputRevisions = const {},
    List<CoachingUnavailableCheck> unavailableChecks =
        CoachingRuleLibrary.unavailableChecks,
  })  : findings = List.unmodifiable(
            findings.toList()..sort((a, b) => a.priority.compareTo(b.priority))),
        inputRevisions = Map.unmodifiable(inputRevisions),
        weightInputRevisions = Map.unmodifiable(weightInputRevisions),
        entryInputRevisions = Map.unmodifiable(entryInputRevisions),
        planInputRevisions = Map.unmodifiable(planInputRevisions),
        unavailableChecks = List.unmodifiable(unavailableChecks) {
    if (this.findings.isEmpty) {
      throw ArgumentError('A check-in must include at least one finding');
    }
  }

  final EligibilityDecision safety;
  final List<CoachingFinding> findings;
  final Map<String, int> inputRevisions;
  final CoachingWindow? window;
  final CoachingDataQuality quality;
  final WeightObservation? weightObservation;
  final Map<String, int> weightInputRevisions;
  final FibreCoverage? fibreCoverage;
  final Map<String, int> entryInputRevisions;
  final Map<String, int> planInputRevisions;

  /// Checks intentionally unavailable in this release, with the missing
  /// evidence or approval that would be required.
  final List<CoachingUnavailableCheck> unavailableChecks;

  CoachingFinding get primaryFinding => findings.first;

  String get coachingRulesVersion => CoachingRuleLibrary.version;
}

final class CoachingService {
  const CoachingService();

  /// Computes deterministic, non-adaptive findings from local records.
  ///
  /// [plannedSlots] are scheduling data, never intake. They are matched to
  /// separately confirmed plan-origin entries by diary date only; no
  /// slot-level adherence is inferred. Weights and entries require [window]
  /// so their evidence has an explicit bounded scope.
  CheckInResult checkIn(SafetyProfile profile, List<CoachingDay> days,
      {CoachingWindow? window,
      List<CoachingWeight> weights = const [],
      List<LoggedEntry> entries = const [],
      List<CoachingPlanSlot> plannedSlots = const []}) {
    if (weights.isNotEmpty && window == null) {
      throw ArgumentError('Weight observations require a check-in window');
    }
    if (entries.isNotEmpty && window == null) {
      throw ArgumentError('Nutrient coverage requires a check-in window');
    }
    if (plannedSlots.isNotEmpty && window == null) {
      throw ArgumentError('Plan slots require a check-in window');
    }

    final seenEntries = <String>{};
    final relevantEntries = <LoggedEntry>[];
    for (final entry in entries) {
      if (entry.id.isEmpty ||
          entry.revision < 1 ||
          !seenEntries.add(entry.id)) {
        throw ArgumentError('Invalid or duplicate entry');
      }
      if (window!.dates.contains(entry.diaryDate.toIso())) {
        relevantEntries.add(entry);
      }
    }

    var reported = 0, estimated = 0, trace = 0, unknown = 0;
    for (final entry in relevantEntries) {
      for (final item in entry.items) {
        switch (item.nutrients[NutrientKey.fiberG]) {
          case NutrientReported() || NutrientMeasured():
            reported++;
          case NutrientEstimated():
            estimated++;
          case NutrientTrace():
            trace++;
          case NutrientUnknown():
            unknown++;
        }
      }
    }
    final fibreCoverage = FibreCoverage(
        reported: reported,
        estimated: estimated,
        trace: trace,
        unknown: unknown);

    final seenWeights = <String>{};
    for (final weight in weights) {
      if (!seenWeights.add(weight.id)) {
        throw ArgumentError('Duplicate weight ID');
      }
    }
    // Equal timestamps cannot establish an ordering, regardless of input order.
    final weightLog = WeightReadingLog(weights.where((weight) =>
        window!.dates.contains(DiaryDate.assign(weight.stamp).toIso())));
    final weightObservation = weightLog.observation;

    final seenSlots = <String>{};
    final relevantSlots = <CoachingPlanSlot>[];
    for (final slot in plannedSlots) {
      if (!seenSlots.add(slot.slotId)) {
        throw ArgumentError('Duplicate plan slot ID');
      }
      if (!window!.dates.contains(slot.date)) {
        throw ArgumentError('Plan slot outside check-in window');
      }
      relevantSlots.add(slot);
    }

    final byDate = <String, CoachingDay>{};
    for (final day in days) {
      if (byDate.containsKey(day.date) || day.revision < 0) {
        throw ArgumentError('Duplicate date or negative revision');
      }
      if (window != null && !window.dates.contains(day.date)) {
        throw ArgumentError('Diary day outside check-in window');
      }
      byDate[day.date] = day;
    }
    final missing =
        window?.dates.where((date) => !byDate.containsKey(date)).toList() ??
            <String>[];
    int count(DiaryCompleteness value) =>
        days.where((day) => day.completeness == value).length;
    final quality = CoachingDataQuality(
        expectedDays: window?.dates.length ?? days.length,
        completeDays: count(DiaryCompleteness.userDeclaredComplete),
        confirmedNoIntakeDays: count(DiaryCompleteness.confirmedNoIntake),
        partialDays: count(DiaryCompleteness.partial),
        unknownDays: count(DiaryCompleteness.unknown),
        missingDates: missing);

    final scopeDates =
        window?.dates ?? List<String>.unmodifiable(days.map((d) => d.date));
    final dayRevisions = <String, int>{
      for (final day in days) 'day:${day.date}': day.revision
    };
    final findings = <CoachingFinding>[];

    final safety = const EligibilityService().evaluate(profile);
    if (safety.seekAdvice) {
      findings.add(_finding(
        CoachingRuleLibrary.safetyRoute,
        evidence: [
          'safety reason codes: ${safety.reasonCodes.join(', ')}',
          'recording and starting estimates remain available',
        ],
        window: window,
        evaluatedDates: scopeDates,
        inputRevisions: dayRevisions,
        quality: quality,
        actionPayload: {'reasons': safety.reasonCodes.join(', ')},
      ));
    }

    final incompleteDates = [
      for (final day in days)
        if (day.completeness == DiaryCompleteness.unknown ||
            day.completeness == DiaryCompleteness.partial)
          day.date
    ];
    if (days.isEmpty || incompleteDates.isNotEmpty || missing.isNotEmpty) {
      final gapDates = [...missing, ...incompleteDates];
      findings.add(_finding(
        CoachingRuleLibrary.recordCoverage,
        evidence: gapDates.isEmpty
            ? const ['No day declarations were supplied for this check-in.']
            : [
                ...gapDates,
                'unrecorded intake is unknown and is not counted as zero',
              ],
        window: window,
        evaluatedDates: scopeDates,
        inputRevisions: dayRevisions,
        quality: quality,
        actionPayload: {
          'count': gapDates.length,
          'dates': gapDates.isEmpty ? 'none supplied' : gapDates.join(', '),
        },
      ));
    } else {
      findings.add(_finding(
        CoachingRuleLibrary.holdCourse,
        evidence: [
          ...days.map((day) => day.date),
          'all considered days are declared complete or confirmed no-intake',
        ],
        window: window,
        evaluatedDates: scopeDates,
        inputRevisions: dayRevisions,
        quality: quality,
        actionPayload: {'count': days.length},
      ));
    }

    if (weightObservation != null) {
      final weightRevisions = <String, int>{
        for (final weight in weightLog.readings)
          'weight:${weight.id}': weight.revision
      };
      findings.add(_finding(
        CoachingRuleLibrary.weightReadings,
        evidence: [
          for (final weight in weightLog.readings)
            'weight reading ${weight.id} on '
                '${DiaryDate.assign(weight.stamp).toIso()}: '
                '${weight.kilograms} kg (revision ${weight.revision})',
          'endpoint difference: ${weightObservation.changeKg} kg',
        ],
        window: window,
        evaluatedDates: [
          for (final weight in weightLog.readings)
            DiaryDate.assign(weight.stamp).toIso()
        ],
        inputRevisions: weightRevisions,
        quality: quality,
        actionPayload: {
          'count': weightObservation.count,
          'firstDate': weightObservation.firstDate,
          'lastDate': weightObservation.lastDate,
          'first': '${weightObservation.first.kilograms}',
          'last': '${weightObservation.last.kilograms}',
          'change': '${weightObservation.changeKg}',
        },
      ));
    }

    if (fibreCoverage.total > 0) {
      final entryRevisions = <String, int>{
        for (final entry in relevantEntries) 'entry:${entry.id}': entry.revision
      };
      final gaps = unknown > 0;
      findings.add(_finding(
        gaps
            ? CoachingRuleLibrary.fibreCoverageGaps
            : CoachingRuleLibrary.fibreCoverage,
        evidence: [
          'logged item snapshots in window: ${fibreCoverage.total}',
          'reported: $reported; estimated: $estimated; '
              'trace: $trace; unknown: $unknown',
          for (final entry in relevantEntries)
            'entry ${entry.id} on ${entry.diaryDate.toIso()} '
                '(revision ${entry.revision})',
        ],
        window: window,
        evaluatedDates: [
          for (final entry in relevantEntries) entry.diaryDate.toIso()
        ],
        inputRevisions: entryRevisions,
        quality: quality,
        actionPayload: {
          'total': fibreCoverage.total,
          'reported': reported,
          'estimated': estimated,
          'trace': trace,
          'unknown': unknown,
        },
      ));
    }

    if (relevantSlots.isNotEmpty) {
      final slotDates = <String>{for (final slot in relevantSlots) slot.date};
      final planEntries = relevantEntries
          .where((entry) =>
              entry.channel == EntryChannel.plan &&
              slotDates.contains(entry.diaryDate.toIso()))
          .toList();
      final gaps = planEntries.length < relevantSlots.length;
      findings.add(_finding(
        gaps
            ? CoachingRuleLibrary.planRecordingGaps
            : CoachingRuleLibrary.planRecording,
        evidence: [
          for (final slot in relevantSlots)
            'plan slot ${slot.slotId} on ${slot.date} '
                '(revision ${slot.revision})',
          for (final entry in planEntries)
            'plan-origin entry ${entry.id} on ${entry.diaryDate.toIso()} '
                '(revision ${entry.revision})',
          'scheduled slots: ${relevantSlots.length}; '
              'separate plan-origin records on those dates: '
              '${planEntries.length}',
        ],
        window: window,
        evaluatedDates: slotDates.toList(),
        inputRevisions: {
          for (final slot in relevantSlots) 'plan:${slot.slotId}': slot.revision,
          for (final entry in planEntries) 'entry:${entry.id}': entry.revision,
        },
        quality: quality,
        actionPayload: {
          'slots': relevantSlots.length,
          'days': slotDates.length,
          'entries': planEntries.length,
        },
      ));
    }

    return CheckInResult(
      safety,
      findings,
      Map.unmodifiable({for (final day in days) day.date: day.revision}),
      quality: quality,
      window: window,
      weightObservation: weightObservation,
      weightInputRevisions: Map.unmodifiable(
          {for (final weight in weightLog.readings) weight.id: weight.revision}),
      fibreCoverage: fibreCoverage.total == 0 ? null : fibreCoverage,
      entryInputRevisions: Map.unmodifiable(
          {for (final entry in relevantEntries) entry.id: entry.revision}),
      planInputRevisions: Map.unmodifiable(
          {for (final slot in relevantSlots) slot.slotId: slot.revision}),
      unavailableChecks: CoachingRuleLibrary.unavailableChecks,
    );
  }

  CoachingFinding _finding(
    CoachingRule rule, {
    required List<String> evidence,
    required CoachingWindow? window,
    required List<String> evaluatedDates,
    required Map<String, int> inputRevisions,
    required CoachingDataQuality quality,
    required Map<String, Object?> actionPayload,
  }) =>
      CoachingFinding(
        rule: rule,
        evidence: evidence,
        window: window,
        evaluatedDates: evaluatedDates,
        inputRevisions: inputRevisions,
        dataQuality: quality,
        actionPayload: actionPayload,
      );
}
