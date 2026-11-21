import 'package:salu_core/salu_core.dart';

extension MealSlotLabel on MealSlot {
  String get label => switch (this) {
        MealSlot.breakfast => 'Breakfast',
        MealSlot.lunch => 'Lunch',
        MealSlot.dinner => 'Dinner',
        MealSlot.snack => 'Snack',
      };
}

extension MealUnitLabel on MealUnit {
  String get label => switch (this) {
        MealUnit.grams => 'g',
        MealUnit.millilitres => 'ml',
        MealUnit.servings => 'servings',
        MealUnit.pieces => 'pieces',
      };
}

extension MealNutrientLabel on NutrientKey {
  String get label => switch (this) {
        NutrientKey.energyKcal => 'Energy',
        NutrientKey.proteinG => 'Protein',
        NutrientKey.fatG => 'Fat',
        NutrientKey.saturatedFatG => 'Saturated fat',
        NutrientKey.carbohydrateG => 'Carbs',
        NutrientKey.fiberG => 'Fibre',
        NutrientKey.sugarsG => 'Sugars',
        NutrientKey.sodiumMg => 'Sodium',
      };
}

MealSlot mealSlotFor(String intent, int hour) {
  final matches = MealSlot.values.where(
    (slot) =>
        RegExp('\\b${slot.name}\\b', caseSensitive: false).hasMatch(intent),
  );
  if (matches.length == 1) return matches.single;
  if (hour < 11) return MealSlot.breakfast;
  if (hour < 15) return MealSlot.lunch;
  if (hour < 18) return MealSlot.snack;
  return MealSlot.dinner;
}

/// Small local date grammar. The shown calendar selection is authoritative.
DiaryDate? mealDateFromIntent(String intent, DiaryDate today) {
  final days = mealDatesFromIntent(intent, today);
  return days.length == 1 ? days.single : null;
}

Set<DiaryDate> mealDatesFromIntent(String intent, DiaryDate today) {
  final days = <DiaryDate>{};
  if (RegExp(r'\b(today|hoje)\b', caseSensitive: false).hasMatch(intent)) {
    days.add(today);
  }
  if (RegExp(r'\b(yesterday|ontem)\b', caseSensitive: false).hasMatch(intent)) {
    days.add(today.addDays(-1));
  }
  const names = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday'
  ];
  for (final (index, name) in names.indexed) {
    if (RegExp('\\b$name\\b', caseSensitive: false).hasMatch(intent)) {
      final delta = (today.localMidnight.weekday - index - 1) % 7;
      days.add(today.addDays(-delta));
    }
  }
  for (final match in RegExp(r'\b\d{4}-\d{2}-\d{2}\b').allMatches(intent)) {
    try {
      final explicit = DiaryDate.parse(match[0]!);
      if (explicit.compareTo(today) <= 0) days.add(explicit);
    } on ArgumentError {
      // The calendar control remains available for invalid dates.
    }
  }
  return days;
}

double? mealNumber(String text) {
  final number = double.tryParse(text.trim().replaceAll(',', '.'));
  return number != null && number.isFinite ? number : null;
}

