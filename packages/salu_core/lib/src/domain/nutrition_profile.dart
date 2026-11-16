library;

import 'health_declarations.dart';
import 'nutrition_contract.dart';

/// The guided-experience profile: routine, household and food choices made
/// once, before any meal plan exists.
///
/// This is the calculation input the starting-estimate service reads. It is
/// deliberately separate from [SafetyProfile] (declarations only) and from the
/// health-declaration document (goal plus optional condition flags): routine
/// answers, measurements and food preferences live here and nowhere else.
///
/// Nothing here is inferred. Measurements, the equation branch and the
/// activity level are absent or positive finite values supplied by the user;
/// a missing calculation input is reported by the estimate service as
/// [TargetEstimateException] `TARGET_INPUT_REQUIRED` with the exact profile
/// field names, never guessed. No field carries a clinical/age/population
/// approval that decides availability, and a declaration never suspends the
/// ability to calculate an estimate from complete inputs.
///
/// Meal labels are the ordered schedule categories below; meal planning may
/// only schedule a recipe under a label it actually declares.

final class NutritionProfile {
  static const int schemaVersion = 1;

  /// Meal categories a guided plan may use, in schedule order.
  static const List<String> allowedMealLabels = [
    'breakfast',
    'lunch',
    'snack',
    'dinner'
  ];

  static const List<String> budgets = ['lowerCost', 'standard', 'flexible'];

  /// Explicitly selectable activity levels; anything else is rejected rather
  /// than mapped silently.
  static final List<Exact> activityLevels = [
    Exact.parse('1.4'),
    Exact.parse('1.6'),
    Exact.parse('1.8'),
    Exact.parse('2.0'),
  ];

  static const List<String> defaultMealLabels = [
    'breakfast',
    'lunch',
    'dinner'
  ];

  NutritionProfile({
    required this.goal,
    this.ageYears,
    this.heightCm,
    this.weightKg,
    this.equationConstant,
    this.activityPal,
    List<String> mealLabels = defaultMealLabels,
    this.maximumCookingMinutes = 30,
    this.coldLunches = false,
    this.budget = 'standard',
    this.householdServings = 1,
    Set<String> dietaryTags = const {},
    Set<String> avoidedFoodIds = const {},
    Set<String> likedRecipeIds = const {},
    Set<String> dislikedRecipeIds = const {},
    this.preferVariety = false,
  })  : mealLabels = List.unmodifiable(mealLabels),
        dietaryTags = Set.unmodifiable(dietaryTags),
        avoidedFoodIds = Set.unmodifiable(avoidedFoodIds),
        likedRecipeIds = Set.unmodifiable(likedRecipeIds),
        dislikedRecipeIds = Set.unmodifiable(dislikedRecipeIds) {
    if (ageYears != null && ageYears! <= 0) {
      throw ArgumentError('ageYears must be positive');
    }
    if (heightCm != null && !heightCm!.positive) {
      throw ArgumentError('heightCm must be positive');
    }
    if (weightKg != null && !weightKg!.positive) {
      throw ArgumentError('weightKg must be positive');
    }
    if (equationConstant != null &&
        equationConstant != 5 &&
        equationConstant != -161) {
      throw ArgumentError('equationConstant must be 5 or -161');
    }
    if (activityPal != null &&
        !activityLevels.any((level) => level == activityPal)) {
      throw ArgumentError('activityPal must be an explicit level');
    }
    if (this.mealLabels.isEmpty ||
        this.mealLabels.length != this.mealLabels.toSet().length ||
        this.mealLabels.any((label) => !NutritionProfile.allowedMealLabels.contains(label))) {
      throw ArgumentError('mealLabels must be unique scheduled labels');
    }
    if (maximumCookingMinutes != null && maximumCookingMinutes! <= 0) {
      throw ArgumentError('maximumCookingMinutes must be positive');
    }
    if (!budgets.contains(budget)) {
      throw ArgumentError('Unknown budget');
    }
    if (householdServings <= 0) {
      throw ArgumentError('householdServings must be positive');
    }
  }

