import 'dart:io';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'local_json_file.dart';

export 'package:salu_core/salu_core.dart'
    show
        AllergenId,
        AllergenIdLabel,
        FoodPreferences,
        PlanningProfile,
        WeightUnit,
        resolveAllergen,
        resolveStrictAllergens;

extension WeightUnitLabel on WeightUnit {
  String get label => switch (this) {
        WeightUnit.kilograms => 'kg',
        WeightUnit.pounds => 'lb',
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
