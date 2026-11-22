/// Version-1 engineering plausibility screening for untrusted and automatic
/// nutrition values.
///
/// The numeric limits in this module are versioned engineering choices
/// requiring evaluation, not clinical limits or diagnostic thresholds.
library;

import 'dart:math' as math;

import 'nutrients.dart';
import 'photo_meal.dart';

/// Schema/rule version for the engineering plausibility thresholds below.
///
/// These are versioned engineering choices requiring evaluation, not clinical
/// limits.
const int nutritionScreeningVersion = 1;

/// Maximum plausible per-item energy in kcal before blocking automatic use.
const double _maxItemEnergyKcal = 10000;

/// Maximum plausible per-item gram nutrient amount before blocking.
const double _maxItemGramNutrientG = 1000;

/// Maximum plausible per-item sodium in mg before blocking automatic use.
const double _maxItemSodiumMg = 100000;

/// Maximum plausible energy density in kcal per gram of declared portion mass.
const double _maxEnergyKcalPerGram = 12;

/// Maximum plausible ratio of any single gram nutrient to declared portion mass.
const double _maxGramNutrientPerGramPortion = 1.1;

/// Minimum absolute energy discrepancy (kcal) before emitting a review warning.
const double _minMacroEnergyToleranceKcal = 100;

/// Relative tolerance on declared energy before emitting a review warning.
const double _relativeMacroEnergyTolerance = 0.30;

/// A screening or plausibility finding attached to a nutrition observation.
final class NutritionIssue {
  /// Creates a screening finding.
  const NutritionIssue({
    required this.code,
    this.nutrient,
    required this.blocksAutomaticUse,
  });

  /// Parses a serialized [NutritionIssue] produced by [toJson].
  factory NutritionIssue.fromJson(Map<String, Object?> json) {
    final code = json['code'];
    final blocks = json['blocksAutomaticUse'];
    if (code is! String || code.trim().isEmpty || blocks is! bool) {
      throw FormatException('Invalid NutritionIssue payload', json);
    }
    final rawNutrient = json['nutrient'];
    if (rawNutrient != null && rawNutrient is! String) {
      throw FormatException('Invalid NutritionIssue nutrient', rawNutrient);
    }
    final nutrient =
        rawNutrient is String ? NutrientKey.fromWire(rawNutrient) : null;
    return NutritionIssue(
      code: code,
      nutrient: nutrient,
      blocksAutomaticUse: blocks,
    );
  }

  /// Stable machine code, e.g. `invalidValue`, `absoluteLimit`,
  /// `massInconsistent`, or `macroEnergyMismatch`.
  final String code;

  /// Affected nutrient, if the finding applies to a specific field.
  final NutrientKey? nutrient;

  /// Whether automatic use was blocked (converting the field to unknown).
  final bool blocksAutomaticUse;

  /// Serializes this issue to JSON.
  Map<String, Object?> toJson() => {
        'code': code,
        if (nutrient case final nutrient?) 'nutrient': nutrient.wire,
        'blocksAutomaticUse': blocksAutomaticUse,
      };

  @override
  bool operator ==(Object other) =>
      other is NutritionIssue &&
      other.code == code &&
      other.nutrient == nutrient &&
      other.blocksAutomaticUse == blocksAutomaticUse;

  @override
  int get hashCode => Object.hash(code, nutrient, blocksAutomaticUse);

  @override
  String toString() =>
      'NutritionIssue(code: $code, nutrient: ${nutrient?.wire}, '
      'blocksAutomaticUse: $blocksAutomaticUse)';
}

/// The result of running plausibility screening on a [NutrientProfile].
final class ScreenedNutrition {
  /// Creates a screened nutrition result.
  ScreenedNutrition({
    required this.profile,
    required List<NutritionIssue> issues,
  }) : issues = List.unmodifiable(issues);

  /// Screened profile with any blocked fields replaced by [NutrientUnknown].
  final NutrientProfile profile;

  /// Issues discovered during screening, including non-blocking warnings.
  final List<NutritionIssue> issues;

  @override
  String toString() => 'ScreenedNutrition(profile: $profile, issues: $issues)';
}

/// Screens raw untrusted nutrient entries before constructing [NutrientValue]
/// instances.
///
/// Non-null entries that are not finite non-negative numbers emit
/// `invalidValue` with `blocksAutomaticUse: true` and remain
/// [NutrientUnknown], never calling [build] with invalid numbers or clamping to
/// zero. Valid finite non-negative numbers are built via [build] and screened
/// with [screenNutrition].
ScreenedNutrition screenRawNutrition(
  Map<NutrientKey, Object?> raw, {
  required NutrientValue Function(double value) build,
  MealPortion? portion,
}) {
  final values = <NutrientKey, NutrientValue>{};
  final rawIssues = <NutritionIssue>[];

  for (final key in NutrientKey.values) {
    if (!raw.containsKey(key)) continue;
    final entry = raw[key];
    if (entry == null) continue;
    if (entry is num && entry.isFinite && entry >= 0) {
      final normalized = entry == 0 ? 0.0 : entry.toDouble();
      values[key] = build(normalized);
    } else {
      rawIssues.add(
        NutritionIssue(
          code: 'invalidValue',
          nutrient: key,
          blocksAutomaticUse: true,
        ),
      );
      values[key] = const NutrientUnknown();
    }
  }

  final screened = screenNutrition(NutrientProfile(values), portion: portion);
  if (rawIssues.isEmpty) return screened;
  return ScreenedNutrition(
    profile: screened.profile,
    issues: [...rawIssues, ...screened.issues],
  );
}

