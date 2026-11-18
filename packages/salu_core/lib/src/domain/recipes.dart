import 'dart:math' as math;

import 'food.dart';
import 'nutrients.dart';
import 'photo_meal.dart';

/// A declared nutrient basis scales in-place; no g/ml or serving conversion is inferred.
final class BoundedNutrition {
  const BoundedNutrition(this.basis, this.nutrients);
  final MealPortion basis;
  final NutrientProfile nutrients;

  NutrientProfile? forPortion(MealPortion portion) {
    if (portion.unit != basis.unit) return null;
    final factor = portion.amount / basis.amount;
    try {
      return nutrients.scaled(factor);
    } on ArgumentError {
      return null;
    }
  }
}

final class RecipeIngredient {
  const RecipeIngredient(
      {required this.food,
      required this.edibleGrams,
      required this.purchaseName,
      this.purchaseGrams,
      this.purchaseId});
  final Food food;
  final double edibleGrams;
  final String purchaseName;

  /// A sourced or explicitly declared purchase amount; null means unresolved.
  final double? purchaseGrams;
  final String? purchaseId;
}

final class RecipeVersion {
  RecipeVersion(
      {required this.id,
      required this.name,
      required this.prepMinutes,
      required Iterable<RecipeIngredient> ingredients,
      this.version = 1,
      this.servings = 1,
      this.finishedGrams,
      this.method = '',
      this.minServings = .5,
      this.maxServings = 3,
      Set<String>? allergens})
      : ingredients = List.unmodifiable(ingredients),
        allergens = allergens == null ? null : Set.unmodifiable(allergens) {
    if (id.isEmpty ||
        name.trim().isEmpty ||
        version < 1 ||
        prepMinutes < 0 ||
        !servings.isFinite ||
        servings <= 0 ||
        !minServings.isFinite ||
        !maxServings.isFinite ||
        minServings <= 0 ||
        maxServings < minServings ||
        (finishedGrams != null &&
            (!finishedGrams!.isFinite || finishedGrams! <= 0)) ||
        this.ingredients.isEmpty ||
        this.ingredients.any((i) =>
            !i.edibleGrams.isFinite ||
            i.edibleGrams <= 0 ||
            (i.purchaseGrams != null &&
                (!i.purchaseGrams!.isFinite || i.purchaseGrams! <= 0)))) {
      throw ArgumentError('Invalid recipe or ingredient quantity');
    }
  }
  final String id, name, method;
  final int version, prepMinutes;
  final double servings, minServings, maxServings;
  final double? finishedGrams;
  final List<RecipeIngredient> ingredients;

  /// Null means no sufficient ingredient/allergen declaration is available.
  final Set<String>? allergens;
  String get key => '$id@$version';

  bool accepts(double portions) =>
      portions.isFinite && portions >= minServings && portions <= maxServings;

  Map<NutrientKey, RecipeTotal> forServings(double portions) {
    if (!accepts(portions)) {
      throw ArgumentError('Portion outside recipe bounds');
    }
    return _totals(portions / servings);
  }

  Map<NutrientKey, RecipeTotal>? forFinishedGrams(double grams) =>
      finishedGrams == null || !grams.isFinite || grams <= 0
          ? null
          : _totals(grams / finishedGrams!);

  Map<NutrientKey, RecipeTotal> _totals(double fraction) => {
        for (final key in NutrientKey.values)
          key: RecipeTotal.from([
            for (final ingredient in ingredients)
              ingredient.food
                  .nutrientsFor(ingredient.edibleGrams * fraction)[key],
          ]),
      };

  /// Separate frozen intake items preserve ingredient-level nutrient coverage.
  List<PhotoMealItem> snapshot(double portions) {
    if (!accepts(portions)) {
      throw ArgumentError('Portion outside recipe bounds');
    }
    return snapshotFraction(portions / servings);
  }

  List<PhotoMealItem> snapshotFraction(double fraction) {
    if (!fraction.isFinite || fraction <= 0) {
      throw ArgumentError('Invalid recipe fraction');
    }
    return [
      for (final ingredient in ingredients)
        PhotoMealItem(
            name: ingredient.food.name,
            portion:
                MealPortion(ingredient.edibleGrams * fraction, MealUnit.grams),
            nutrients:
                ingredient.food.nutrientsFor(ingredient.edibleGrams * fraction),
            source:
                'recipe:$key:${ingredient.food.source.dataset}:${ingredient.food.source.datasetId}'),
    ];
  }
}

/// Inventory is separate from the recipe and expressed as a fraction of a batch.
final class CookedRecipeBatch {
  CookedRecipeBatch(
      {required this.recipe,
      required this.cookedServings,
      this.finishedGrams,
      this.remainingFraction = 1}) {
    if (!cookedServings.isFinite ||
        cookedServings <= 0 ||
        !remainingFraction.isFinite ||
        remainingFraction < 0 ||
        remainingFraction > 1 ||
        (finishedGrams != null &&
            (!finishedGrams!.isFinite || finishedGrams! <= 0))) {
      throw ArgumentError('Invalid cooked batch');
    }
  }
  final RecipeVersion recipe;
  final double cookedServings, remainingFraction;
  final double? finishedGrams;

