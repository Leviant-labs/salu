import 'dart:io';

import 'package:salu_data/salu_data.dart';

import '../onboarding/local_json_file.dart';

enum MealSlot {
  breakfast('Breakfast'),
  lunch('Lunch'),
  dinner('Dinner');

  const MealSlot(this.label);

  final String label;
}

typedef MealPosition = ({int day, MealSlot slot});

/// Calendar dates use UTC as a date-only representation so that stepping a
/// day or week never depends on the length of a local daylight-saving day.
DateTime startOfPlanWeek(DateTime localDate) => DateTime.utc(
      localDate.year,
      localDate.month,
      localDate.day,
    ).subtract(Duration(days: localDate.weekday - DateTime.monday));

class PlannedMeal {
  const PlannedMeal(this.name,
      {this.details = '', this.recipeKey, this.servings, this.pinned = false});

  factory PlannedMeal.fromJson(Map<String, dynamic> json) =>
      PlannedMeal(json['name'] as String,
          details: json['details'] as String,
          recipeKey: json['recipeKey'] as String?,
          servings: (json['servings'] as num?)?.toDouble(),
          pinned: json['pinned'] as bool? ?? false);

  final String name;
  final String details;
  final String? recipeKey;
  final double? servings;
  final bool pinned;

  Map<String, Object> toJson() => {
        'name': name,
        'details': details,
        if (recipeKey != null) 'recipeKey': recipeKey!,
        if (servings != null) 'servings': servings!,
        'pinned': pinned
      };
}

class GroceryItem {
  const GroceryItem(this.name,
      {this.amount = '',
      this.checked = false,
      this.requirementKey,
      this.requiredGrams,
      this.override = false,
      this.changed = false});

  factory GroceryItem.fromJson(Map<String, dynamic> json) => GroceryItem(
        json['name'] as String,
        amount: json['amount'] as String,
        checked: json['checked'] as bool,
        requirementKey: json['requirementKey'] as String?,
        requiredGrams: (json['requiredGrams'] as num?)?.toDouble(),
        override: json['override'] as bool? ?? false,
        changed: json['changed'] as bool? ?? false,
      );

  final String name;
  final String amount;
  final bool checked;
  final String? requirementKey;
  final double? requiredGrams;
  final bool override, changed;

  String get nameKey =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  GroceryItem withChecked(bool value) => GroceryItem(name,
      amount: amount,
      checked: value,
      requirementKey: requirementKey,
      requiredGrams: requiredGrams,
      override: override);

  Map<String, Object> toJson() => {
        'name': name,
        'amount': amount,
        'checked': checked,
        if (requirementKey != null) 'requirementKey': requirementKey!,
        if (requiredGrams != null) 'requiredGrams': requiredGrams!,
        if (override) 'override': true,
        if (changed) 'changed': true,
      };
}

class WeekPlan {
  WeekPlan(
    this.monday, {
    Map<MealPosition, PlannedMeal> meals = const {},
    List<GroceryItem> groceries = const [],
    this.revision = 0,
  })  : meals = Map.unmodifiable(meals),
        groceries = List.unmodifiable(groceries);

  factory WeekPlan.fromJson(DateTime monday, Map<String, dynamic> json,
      {int revision = 0}) {
    final meals = <MealPosition, PlannedMeal>{};
    for (final raw in json['meals'] as List<dynamic>) {
      final row = raw as Map<String, dynamic>;
      final day = row['day'] as int;
      final slot = MealSlot.values.byName(row['slot'] as String);
      if (day < 0 || day >= 7 || meals.containsKey((day: day, slot: slot))) {
        throw const FormatException('Invalid saved meal position');
      }
      meals[(day: day, slot: slot)] = PlannedMeal.fromJson(row);
    }
    return WeekPlan(
      monday,
      revision: revision,
      meals: meals,
      groceries: (json['groceries'] as List<dynamic>)
          .map((raw) => GroceryItem.fromJson(raw as Map<String, dynamic>))
          .toList(),
    );
  }

  final DateTime monday;
  final int revision;
  final Map<MealPosition, PlannedMeal> meals;
  final List<GroceryItem> groceries;

  DateTime dateFor(int day) => monday.add(Duration(days: day));

  WeekPlan copyWith({
    Map<MealPosition, PlannedMeal>? meals,
    List<GroceryItem>? groceries,
    int? revision,
  }) =>
      WeekPlan(
        monday,
        revision: revision ?? this.revision,
        meals: meals ?? this.meals,
        groceries: groceries ?? this.groceries,
      );

  Map<String, Object> toJson() => {
        'meals': [
          for (final entry in meals.entries)
            {
              'day': entry.key.day,
              'slot': entry.key.slot.name,
              ...entry.value.toJson(),
            },
        ],
        'groceries': groceries.map((item) => item.toJson()).toList(),
      };
}

class WeekPlanStore {
  WeekPlanStore(
      {Future<Directory> Function()? directory, LocalDocumentStore? documents})
      : _directory = directory,
        _documents = documents;

  static final local = WeekPlanStore();

  final Future<Directory> Function()? _directory;
  final LocalDocumentStore? _documents;
  String _key(DateTime week) =>
      'week:${week.toIso8601String().substring(0, 10)}';
  final _files = <DateTime, LocalJsonFile>{};

  LocalJsonFile _file(DateTime week) => _files.putIfAbsent(week, () {
        final filename =
            'week_plan_v1_${week.year}-${week.month}-${week.day}.json';
        final directory = _directory;
        return directory == null
            ? LocalJsonFile(filename)
            : LocalJsonFile(filename, directory: directory);
      });

  Future<WeekPlan> load(DateTime monday) async {
    final docs = _documents;
    if (docs != null) {
      final saved = await docs.read(_key(monday));
      if (saved != null) {
        return WeekPlan.fromJson(monday, saved.data, revision: saved.revision);
      }
    }
    final data = await _file(monday).read();
    if (data == null) return WeekPlan(monday);
    final legacy = WeekPlan.fromJson(monday, data);
    if (docs == null) return legacy;
    await docs.put(_key(monday), 0, legacy.toJson());
    final migrated = (await docs.read(_key(monday)))!;
    return WeekPlan.fromJson(monday, migrated.data,
        revision: migrated.revision);
  }

  Future<void> save(WeekPlan plan) async {
    final docs = _documents;
    if (docs != null) {
      if (!await docs.put(_key(plan.monday), plan.revision, plan.toJson())) {
        throw StateError('This week changed. Reload before saving.');
      }
      return;
    }
    await _file(plan.monday).update((saved) {
      if (saved != null) WeekPlan.fromJson(plan.monday, saved);
      return plan.toJson();
    });
  }
}