/// Screens a [NutrientProfile] under version-1 engineering plausibility rules.
///
/// Preserves [NutrientUnknown] and [NutrientTrace] untouched. Blocked numeric
/// values become [NutrientUnknown] (never clamped to zero). Gram-portion mass
/// checks apply only when [portion] is expressed in [MealUnit.grams].
ScreenedNutrition screenNutrition(
  NutrientProfile profile, {
  MealPortion? portion,
}) {
  final screenedValues = <NutrientKey, NutrientValue>{};
  final issues = <NutritionIssue>[];

  for (final entry in profile.values.entries) {
    final key = entry.key;
    final value = entry.value;
    final numeric = switch (value) {
      NutrientMeasured(:final value) ||
      NutrientReported(:final value) ||
      NutrientEstimated(:final value) =>
        value,
      NutrientUnknown() || NutrientTrace() => null,
    };
    if (numeric == null) {
      screenedValues[key] = value;
      continue;
    }

    if (!numeric.isFinite || numeric < 0) {
      issues.add(
        NutritionIssue(
          code: 'invalidValue',
          nutrient: key,
          blocksAutomaticUse: true,
        ),
      );
      screenedValues[key] = const NutrientUnknown();
      continue;
    }

    if (_exceedsAbsoluteLimit(key, numeric)) {
      issues.add(
        NutritionIssue(
          code: 'absoluteLimit',
          nutrient: key,
          blocksAutomaticUse: true,
        ),
      );
      screenedValues[key] = const NutrientUnknown();
      continue;
    }

    if (portion != null &&
        portion.unit == MealUnit.grams &&
        _exceedsGramPortionMass(key, numeric, portion.amount)) {
      issues.add(
        NutritionIssue(
          code: 'massInconsistent',
          nutrient: key,
          blocksAutomaticUse: true,
        ),
      );
      screenedValues[key] = const NutrientUnknown();
      continue;
    }

    screenedValues[key] = value;
  }

  final screenedProfile = NutrientProfile(screenedValues);
  final energy = screenedProfile[NutrientKey.energyKcal];
  final protein = screenedProfile[NutrientKey.proteinG];
  final carb = screenedProfile[NutrientKey.carbohydrateG];
  final fat = screenedProfile[NutrientKey.fatG];

  if (energy.isKnown && protein.isKnown && carb.isKnown && fat.isKnown) {
    final fiber = screenedProfile[NutrientKey.fiberG];
    // Warning-only v1 heuristic: EU labels report available carbohydrate
    // excluding fibre (adding 2 kcal/g for fibre), whereas US labels report
    // total carbohydrate including fibre. Therefore this check never rewrites
    // or blocks reported energy or macros.
    final derivedEnergy = 4 * protein.numericValue! +
        4 * carb.numericValue! +
        9 * fat.numericValue! +
        (fiber.isKnown ? 2 * fiber.numericValue! : 0);
    final declaredEnergy = energy.numericValue!;
    final tolerance = math.max(
      _minMacroEnergyToleranceKcal,
      _relativeMacroEnergyTolerance * declaredEnergy,
    );
    if ((declaredEnergy - derivedEnergy).abs() > tolerance) {
      issues.add(
        const NutritionIssue(
          code: 'macroEnergyMismatch',
          nutrient: NutrientKey.energyKcal,
          blocksAutomaticUse: false,
        ),
      );
    }
  }

  return ScreenedNutrition(profile: screenedProfile, issues: issues);
}

bool _exceedsAbsoluteLimit(NutrientKey key, double value) => switch (key) {
      NutrientKey.energyKcal => value > _maxItemEnergyKcal,
      NutrientKey.sodiumMg => value > _maxItemSodiumMg,
      NutrientKey.proteinG ||
      NutrientKey.fatG ||
      NutrientKey.saturatedFatG ||
      NutrientKey.carbohydrateG ||
      NutrientKey.fiberG ||
      NutrientKey.sugarsG =>
        value > _maxItemGramNutrientG,
    };

bool _exceedsGramPortionMass(
  NutrientKey key,
  double value,
  double portionGrams,
) =>
    switch (key) {
      NutrientKey.energyKcal => value > _maxEnergyKcalPerGram * portionGrams,
      NutrientKey.sodiumMg => false,
      NutrientKey.proteinG ||
      NutrientKey.fatG ||
      NutrientKey.saturatedFatG ||
      NutrientKey.carbohydrateG ||
      NutrientKey.fiberG ||
      NutrientKey.sugarsG =>
        value > _maxGramNutrientPerGramPortion * portionGrams,
    };
