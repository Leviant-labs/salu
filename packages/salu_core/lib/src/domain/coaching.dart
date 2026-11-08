import 'nutrition_contract.dart';
import 'policy.dart';

final class CoachingDay {
  const CoachingDay(
      {required this.date, required this.revision, required this.completeness});
  final String date;
  final int revision;
  final DiaryCompleteness completeness;
}

enum CoachingAction { hold, improveData, editPlan, discussTarget, seekAdvice }

final class CoachingFinding {
  const CoachingFinding(
      this.ruleId, this.action, this.evidence, this.limitations);
  static const ruleVersion = 'coaching-nonadaptive-draft-v2';
  final String ruleId;
  final CoachingAction action;
  final List<String> evidence;
  final String limitations;
}

final class CheckInResult {
  CheckInResult(this.safety, this.findings, this.inputRevisions);
  final EligibilityDecision safety;
  final List<CoachingFinding> findings;
  final Map<String, int> inputRevisions;
  String get adaptationStatus => 'disabled';
}

final class CoachingService {
  const CoachingService();
  CheckInResult checkIn(SafetyProfile profile, List<CoachingDay> days) {
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
    if (incomplete.isNotEmpty) {
      findings.add(CoachingFinding(
          'record-coverage',
          CoachingAction.improveData,
          incomplete.map((d) => d.date).toList(),
          'Unrecorded intake is unknown. Complete a record, estimate explicitly, or take a logging break.'));
    } else {
      findings.add(CoachingFinding(
          'hold-course',
          CoachingAction.hold,
          days.map((d) => d.date).toList(),
          'Day declarations describe recording, not nutritional adequacy or measured requirements. No target change is needed to run a check-in.'));
    }
    return CheckInResult(safety, List.unmodifiable(findings),
        Map.unmodifiable({for (final d in days) d.date: d.revision}));
  }
}