  final AdultGoal goal;
  final int? ageYears;
  final Exact? heightCm;
  final Exact? weightKg;

  /// The Mifflin–St Jeor branch constant the user selected: `5` or `-161`.
  final int? equationConstant;
  final Exact? activityPal;
  final List<String> mealLabels;
  final int? maximumCookingMinutes;
  final bool coldLunches;
  final String budget;
  final int householdServings;
  final Set<String> dietaryTags;
  final Set<String> avoidedFoodIds;
  final Set<String> likedRecipeIds;
  final Set<String> dislikedRecipeIds;
  final bool preferVariety;

  static const Object _unset = Object();

  NutritionProfile copyWith({
    AdultGoal? goal,
    Object? ageYears = _unset,
    Object? heightCm = _unset,
    Object? weightKg = _unset,
    Object? equationConstant = _unset,
    Object? activityPal = _unset,
    List<String>? mealLabels,
    Object? maximumCookingMinutes = _unset,
    bool? coldLunches,
    String? budget,
    int? householdServings,
    Set<String>? dietaryTags,
    Set<String>? avoidedFoodIds,
    Set<String>? likedRecipeIds,
    Set<String>? dislikedRecipeIds,
    bool? preferVariety,
  }) =>
      NutritionProfile(
        goal: goal ?? this.goal,
        ageYears: identical(ageYears, _unset)
            ? this.ageYears
            : ageYears as int?,
        heightCm: identical(heightCm, _unset)
            ? this.heightCm
            : heightCm as Exact?,
        weightKg: identical(weightKg, _unset)
            ? this.weightKg
            : weightKg as Exact?,
        equationConstant: identical(equationConstant, _unset)
            ? this.equationConstant
            : equationConstant as int?,
        activityPal: identical(activityPal, _unset)
            ? this.activityPal
            : activityPal as Exact?,
        mealLabels: mealLabels ?? this.mealLabels,
        maximumCookingMinutes: identical(maximumCookingMinutes, _unset)
            ? this.maximumCookingMinutes
            : maximumCookingMinutes as int?,
        coldLunches: coldLunches ?? this.coldLunches,
        budget: budget ?? this.budget,
        householdServings: householdServings ?? this.householdServings,
        dietaryTags: dietaryTags ?? this.dietaryTags,
        avoidedFoodIds: avoidedFoodIds ?? this.avoidedFoodIds,
        likedRecipeIds: likedRecipeIds ?? this.likedRecipeIds,
        dislikedRecipeIds: dislikedRecipeIds ?? this.dislikedRecipeIds,
        preferVariety: preferVariety ?? this.preferVariety,
      );

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'goal': goal.name,
        'ageYears': ageYears,
        'heightCm': heightCm?.toJson(),
        'weightKg': weightKg?.toJson(),
        'equationConstant': equationConstant,
        'activityPal': activityPal?.toJson(),
        'mealLabels': mealLabels,
        'maximumCookingMinutes': maximumCookingMinutes,
        'coldLunches': coldLunches,
        'budget': budget,
        'householdServings': householdServings,
        'dietaryTags': dietaryTags.toList(),
        'avoidedFoodIds': avoidedFoodIds.toList(),
        'likedRecipeIds': likedRecipeIds.toList(),
        'dislikedRecipeIds': dislikedRecipeIds.toList(),
        'preferVariety': preferVariety,
      };

  factory NutritionProfile.fromJson(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    if (version != null && version != 1) {
      throw const FormatException('Unsupported nutrition profile version');
    }
    final goalValue = json['goal'];
    final goal = goalValue is String ? AdultGoal.byNameOrNull(goalValue) : null;
    if (goal == null) {
      throw const FormatException('Invalid nutrition profile goal');
    }
    Exact? amount(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! Map) throw FormatException('Invalid $key');
      return Exact.fromJson(Map<String, Object?>.from(value));
    }

    Set<String> ids(String key) {
      final value = json[key];
      if (value == null) return const {};
      if (value is! List || value.any((entry) => entry is! String)) {
        throw FormatException('Invalid $key');
      }
      return value.cast<String>().toSet();
    }

    final labelsValue = json['mealLabels'];
    final labels = labelsValue == null
        ? defaultMealLabels
        : (labelsValue is List &&
                labelsValue.every((entry) => entry is String))
            ? labelsValue.cast<String>()
            : throw const FormatException('Invalid mealLabels');

    final cookingValue = json['maximumCookingMinutes'];
    final budgetValue = json['budget'];
    final householdValue = json['householdServings'];
    return NutritionProfile(
      goal: goal,
      ageYears: json['ageYears'] == null
          ? null
          : (json['ageYears'] is int
              ? json['ageYears']! as int
              : throw const FormatException('Invalid ageYears')),
      heightCm: amount('heightCm'),
      weightKg: amount('weightKg'),
      equationConstant: json['equationConstant'] == null
          ? null
          : (json['equationConstant'] is int
              ? json['equationConstant']! as int
              : throw const FormatException('Invalid equationConstant')),
      activityPal: amount('activityPal'),
      mealLabels: labels,
      maximumCookingMinutes: cookingValue == null
          ? 30
          : (cookingValue is int
              ? cookingValue
              : throw const FormatException('Invalid maximumCookingMinutes')),
      coldLunches: json['coldLunches'] == true,
      budget: budgetValue == null
          ? 'standard'
          : (budgetValue is String
              ? budgetValue
              : throw const FormatException('Invalid budget')),
      householdServings: householdValue == null
          ? 1
          : (householdValue is int
              ? householdValue
              : throw const FormatException('Invalid householdServings')),
      dietaryTags: ids('dietaryTags'),
      avoidedFoodIds: ids('avoidedFoodIds'),
      likedRecipeIds: ids('likedRecipeIds'),
      dislikedRecipeIds: ids('dislikedRecipeIds'),
      preferVariety: json['preferVariety'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NutritionProfile &&
      other.goal == goal &&
      other.ageYears == ageYears &&
      other.heightCm == heightCm &&
      other.weightKg == weightKg &&
      other.equationConstant == equationConstant &&
      other.activityPal == activityPal &&
      _orderedEquals(other.mealLabels, mealLabels) &&
      other.maximumCookingMinutes == maximumCookingMinutes &&
      other.coldLunches == coldLunches &&
      other.budget == budget &&
      other.householdServings == householdServings &&
      other.dietaryTags.length == dietaryTags.length &&
      other.dietaryTags.containsAll(dietaryTags) &&
      other.avoidedFoodIds.length == avoidedFoodIds.length &&
      other.avoidedFoodIds.containsAll(avoidedFoodIds) &&
      other.likedRecipeIds.length == likedRecipeIds.length &&
      other.likedRecipeIds.containsAll(likedRecipeIds) &&
      other.dislikedRecipeIds.length == dislikedRecipeIds.length &&
      other.dislikedRecipeIds.containsAll(dislikedRecipeIds) &&
      other.preferVariety == preferVariety;

  @override
  int get hashCode => Object.hashAll([
        goal,
        ageYears,
        heightCm,
        weightKg,
        equationConstant,
        activityPal,
        Object.hashAll(mealLabels),
        maximumCookingMinutes,
        coldLunches,
        budget,
        householdServings,
        Object.hashAllUnordered(dietaryTags),
        Object.hashAllUnordered(avoidedFoodIds),
        Object.hashAllUnordered(likedRecipeIds),
        Object.hashAllUnordered(dislikedRecipeIds),
        preferVariety,
      ]);

  static bool _orderedEquals(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}