String mealNumberText(double value) {
  if (value == 0) return '0';
  if (value.abs() < 0.01 || value.abs() >= 1e7) {
    return value.toStringAsPrecision(3);
  }
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

String? mealPortionText(MealPortion? portion) => portion == null
    ? null
    : '${mealNumberText(portion.amount)} ${portion.unit.label}';

bool sameMealPortion(MealPortion? a, MealPortion? b) =>
    a?.amount == b?.amount && a?.unit == b?.unit;

NutrientProfile? _tryScale(NutrientProfile profile, double factor) {
  if (!factor.isFinite || factor <= 0) return null;
  try {
    return profile.scaled(factor);
  } on ArgumentError {
    return null;
  }
}

/// The logged profile is as-consumed. Only the same food with compatible old
/// and new portions can reuse it. A renamed food does not inherit its evidence.
PhotoMealItem reviseMealItem(
  PhotoMealItem original,
  String name,
  MealPortion? portion,
) {
  if (name.toLowerCase() != original.name.trim().toLowerCase()) {
    return PhotoMealItem(id: original.id, name: name, portion: portion);
  }
  final before = original.portion;
  if (sameMealPortion(before, portion)) return original.copyWith(name: name);
  final nutrients =
      before != null && portion != null && before.unit == portion.unit
          ? _tryScale(original.nutrients, portion.amount / before.amount)
          : null;
  // Construct explicitly so an absent portion or source really is cleared.
  return PhotoMealItem(
    id: original.id,
    name: name,
    portion: portion,
    nutrients: nutrients,
    labelPaths: original.labelPaths,
    source: nutrients?.hasAnyKnownValue == true ? original.source : null,
    reviewIssues: nutrients != null ? original.reviewIssues : const [],
  );
}

PhotoMealItem catalogueMealItem(Food food, MealPortion? portion) {
  final quantity = switch (portion?.unit) {
    MealUnit.grams => MassQuantity(portion!.amount),
    MealUnit.millilitres => VolumeQuantity(portion!.amount),
    MealUnit.pieces => PieceQuantity(portion!.amount),
    MealUnit.servings || null => null,
  };
  final resolved =
      quantity == null ? null : resolveQuantity(quantity, food.portions);
  final nutrients = resolved is ResolvedMass
      ? _tryScale(food.per100g, resolved.grams / 100)
      : null;
  return PhotoMealItem(
    name: food.name,
    portion: portion,
    nutrients: nutrients,
    source: nutrients?.hasAnyKnownValue == true
        ? 'catalogue:${food.source.dataset}'
        : null,
  );
}

NutrientProfile? scaleMealLabel(
  NutrientProfile label,
  MealPortion declared,
  MealPortion? consumed,
) {
  if (consumed == null || consumed.unit != declared.unit) return null;
  return _tryScale(label, consumed.amount / declared.amount);
}

String mealNutrientDetails(NutrientProfile profile) {
  final known = profile.knownKeys;
  if (known.isEmpty) return 'Nutrition unknown';
  return [
    for (final key in known)
      '${key.label}: ${switch (profile[key]) {
        NutrientEstimated(:final value) =>
          '≈${mealNumberText(value)} ${key.unit}',
        NutrientMeasured(:final value) =>
          '${mealNumberText(value)} ${key.unit}',
        NutrientReported(:final value) =>
          '${mealNumberText(value)} ${key.unit} (reported)',
        NutrientTrace() => 'trace',
        NutrientUnknown() => 'unknown',
      }}',
    if (known.length < NutrientKey.values.length) 'Other nutrients unknown',
  ].join(' · ');
}

String mealTotalDetails(List<PhotoMealItem> items) {
  final totals = <String>[];
  for (final key in NutrientKey.values) {
    var sum = NutrientSum.zero;
    var hasData = false;
    for (final item in items) {
      final value = item.nutrients[key];
      hasData |= value.isKnown;
      sum = sum.adding(value);
    }
    if (!hasData || !sum.value.isFinite) continue;
    totals.add(
      '${key.label}: ${sum.includesEstimate ? '≈' : ''}'
      '${mealNumberText(sum.value)} ${key.unit}'
      '${sum.isComplete ? '' : ' (partial)'}'
      '${sum.includesTrace ? ' (includes trace)' : ''}',
    );
  }
  if (totals.isEmpty) return 'Nutrition unknown';
  if (totals.length < NutrientKey.values.length) {
    totals.add('Other nutrients unknown');
  }
  return totals.join(' · ');
}

String mealNutritionIssueText(NutritionIssue issue) {
  final nutrient = issue.nutrient;
  return switch (issue.code) {
    'invalidValue' => nutrient != null
        ? '${nutrient.label} had an invalid value and was left unknown.'
        : 'An invalid nutrition value was left unknown.',
    'absoluteLimit' => nutrient != null
        ? '${nutrient.label} exceeded plausibility limits and was left unknown. Review or enter manually.'
        : 'A value exceeded plausibility limits and was left unknown.',
    'massInconsistent' => nutrient != null
        ? '${nutrient.label} exceeded the portion weight and was left unknown. Review or enter manually.'
        : 'A value exceeded the portion weight and was left unknown.',
    'macroEnergyMismatch' =>
      'Reported energy differs substantially from protein, carbs, fat, and fibre. Review before relying on it.',
    _ => nutrient != null
        ? '${nutrient.label} needs review (${issue.code}).'
        : 'Nutrition needs review (${issue.code}).',
  };
}
