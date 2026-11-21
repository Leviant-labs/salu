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

  factory PlannedMeal.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final details = json['details'];
    final recipeKey = json['recipeKey'];
    final rawServings = json['servings'];
    final pinned = json['pinned'];
    if (name is! String || details is! String) {
      throw FormatException('Invalid planned meal payload', json);
    }
    if (recipeKey != null && recipeKey is! String) {
      throw FormatException('Invalid planned meal recipeKey', recipeKey);
    }
    if (rawServings != null &&
        (rawServings is! num || !rawServings.isFinite || rawServings <= 0)) {
      throw FormatException('Invalid planned meal servings', rawServings);
    }
    if (pinned != null && pinned is! bool) {
      throw FormatException('Invalid planned meal pinned flag', pinned);
    }
    return PlannedMeal(
      name,
      details: details,
      recipeKey: recipeKey as String?,
      servings: (rawServings as num?)?.toDouble(),
      pinned: pinned as bool? ?? false,
    );
  }

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

  factory GroceryItem.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final amount = json['amount'];
    final checked = json['checked'];
    final requirementKey = json['requirementKey'];
    final rawGrams = json['requiredGrams'];
    final override = json['override'];
    final changed = json['changed'];
    if (name is! String || amount is! String || checked is! bool) {
      throw FormatException('Invalid grocery item payload', json);
    }
    if (requirementKey != null && requirementKey is! String) {
      throw FormatException('Invalid grocery requirementKey', requirementKey);
    }
    if (rawGrams != null &&
        (rawGrams is! num || !rawGrams.isFinite || rawGrams < 0)) {
      throw FormatException('Invalid grocery requiredGrams', rawGrams);
    }
    if ((override != null && override is! bool) ||
        (changed != null && changed is! bool)) {
      throw FormatException('Invalid grocery flags', json);
    }
    return GroceryItem(
      name,
      amount: amount,
      checked: checked,
      requirementKey: requirementKey as String?,
      requiredGrams: (rawGrams as num?)?.toDouble(),
      override: override as bool? ?? false,
      changed: changed as bool? ?? false,
    );
  }

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
  static const int currentVersion = 1;

  WeekPlan(
    this.monday, {
    Map<MealPosition, PlannedMeal> meals = const {},
    List<GroceryItem> groceries = const [],
    this.revision = 0,
  })  : meals = Map.unmodifiable(meals),
        groceries = List.unmodifiable(groceries);

  factory WeekPlan.fromJson(DateTime monday, Map<String, dynamic> json,
      {int revision = 0}) {
    isCurrentDocumentVersion(json, currentVersion, documentName: 'week-plan');
    final rawMeals = json['meals'];
    final rawGroceries = json['groceries'];
    if (rawMeals is! List || rawGroceries is! List) {
      throw FormatException('Invalid week-plan payload', json);
    }
    final meals = <MealPosition, PlannedMeal>{};
    for (final raw in rawMeals) {
      if (raw is! Map) {
        throw FormatException('Invalid planned meal row', raw);
      }
      final row = Map<String, dynamic>.from(raw);
      final day = row['day'];
      final rawSlot = row['slot'];
      if (day is! int || rawSlot is! String) {
        throw FormatException('Invalid saved meal position', row);
      }
      MealSlot? slot;
      for (final value in MealSlot.values) {
        if (value.name == rawSlot) {
          slot = value;
          break;
        }
      }
      if (slot == null ||
          day < 0 ||
          day >= 7 ||
          meals.containsKey((day: day, slot: slot))) {
        throw const FormatException('Invalid saved meal position');
      }
      meals[(day: day, slot: slot)] = PlannedMeal.fromJson(row);
    }
    return WeekPlan(
      monday,
      revision: revision,
      meals: meals,
      groceries: [
        for (final raw in rawGroceries)
          if (raw is Map)
            GroceryItem.fromJson(Map<String, dynamic>.from(raw))
          else
            throw FormatException('Invalid grocery row', raw),
      ],
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
        'version': currentVersion,
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
        final plan =
            WeekPlan.fromJson(monday, saved.data, revision: saved.revision);
        if (!isCurrentDocumentVersion(
          saved.data,
          WeekPlan.currentVersion,
          documentName: 'week-plan',
        )) {
          final migrated = <String, Object?>{
            ...saved.data,
            'version': WeekPlan.currentVersion,
          };
          if (await docs.put(_key(monday), saved.revision, migrated)) {
            return plan.copyWith(revision: saved.revision + 1);
          }
          final latest = await docs.read(_key(monday));
          if (latest != null) {
            return WeekPlan.fromJson(
              monday,
              latest.data,
              revision: latest.revision,
            );
          }
        }
        return plan;
      }
    }
    final data = await _file(monday).read();
    if (data == null) return WeekPlan(monday);
    final legacy = WeekPlan.fromJson(monday, data);
    if (docs == null) return legacy;
    await docs.put(_key(monday), 0, {...data, ...legacy.toJson()});
    final migrated = (await docs.read(_key(monday)))!;
    return WeekPlan.fromJson(monday, migrated.data,
        revision: migrated.revision);
  }

  Future<void> save(WeekPlan plan) async {
    final docs = _documents;
    if (docs != null) {
      final existing = await docs.read(_key(plan.monday));
      if (existing != null) {
        isCurrentDocumentVersion(
          existing.data,
          WeekPlan.currentVersion,
          documentName: 'week-plan',
        );
      }
      if (!await docs.put(_key(plan.monday), plan.revision, {
        ...?existing?.data,
        ...plan.toJson(),
      })) {
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
