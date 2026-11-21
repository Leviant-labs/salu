import '../domain/nutrients.dart';
import '../domain/photo_meal.dart';

/// Whether two meal portions have the same amount and unit.
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
