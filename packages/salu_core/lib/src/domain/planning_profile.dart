import 'nutrients.dart';

enum WeightUnit {
  kilograms,
  pounds,
}

class FoodPreferences {
  const FoodPreferences({
    this.likes = '',
    this.dislikes = '',
    this.exclusions = '',
    this.strictAllergens = '',
  });

  factory FoodPreferences.fromJson(Map<String, dynamic> json) =>
      FoodPreferences(
        likes: json['likes'] as String? ?? '',
        dislikes: json['dislikes'] as String? ?? '',
        exclusions: json['exclusions'] as String? ?? '',
        strictAllergens: json['strictAllergens'] as String? ?? '',
      );

  final String likes;
  final String dislikes;
  final String exclusions;
  final String strictAllergens;

  List<String> get exclusionItems => _terms(exclusions);
  List<String> get allergenItems => _terms(strictAllergens);
  List<String> get dislikeItems => _terms(dislikes);
  static List<String> _terms(String value) => value
      .split(RegExp(r'[,;\n]'))
      .map((term) => term.trim())
      .where((term) => term.isNotEmpty)
      .toList(growable: false);

  Map<String, String> toJson() => {
        'likes': likes,
        'dislikes': dislikes,
        'exclusions': exclusions,
        'strictAllergens': strictAllergens,
      };
}

void _validatePositiveFinite(double? value, String name) {
  if (value != null && (!value.isFinite || value <= 0)) {
    throw ArgumentError.value(value, name, 'must be finite and > 0');
  }
}

double? _readOptionalDouble(Map<String, dynamic> json, String key) {
  final raw = json[key];
  if (raw == null) return null;
  if (raw is! num) {
    throw FormatException('Expected numeric value for $key', raw);
  }
  final value = raw.toDouble();
  _validatePositiveFinite(value, key);
  return value;
}

/// User-declared information only. Null weight represents an unfilled profile.
class PlanningProfile {
  const PlanningProfile({
    this.startingWeight,
    this.weightUnit = WeightUnit.kilograms,
    this.energyGoal = '',
    this.dailyEnergyKcal,
    this.proteinGrams,
    this.carbohydrateGrams,
    this.fatGrams,
    this.habitualActivity = '',
    this.preferences = const FoodPreferences(),
    this.onboarded = false,
  });

  factory PlanningProfile.fromJson(Map<String, dynamic> json) {
    final rawPrefs = json['preferences'];
    final prefsMap = switch (rawPrefs) {
      null => const <String, dynamic>{},
      Map<String, dynamic>() => rawPrefs,
      Map() => Map<String, dynamic>.from(rawPrefs),
      _ => throw FormatException('Expected map for preferences', rawPrefs),
    };
    return PlanningProfile(
      startingWeight: _readOptionalDouble(json, 'startingWeight'),
      weightUnit: WeightUnit.values.byName(
        json['weightUnit'] as String? ?? WeightUnit.kilograms.name,
      ),
      energyGoal: json['energyGoal'] as String? ?? '',
      dailyEnergyKcal: _readOptionalDouble(json, 'dailyEnergyKcal'),
      proteinGrams: _readOptionalDouble(json, 'proteinGrams'),
      carbohydrateGrams: _readOptionalDouble(json, 'carbohydrateGrams'),
      fatGrams: _readOptionalDouble(json, 'fatGrams'),
      habitualActivity: json['habitualActivity'] as String? ?? '',
      preferences: FoodPreferences.fromJson(prefsMap),
      onboarded: json['onboarded'] as bool? ?? json['startingWeight'] != null,
    );
  }

  final double? startingWeight;
  final WeightUnit weightUnit;
  final String energyGoal;
  final double? dailyEnergyKcal;
  final double? proteinGrams, carbohydrateGrams, fatGrams;
  final String habitualActivity;
  final FoodPreferences preferences;
  final bool onboarded;

  void validate() {
    _validatePositiveFinite(startingWeight, 'startingWeight');
    _validatePositiveFinite(dailyEnergyKcal, 'dailyEnergyKcal');
    _validatePositiveFinite(proteinGrams, 'proteinGrams');
    _validatePositiveFinite(carbohydrateGrams, 'carbohydrateGrams');
    _validatePositiveFinite(fatGrams, 'fatGrams');
  }

  PlanningProfile copyWith({
    double? startingWeight,
    WeightUnit? weightUnit,
    String? energyGoal,
    double? dailyEnergyKcal,
    double? proteinGrams,
    double? carbohydrateGrams,
    double? fatGrams,
    String? habitualActivity,
    FoodPreferences? preferences,
    bool? onboarded,
  }) =>
      PlanningProfile(
        startingWeight: startingWeight ?? this.startingWeight,
        weightUnit: weightUnit ?? this.weightUnit,
        energyGoal: energyGoal ?? this.energyGoal,
        dailyEnergyKcal: dailyEnergyKcal ?? this.dailyEnergyKcal,
        proteinGrams: proteinGrams ?? this.proteinGrams,
        carbohydrateGrams: carbohydrateGrams ?? this.carbohydrateGrams,
        fatGrams: fatGrams ?? this.fatGrams,
        habitualActivity: habitualActivity ?? this.habitualActivity,
        preferences: preferences ?? this.preferences,
        onboarded: onboarded ?? this.onboarded,
      );

  Map<NutrientKey, double> get targets => {
        if (dailyEnergyKcal case final value?) NutrientKey.energyKcal: value,
        if (proteinGrams case final value?) NutrientKey.proteinG: value,
        if (carbohydrateGrams case final value?)
          NutrientKey.carbohydrateG: value,
        if (fatGrams case final value?) NutrientKey.fatG: value,
      };

  Map<String, Object?> toJson() => {
        'startingWeight': startingWeight,
        'weightUnit': weightUnit.name,
        'energyGoal': energyGoal,
        'dailyEnergyKcal': dailyEnergyKcal,
        'proteinGrams': proteinGrams,
        'carbohydrateGrams': carbohydrateGrams,
        'fatGrams': fatGrams,
        'habitualActivity': habitualActivity,
        'preferences': preferences.toJson(),
        'onboarded': onboarded,
      };
}
