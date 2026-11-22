import '../domain/allergens.dart';
import '../domain/nutrients.dart';
import '../domain/photo_meal.dart';
import '../domain/planning_profile.dart';
import '../domain/recipes.dart';

/// Planning-specific meal slots for a weekly plan.
///
/// Kept distinct from diary intake [MealSlot]; use [toIntakeMealSlot] when
/// logging a planned meal into the diary.
enum PlanMealSlot {
  breakfast,
  lunch,
  dinner,
}

/// Converts a planning [PlanMealSlot] to the diary intake [MealSlot].
MealSlot toIntakeMealSlot(PlanMealSlot slot) => switch (slot) {
      PlanMealSlot.breakfast => MealSlot.breakfast,
      PlanMealSlot.lunch => MealSlot.lunch,
      PlanMealSlot.dinner => MealSlot.dinner,
    };

/// A day/slot coordinate in a weekly meal plan (`day` is `0..6` from Monday).
typedef PlanMealPosition = ({int day, PlanMealSlot slot});

/// Calendar dates use UTC as a date-only representation so that stepping a
/// day or week never depends on the length of a local daylight-saving day.
DateTime startOfPlanWeek(DateTime localDate) => DateTime.utc(
      localDate.year,
      localDate.month,
      localDate.day,
    ).subtract(Duration(days: localDate.weekday - DateTime.monday));

/// A meal planned for a specific slot in a [WeekPlan].
class PlannedMeal {
  /// Creates a planned meal.
  const PlannedMeal(
    this.name, {
    this.details = '',
    this.recipeKey,
    this.servings,
    this.pinned = false,
  });

  /// Parses a persisted [PlannedMeal] JSON object.
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
        'pinned': pinned,
      };
}

/// An item on a weekly shopping list.
class GroceryItem {
  /// Creates a grocery item.
  const GroceryItem(
    this.name, {
    this.amount = '',
    this.checked = false,
    this.requirementKey,
    this.requiredGrams,
    this.override = false,
    this.changed = false,
  });

  /// Parses a persisted [GroceryItem] JSON object.
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
  final bool override;
  final bool changed;

  String get nameKey =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  GroceryItem withChecked(bool value) => GroceryItem(
        name,
        amount: amount,
        checked: value,
        requirementKey: requirementKey,
        requiredGrams: requiredGrams,
        override: override,
      );

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

/// A week's meal plan and reconciled grocery list.
class WeekPlan {
  static const int currentVersion = 1;

  WeekPlan(
    this.monday, {
    Map<PlanMealPosition, PlannedMeal> meals = const {},
    List<GroceryItem> groceries = const [],
    this.revision = 0,
  })  : meals = Map.unmodifiable(meals),
        groceries = List.unmodifiable(groceries);

