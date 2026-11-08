import 'nutrition_contract.dart';
import 'entry.dart';
import 'nutrients.dart';
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

/// Two observed readings are not a smoothed trend or an estimate of fat loss.
final class WeightObservation {
  const WeightObservation(this.first, this.last, this.count);
  final CoachingWeight first, last;
  final int count;
  Exact get changeKg => last.kilograms - first.kilograms;
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
}

enum CoachingAction { hold, improveData, editPlan, discussTarget, seekAdvice }

final class CoachingFinding {
  const CoachingFinding(
      this.ruleId, this.action, this.evidence, this.limitations);
  static const ruleVersion = 'coaching-nonadaptive-draft-v3';
  final String ruleId;
  final CoachingAction action;
  final List<String> evidence;
  final String limitations;
}

final class CheckInResult {
  CheckInResult(this.safety, this.findings, this.inputRevisions,
      {required this.quality,
      this.window,
      this.weightObservation,
      this.weightInputRevisions = const {},
      this.fibreCoverage,
      this.entryInputRevisions = const {}});
  final EligibilityDecision safety;
  final List<CoachingFinding> findings;
  final Map<String, int> inputRevisions;
  final CoachingWindow? window;
  final CoachingDataQuality quality;
  final WeightObservation? weightObservation;
  final Map<String, int> weightInputRevisions;
  final FibreCoverage? fibreCoverage;
  final Map<String, int> entryInputRevisions;
  String get adaptationStatus => 'disabled';
}

final class CoachingService {
  const CoachingService();
  CheckInResult checkIn(SafetyProfile profile, List<CoachingDay> days,
      {CoachingWindow? window,
      List<CoachingWeight> weights = const [],
      List<LoggedEntry> entries = const []}) {
    if (weights.isNotEmpty && window == null) {
      throw ArgumentError('Weight observations require a check-in window');
    }
    if (entries.isNotEmpty && window == null) {
      throw ArgumentError('Nutrient coverage requires a check-in window');
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
    final relevantWeights = weights
        .where((weight) =>
            window!.dates.contains(DiaryDate.assign(weight.stamp).toIso()))
        .toList()
      ..sort((a, b) => a.stamp.instantUtc.compareTo(b.stamp.instantUtc));
    // Equal timestamps cannot establish an ordering, regardless of input order.
    final first = relevantWeights.isEmpty ? null : relevantWeights.first;
    final last = relevantWeights.isEmpty ? null : relevantWeights.last;
    final weightObservation = first != null &&
            last != null &&
            first.stamp.instantUtc.isBefore(last.stamp.instantUtc) &&
            relevantWeights
                    .where((w) => w.stamp.instantUtc == first.stamp.instantUtc)
                    .length ==
                1 &&
            relevantWeights
                    .where((w) => w.stamp.instantUtc == last.stamp.instantUtc)
                    .length ==
                1
        ? WeightObservation(first, last, relevantWeights.length)
        : null;
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
    final safety = const EligibilityService().evaluate(profile);
    final findings = <CoachingFinding>[];
    if (safety.seekAdvice) {
      findings.add(CoachingFinding(
          'declared-needs',
          CoachingAction.seekAdvice,
          safety.reasonCodes,
          'Automatic energy advice is unavailable. Recording can remain available; consider qualified advice.'));
    }
    final incomplete = days
        .where((d) =>
            d.completeness == DiaryCompleteness.unknown ||
            d.completeness == DiaryCompleteness.partial)
        .toList();
    if (days.isEmpty || incomplete.isNotEmpty || missing.isNotEmpty) {
      findings.add(CoachingFinding(
          'record-coverage',
          CoachingAction.improveData,
          List.unmodifiable([...missing, ...incomplete.map((d) => d.date)]),
          'Unrecorded intake is unknown. Complete a record, estimate explicitly, or take a logging break.'));
    } else {
      findings.add(CoachingFinding(
          'hold-course',
          CoachingAction.hold,
          days.map((d) => d.date).toList(),
          'Day declarations describe recording, not nutritional adequacy or measured requirements. No target change is needed to run a check-in.'));
    }
    return CheckInResult(safety, List.unmodifiable(findings),
        Map.unmodifiable({for (final d in days) d.date: d.revision}),
        quality: quality,
        window: window,
        weightObservation: weightObservation,
        weightInputRevisions: Map.unmodifiable(
            {for (final w in relevantWeights) w.id: w.revision}),
        fibreCoverage: fibreCoverage.total == 0 ? null : fibreCoverage,
        entryInputRevisions: Map.unmodifiable(
            {for (final e in relevantEntries) e.id: e.revision}));
  }
}
