import 'dart:io';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'local_json_file.dart';

enum WeightUnit {
  kilograms('kg'),
  pounds('lb');

  const WeightUnit(this.label);

  final String label;
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

  factory PlanningProfile.fromJson(Map<String, dynamic> json) =>
      PlanningProfile(
        startingWeight: (json['startingWeight'] as num?)?.toDouble(),
        weightUnit: WeightUnit.values.byName(
          json['weightUnit'] as String? ?? WeightUnit.kilograms.name,
        ),
        energyGoal: json['energyGoal'] as String? ?? '',
        dailyEnergyKcal: (json['dailyEnergyKcal'] as num?)?.toDouble(),
        proteinGrams: (json['proteinGrams'] as num?)?.toDouble(),
        carbohydrateGrams: (json['carbohydrateGrams'] as num?)?.toDouble(),
        fatGrams: (json['fatGrams'] as num?)?.toDouble(),
        habitualActivity: json['habitualActivity'] as String? ?? '',
        preferences: FoodPreferences.fromJson(
          json['preferences'] as Map<String, dynamic>? ?? const {},
        ),
        onboarded: json['onboarded'] as bool? ?? json['startingWeight'] != null,
      );

  final double? startingWeight;
  final WeightUnit weightUnit;
  final String energyGoal;
  final double? dailyEnergyKcal;
  final double? proteinGrams, carbohydrateGrams, fatGrams;
  final String habitualActivity;
  final FoodPreferences preferences;
  final bool onboarded;

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

class PlanningProfileStore {
  PlanningProfileStore(
      {Future<Directory> Function()? directory, LocalDocumentStore? documents})
      : _file = directory == null
            ? LocalJsonFile('planning_profile_v1.json')
            : LocalJsonFile('planning_profile_v1.json', directory: directory),
        _documents = documents;

  static final local = PlanningProfileStore();

  final LocalJsonFile _file;
  final LocalDocumentStore? _documents;
  static const _key = 'planning-profile';

  Future<PlanningProfile> load() async {
    final docs = _documents;
    if (docs == null) {
      return PlanningProfile.fromJson(await _file.read() ?? const {});
    }
    final stored = await docs.read(_key);
    if (stored != null) return PlanningProfile.fromJson(stored.data);
    final legacy = await _file.read();
    if (legacy == null) return const PlanningProfile();
    final profile = PlanningProfile.fromJson(legacy);
    if (await docs.put(_key, 0, profile.toJson())) return profile;
    return PlanningProfile.fromJson((await docs.read(_key))!.data);
  }

  Future<void> save(PlanningProfile profile) =>
      _update((_) => profile.toJson());

  Future<void> savePreferences(FoodPreferences preferences) => _update(
        (saved) => {
          ...PlanningProfile.fromJson(saved ?? const {}).toJson(),
          'preferences': preferences.toJson(),
        },
      );

  Future<void> skipOnboarding() => _update((saved) => {
        ...PlanningProfile.fromJson(saved ?? const {}).toJson(),
        'onboarded': true,
      });

  Future<void> _update(
      Map<String, Object?> Function(Map<String, dynamic>?) change) async {
    final docs = _documents;
    if (docs == null) return _file.update(change);
    await load();
    final old = await docs.read(_key);
    if (!await docs.put(_key, old?.revision ?? 0, change(old?.data))) {
      throw StateError('The profile changed while saving');
    }
  }
}