  factory WeekPlan.fromJson(
    DateTime monday,
    Map<String, dynamic> json, {
    int revision = 0,
  }) {
    if (json.containsKey('version') && json['version'] != currentVersion) {
      throw FormatException(
        'Unsupported week-plan version: ${json['version']}',
        json['version'],
      );
    }
    final rawMeals = json['meals'];
    final rawGroceries = json['groceries'];
    if (rawMeals is! List || rawGroceries is! List) {
      throw FormatException('Invalid week-plan payload', json);
    }
    final meals = <PlanMealPosition, PlannedMeal>{};
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
      PlanMealSlot? slot;
      for (final value in PlanMealSlot.values) {
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
  final Map<PlanMealPosition, PlannedMeal> meals;
  final List<GroceryItem> groceries;

  DateTime dateFor(int day) => monday.add(Duration(days: day));

  WeekPlan copyWith({
    Map<PlanMealPosition, PlannedMeal>? meals,
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

/// A conflict between a pinned meal and active profile allergens/exclusions.
final class PinnedMealConflict {
  const PinnedMealConflict({
    required this.position,
    required this.meal,
    required this.reasons,
  });

  final PlanMealPosition position;
  final PlannedMeal meal;
  final List<String> reasons;
}

/// Pure-Dart planning math: day nutrient totals, grocery reconciliation, and
/// pinned-meal conflict checks.
final class PlanService {
  const PlanService();

  /// Computes per-nutrient totals for [day] across [meals].
  Map<NutrientKey, RecipeTotal> dayTotals(
    Map<PlanMealPosition, PlannedMeal> meals,
    int day,
    Map<String, RecipeVersion> recipes,
  ) {
    final data = <NutrientProfile>[];
    for (final entry in meals.entries.where((entry) => entry.key.day == day)) {
      final recipe = recipes[entry.value.recipeKey];
      final amount = entry.value.servings;
      if (recipe == null || amount == null || !recipe.accepts(amount)) {
        data.add(const NutrientProfile.empty());
      } else {
        data.addAll(recipe.snapshot(amount).map((item) => item.nutrients));
      }
    }
    return {
      for (final key in NutrientKey.values)
        key: RecipeTotal.from(data.map((profile) => profile[key])),
    };
  }

  /// Reconciles [plan]'s grocery list against its planned recipes while
  /// preserving manual items, user overrides, and checked flags.
  WeekPlan reconcileGroceries(
    WeekPlan plan,
    Map<String, RecipeVersion> recipes,
  ) {
    final choices = <RecipePortion>[];
    for (final meal in plan.meals.values) {
      final recipe = recipes[meal.recipeKey];
      final amount = meal.servings;
      if (recipe != null && amount != null && recipe.accepts(amount)) {
        choices.add((recipe: recipe, servings: amount));
      }
    }
    final previous = {
      for (final item in plan.groceries)
        if (item.requirementKey != null) item.requirementKey!: item,
    };
    final items = <GroceryItem>[
      for (final item in plan.groceries)
        if (item.requirementKey == null) item,
    ];
    for (final requirement in groceriesFor(choices)) {
      final before = previous.remove(requirement.key);
      final grams = requirement.grams;
      final increased = before?.checked == true &&
          grams != null &&
          grams > (before?.requiredGrams ?? 0) + .00001;
      items.add(
        GroceryItem(
          before?.override == true ? before!.name : requirement.name,
          amount: before?.override == true
              ? before!.amount
              : grams == null
                  ? 'Amount unresolved'
                  : '${_displayAmount(grams)} g',
          checked: before?.checked ?? false,
          requirementKey: requirement.key,
          requiredGrams: grams,
          override: before?.override ?? false,
          changed: increased || (before?.changed ?? false),
        ),
      );
    }
    // Preserve rows the user explicitly edited or checked even when no longer required.
    for (final item in previous.values) {
      if (item.override || item.checked) {
        items.add(
          GroceryItem(item.name, amount: item.amount, checked: item.checked),
        );
      }
    }
    return plan.copyWith(groceries: items);
  }

  /// Finds pinned meals in [plan] that conflict with [profile]'s strict
  /// allergens or exclusions (and optional [cookingLimit]).
  List<PinnedMealConflict> findPinnedConflicts(
    WeekPlan plan,
    Map<String, RecipeVersion> recipes,
    PlanningProfile profile, {
    int? cookingLimit,
  }) {
    final exclusions = profile.preferences.exclusionItems;
    final strictAllergens = profile.preferences.allergenItems;
    final conflicts = <PinnedMealConflict>[];
    for (final entry in plan.meals.entries) {
      final meal = entry.value;
      if (!meal.pinned) continue;
      final recipe = meal.recipeKey == null ? null : recipes[meal.recipeKey];
      if (recipe != null) {
        final reasons = recipeIneligibilityReasons(
          recipe,
          exclusions: exclusions,
          strictAllergens: strictAllergens,
          cookingLimit: cookingLimit,
        );
        if (reasons.isNotEmpty) {
          conflicts.add(
            PinnedMealConflict(
              position: entry.key,
              meal: meal,
              reasons: reasons,
            ),
          );
        }
        continue;
      }
      final reasons = <String>[];
      if (strictAllergens.isNotEmpty) {
        final parsed = resolveStrictAllergens(strictAllergens);
        for (final term in parsed.unresolved) {
          reasons.add('unresolvedStrictAllergen:$term');
        }
        reasons.add('unknownAllergenStatus');
      }
      for (final raw in exclusions) {
        final term = raw.trim();
        if (term.isNotEmpty &&
            _textMentions('${meal.name} ${meal.details}', term)) {
          final code = 'excludedIngredient:$term';
          if (!reasons.contains(code)) reasons.add(code);
        }
      }
      if (reasons.isNotEmpty) {
        conflicts.add(
          PinnedMealConflict(
            position: entry.key,
            meal: meal,
            reasons: List.unmodifiable(reasons),
          ),
        );
      }
    }
    return List.unmodifiable(conflicts);
  }
}

String _displayAmount(double value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

bool _textMentions(String text, String term) {
  final key = normalizeAllergenText(term);
  if (key.isEmpty) return false;
  final haystack = ' ${normalizeAllergenText(text)} ';
  final singular = key.endsWith('s') && key.length > 3
      ? key.substring(0, key.length - 1)
      : key;
  return [key, singular, '${singular}s', '${singular}es']
      .any((word) => haystack.contains(' $word '));
}
