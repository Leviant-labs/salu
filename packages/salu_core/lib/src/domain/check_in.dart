import 'nutrients.dart';
import 'time.dart';

enum DiaryCompleteness { unknown, partial, declaredComplete, confirmedNoIntake }

final class DayObservation {
  DayObservation(
      {required this.date,
      this.completeness = DiaryCompleteness.unknown,
      this.weightKg,
      this.activityMinutes,
      Iterable<NutrientProfile> recorded = const []})
      : recorded = List.unmodifiable(recorded) {
    if ((weightKg != null && (!weightKg!.isFinite || weightKg! <= 0)) ||
        (activityMinutes != null &&
            (activityMinutes! < 0 || activityMinutes! > 1440))) {
      throw ArgumentError('Invalid weight or activity observation');
    }
  }
  final DiaryDate date;
  final DiaryCompleteness completeness;
  final double? weightKg;
  final int? activityMinutes;
  final List<NutrientProfile> recorded;

  bool get confirmed =>
      completeness == DiaryCompleteness.declaredComplete &&
          recorded.isNotEmpty ||
      completeness == DiaryCompleteness.confirmedNoIntake && recorded.isEmpty;
}

enum CheckInAction { improveRecords, reviewFoodChoices, reviewActivity, hold }

final class WeeklyCheckIn {
  const WeeklyCheckIn(
      {required this.days,
      required this.confirmedDays,
      required this.energyDays,
      required this.activityDays,
      required this.action,
      this.recordedEnergyAverage,
      this.weightChangeKg,
      this.activityTotalMinutes,
      this.energyIncludesEstimates = false});
  final int days, confirmedDays, energyDays, activityDays;
  final double? recordedEnergyAverage, weightChangeKg;
  final int? activityTotalMinutes;
  final bool energyIncludesEstimates;
  final CheckInAction action;
  static const ruleVersion = 1;
}

/// Compares only user-declared targets to recorded observations, not inferred
/// needs. Sparse data can't authorize diet or activity change suggestions.
WeeklyCheckIn weeklyCheckIn(Iterable<DayObservation> observations,
    {double? declaredEnergy,
    int? declaredActivityMinutes,
    bool allowOptionalActions = true}) {
  final days = observations.toList()..sort((a, b) => a.date.compareTo(b.date));
  final confirmed = days.where((day) => day.confirmed).length;
  final energy = <double>[];
  var includesEstimates = false;
  var includesUnresolvedEstimation = false;
  for (final day in days) {
    if (!day.confirmed) continue;
    if (day.completeness == DiaryCompleteness.confirmedNoIntake) {
      energy.add(0);
      continue;
    }
    final values =
        day.recorded.map((profile) => profile[NutrientKey.energyKcal]).toList();
    if (values.isEmpty || values.any((value) => !value.isKnown)) continue;
    final total =
        values.fold<double>(0, (sum, value) => sum + value.numericValue!);
    if (!total.isFinite) continue;
    energy.add(total);
    includesEstimates |= values.any((value) => value is NutrientEstimated);
    includesUnresolvedEstimation |= values.any((value) =>
        value is NutrientEstimated &&
        !value.basis.startsWith('usda-fdc-sr-legacy:'));
  }
  final mean = energy.isEmpty
      ? null
      : energy.fold<double>(0, (sum, n) => sum + n / energy.length);
  final activity =
      days.map((day) => day.activityMinutes).whereType<int>().toList();
  final activityTotal =
      activity.isEmpty ? null : activity.fold<int>(0, (sum, n) => sum + n);
  final early =
      days.take(3).map((day) => day.weightKg).whereType<double>().toList();
  final late =
      days.skip(4).map((day) => day.weightKg).whereType<double>().toList();
  final shift = days.length == 7 && early.length >= 2 && late.length >= 2
      ? _median(late) - _median(early)
      : null;
  final enough = days.length == 7 && confirmed >= 5;
  final action = !enough
      ? CheckInAction.improveRecords
      : !allowOptionalActions
          ? CheckInAction.hold
          : declaredActivityMinutes != null &&
                  activity.length == days.length &&
                  activityTotal! < declaredActivityMinutes
              ? CheckInAction.reviewActivity
              : declaredEnergy != null &&
                      energy.length == days.length &&
                      !includesUnresolvedEstimation &&
                      mean != null &&
                      mean > declaredEnergy
                  ? CheckInAction.reviewFoodChoices
                  : CheckInAction.hold;
  return WeeklyCheckIn(
      days: days.length,
      confirmedDays: confirmed,
      energyDays: energy.length,
      activityDays: activity.length,
      action: action,
      recordedEnergyAverage: mean,
      weightChangeKg: shift,
      activityTotalMinutes: activityTotal,
      energyIncludesEstimates: includesEstimates);
}

double _median(List<double> values) {
  values.sort();
  final i = values.length ~/ 2;
  return values.length.isOdd ? values[i] : (values[i - 1] + values[i]) / 2;
}