  double? consumptionFraction(MealPortion amount) {
    final capacity = switch (amount.unit) {
      MealUnit.grams => finishedGrams,
      MealUnit.servings => cookedServings,
      _ => null,
    };
    if (capacity == null) return null;
    final fraction = amount.amount / capacity;
    return fraction <= remainingFraction + 1e-10
        ? fraction.clamp(0, remainingFraction).toDouble()
        : null;
  }

  List<PhotoMealItem> snapshot(double fraction) {
    if (fraction <= 0 || fraction > remainingFraction + 1e-10) {
      throw ArgumentError('Insufficient leftover amount');
    }
    return recipe.snapshotFraction(fraction * cookedServings / recipe.servings);
  }
}

final class RecipeTotal {
  RecipeTotal.from(Iterable<NutrientValue> values) {
    var sum = NutrientSum.zero;
    var known = 0;
    var missing = 0;
    for (final value in values) {
      if (value.isKnown) {
        known++;
      } else {
        missing++;
      }
      sum = sum.adding(value);
    }
    amount = known == 0 || !sum.value.isFinite ? null : sum.value;
    complete = known > 0 && missing == 0;
    estimated = sum.includesEstimate;
  }
  late final double? amount;
  late final bool complete, estimated;
}

typedef RecipePortion = ({RecipeVersion recipe, double servings});

final class GroceryRequirement {
  const GroceryRequirement(this.key, this.name, this.grams);
  final String key, name;
  final double? grams;
}

List<GroceryRequirement> groceriesFor(Iterable<RecipePortion> choices) {
  final requirements = <String, GroceryRequirement>{};
  for (final choice in choices) {
    if (!choice.recipe.accepts(choice.servings)) {
      throw ArgumentError('Invalid recipe portion');
    }
    final fraction = choice.servings / choice.recipe.servings;
    for (final i in choice.recipe.ingredients) {
      // Never merge unidentified purchase measures with quantified requirements.
      final key =
          '${i.purchaseId ?? i.food.id}:${i.purchaseGrams == null ? 'unresolved' : 'g'}';
      final amount = i.purchaseGrams;
      requirements[key] = GroceryRequirement(
          key,
          i.purchaseName,
          amount == null
              ? null
              : (requirements[key]?.grams ?? 0) + amount * fraction);
    }
  }
  return requirements.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// Reproducible bounded local search over resolved choices, with soft targets.
List<RecipePortion> rankRecipePortions({
  required Iterable<RecipeVersion> recipes,
  Iterable<String> dislikes = const [],
  Iterable<String> exclusions = const [],
  Iterable<String> strictAllergens = const [],
  Map<NutrientKey, double> remaining = const {},
  int? cookingLimit,
  Map<String, int> uses = const {},
}) {
  final candidates = <({RecipePortion value, double score})>[];
  for (final recipe in recipes) {
    if (!recipeEligible(recipe,
        exclusions: exclusions,
        strictAllergens: strictAllergens,
        cookingLimit: cookingLimit)) {
      continue;
    }
    final disliked = dislikes.any((term) => _recipeMentions(recipe, term));
    for (final servings in const [.5, .75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]) {
      if (!recipe.accepts(servings)) continue;
      final totals = recipe.forServings(servings);
      var score = (disliked ? 10.0 : 0.0) +
          (uses[recipe.key] ?? 0) * .3 +
          recipe.prepMinutes * .01 +
          (servings - 1).abs() * .12;
      for (final target in remaining.entries) {
        final total = totals[target.key]!;
        score += !total.complete || total.amount == null
            ? 3
            : (total.amount! - target.value).abs() /
                math.max(1, target.value.abs());
      }
      candidates
          .add((value: (recipe: recipe, servings: servings), score: score));
    }
  }
  candidates.sort((a, b) {
    final byScore = a.score.compareTo(b.score);
    if (byScore != 0) return byScore;
    final byKey = a.value.recipe.key.compareTo(b.value.recipe.key);
    return byKey == 0 ? a.value.servings.compareTo(b.value.servings) : byKey;
  });
  return candidates.map((candidate) => candidate.value).toList(growable: false);
}

bool recipeEligible(RecipeVersion recipe,
    {Iterable<String> exclusions = const [],
    Iterable<String> strictAllergens = const [],
    int? cookingLimit}) {
  // A declaration of an empty set is distinct from unknown status.
  if (strictAllergens.isNotEmpty &&
      (recipe.allergens == null ||
          strictAllergens.any(
              (term) => recipe.allergens!.any((tag) => _matches(tag, term))))) {
    return false;
  }
  return (cookingLimit == null || recipe.prepMinutes <= cookingLimit) &&
      !exclusions.any((term) => _recipeMentions(recipe, term));
}

bool _recipeMentions(RecipeVersion recipe, String term) =>
    _matches(recipe.name, term) ||
    recipe.ingredients.any((ingredient) =>
        _matches(ingredient.food.name, term) ||
        _matches(ingredient.purchaseName, term));

bool _matches(String name, String term) {
  String normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  final key = normalize(term);
  if (key.isEmpty) return false;
  final haystack = ' ${normalize(name)} ';
  final singular = key.endsWith('s') && key.length > 3
      ? key.substring(0, key.length - 1)
      : key;
  return [key, singular, '${singular}s', '${singular}es']
      .any((word) => haystack.contains(' $word '));
}
