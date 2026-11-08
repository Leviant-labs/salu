import 'dart:convert';
import 'food.dart';
import 'nutrients.dart';
import 'nutrition_contract.dart';

final class RecipeIngredient {
  RecipeIngredient(Food food, this.grams)
      : food = Food(
            id: food.id,
            name: food.name,
            per100g: food.per100g,
            source: food.source,
            portions: food.portions,
            quality: food.quality,
            preparation: food.preparation,
            allergens: food.allergens == null
                ? null
                : Set.unmodifiable(food.allergens!),
            dietaryTags: Set.unmodifiable(food.dietaryTags),
            isComposite: food.isComposite,
            basisUnit: food.basisUnit,
            basisValue: food.basisValue) {
    if (!grams.positive) {
      throw ArgumentError('Ingredient amount must be positive');
    }
  }
  final Food food;
  final Exact grams;
  NutrientProfile get nutrients => food.nutrientsForExactGrams(grams);
}

/// Immutable definition, deliberately distinct from finite cooked stock.
final class RecipeVersion {
  RecipeVersion(
      {required this.id,
      required this.revision,
      required this.name,
      required List<RecipeIngredient> ingredients,
      required this.servings,
      required this.minutes,
      Set<String>? allergens,
      Set<String> dietaryTags = const {}})
      : ingredients = List.unmodifiable(ingredients),
        allergens = allergens == null ? null : Set.unmodifiable(allergens),
        dietaryTags = Set.unmodifiable(dietaryTags) {
    if (id.isEmpty ||
        revision < 1 ||
        ingredients.isEmpty ||
        !servings.positive ||
        minutes < 0) {
      throw ArgumentError('Invalid recipe');
    }
  }
  final String id, name;
  final int revision, minutes;
  final Exact servings;
  final List<RecipeIngredient> ingredients;
  final Set<String>? allergens;
  final Set<String> dietaryTags;
  String get definitionSignature => jsonEncode({
        'id': id,
        'revision': revision,
        'name': name,
        'servings': servings.toJson(),
        'minutes': minutes,
        'allergens': allergens == null ? null : (allergens!.toList()..sort()),
        'diet': dietaryTags.toList()..sort(),
        'ingredients': [
          for (final i in ingredients)
            {
              'id': i.food.id,
              'name': i.food.name,
              'quantity': i.grams.toJson(),
              'basisUnit': i.food.basisUnit.name,
              'basisValue': i.food.basisValue,
              'source': i.food.source.toString(),
              'state': i.food.preparation.name,
              'allergens': i.food.allergens == null
                  ? null
                  : (i.food.allergens!.toList()..sort()),
              'nutrients': {
                for (final key in NutrientKey.values)
                  if (i.food.per100g.values.containsKey(key))
                    key.wire: i.food.per100g[key].toJson()
              }
            }
        ],
      });
  @override
  bool operator ==(Object other) =>
      other is RecipeVersion &&
      definitionSignature == other.definitionSignature;
  @override
  int get hashCode => definitionSignature.hashCode;
  Map<NutrientKey, NutrientSum> get totals =>
      NutrientProfile.combine(ingredients.map((i) => i.nutrients));

  /// Cooking losses are not modeled. Missing nutrients stay partial.
  Map<NutrientKey, NutrientSum> perServing(Exact portion) {
    final scale = portion / servings;
    return totals.map((key, s) => MapEntry(
        key,
        NutrientSum(
            value: (s.exactValue * scale).toDouble(),
            exact: s.exactValue * scale,
            knownEntries: s.knownEntries,
            isComplete: s.isComplete,
            includesTrace: s.includesTrace,
            includesEstimate: s.includesEstimate)));
  }

  bool eligible(Set<String> exclusions, Set<String> diet) {
    if (!diet.every(dietaryTags.contains)) return false;
    if (exclusions.isNotEmpty &&
        (allergens == null || exclusions.any(allergens!.contains))) {
      return false;
    }
    for (final i in ingredients) {
      if (exclusions.isNotEmpty &&
          (i.food.allergens == null ||
              exclusions.any(i.food.allergens!.contains))) {
        return false;
      }
    }
    return true;
  }
}

final class BatchAllocation {
  BatchAllocation(this.id, this.amount, this.status) {
    if (id.isEmpty || !amount.positive) {
      throw ArgumentError('Invalid allocation');
    }
  }
  final String id;
  final Exact amount;
  final String
      status; // planned or consumed; changing state retains one allocation.
}

final class CookedBatch {
  CookedBatch(
      {required this.id,
      required this.recipe,
      required this.revision,
      required this.available,
      required this.unit,
      this.finishedWeightG,
      List<BatchAllocation> allocations = const []})
      : allocations = List.unmodifiable(allocations) {
    if (id.isEmpty ||
        revision < 1 ||
        !available.positive ||
        (unit != FoodUnit.g && unit != FoodUnit.serving)) {
      throw ArgumentError('Invalid batch');
    }
    if (unit == FoodUnit.g &&
        (finishedWeightG == null || !finishedWeightG!.positive)) {
      throw StateError('MEASURED_YIELD_REQUIRED');
    }
    if (allocations.map((a) => a.id).toSet().length != allocations.length) {
      throw StateError('DUPLICATE_ALLOCATION');
    }
    if (allocated.compareTo(available) > 0) {
      throw StateError('BATCH_OVERALLOCATED');
    }
  }
  final String id;
  final RecipeVersion recipe;
  final int revision;
  final Exact available;
  final FoodUnit unit;
  final Exact? finishedWeightG;
  final List<BatchAllocation> allocations;
  Exact get allocated => allocations.fold(Exact.zero, (a, b) => a + b.amount);
  CookedBatch allocate(BatchAllocation allocation,
      {required int expectedRevision}) {
    if (expectedRevision != revision) throw StateError('STALE_BATCH');
    return CookedBatch(
        id: id,
        recipe: recipe,
        revision: revision + 1,
        available: available,
        unit: unit,
        finishedWeightG: finishedWeightG,
        allocations: [...allocations, allocation]);
  }

  Map<NutrientKey, NutrientSum> nutrientsFor(Exact amount) {
    if (!amount.positive || amount.compareTo(available) > 0) {
      throw ArgumentError('Invalid portion');
    }
    final factor = unit == FoodUnit.g
        ? amount / finishedWeightG!
        : amount / recipe.servings;
    return recipe.totals.map((k, s) => MapEntry(
        k,
        NutrientSum(
            value: (s.exactValue * factor).toDouble(),
            exact: s.exactValue * factor,
            knownEntries: s.knownEntries,
            isComplete: s.isComplete,
            includesTrace: s.includesTrace,
            includesEstimate: s.includesEstimate)));
  }
}

final class MealSlot {
  const MealSlot(this.id, this.date, this.label);
  final String id, date, label;
}

final class PlannedMeal {
  PlannedMeal(this.slot, this.recipe, this.portions, {this.pinned = false}) {
    if (!portions.positive) throw ArgumentError('Portions must be positive');
  }
  final MealSlot slot;
  final RecipeVersion recipe;
  final Exact portions;
  final bool pinned;
  Map<NutrientKey, NutrientSum> get nutrients => recipe.perServing(portions);
}

final class NumericConstraint {
  NumericConstraint(this.nutrient, this.minimum, this.maximum) {
    if (minimum.compareTo(maximum) > 0 || minimum.compareTo(Exact.zero) < 0) {
      throw ArgumentError('TARGET_CONFLICT');
    }
  }
  final NutrientKey nutrient;
  final Exact minimum, maximum;
}

final class PlannerContext {
  PlannerContext(
      {required List<MealSlot> slots,
      required List<RecipeVersion> recipes,
      required this.seed,
      this.catalogueVersion = 'local',
      this.policyVersion = 'planner-v2',
      this.maxNodes = 2000,
      this.maximumMinutes,
      this.maximumRepeats,
      this.strictExclusions = const {},
      this.dietaryTags = const {},
      this.constraints = const [],
      List<Exact>? portions})
      : slots = List.unmodifiable(slots),
        recipes = List.unmodifiable(recipes),
        portions = List.unmodifiable(portions ?? [Exact.one]) {
    if (maxNodes < 1 ||
        slots.map((s) => s.id).toSet().length != slots.length ||
        this.portions.isEmpty ||
        this.portions.any((p) => !p.positive)) {
      throw ArgumentError('Invalid planner context');
    }
  }
  final List<MealSlot> slots;
  final List<RecipeVersion> recipes;
  final List<Exact> portions;
  final int seed, maxNodes;
  final String catalogueVersion, policyVersion;
  final int? maximumMinutes, maximumRepeats;
  final Set<String> strictExclusions, dietaryTags;
  final List<NumericConstraint> constraints;
}

enum PlannerStatus {
  validPlan,
  targetConflict,
  insufficientData,
  searchExhausted,
  provenInfeasible,
  proposedRelaxation
}

final class PlannerResult {
  PlannerResult(this.status, this.meals, this.diagnostics, {this.visited = 0});
  final PlannerStatus status;
  final List<PlannedMeal> meals;
  final List<String> diagnostics;
  final int visited;
}

final class PlannerService {
  const PlannerService();
  List<String> validate(List<PlannedMeal> meals, PlannerContext c) {
    final errors = <String>[];
    if (meals.length != c.slots.length ||
        meals.map((m) => m.slot.id).toSet().length != c.slots.length) {
      errors.add('UNRESOLVED_SLOTS');
    }
    for (final meal in meals) {
      final definitions = c.recipes.where(
          (r) => r.id == meal.recipe.id && r.revision == meal.recipe.revision);
      if (definitions.isEmpty || definitions.first != meal.recipe) {
        errors.add('RECIPE_REVISION_MISMATCH');
      }
      if (!meal.recipe.eligible(c.strictExclusions, c.dietaryTags)) {
        errors.add('EXCLUSION_CONFLICT');
      }
      if (c.maximumMinutes != null && meal.recipe.minutes > c.maximumMinutes!) {
        errors.add('COOKING_TIME');
      }
      if (!c.portions.contains(meal.portions)) errors.add('PORTION_BOUNDS');
      if (!c.slots
          .any((s) => s.id == meal.slot.id && s.date == meal.slot.date)) {
        errors.add('SLOT_MISMATCH');
      }
    }
    if (c.maximumRepeats != null) {
      for (final r in c.recipes) {
        if (meals.where((m) => m.recipe.id == r.id).length >
            c.maximumRepeats!) {
          errors.add('REPETITION_LIMIT');
        }
      }
    }
    for (final day in c.slots.map((s) => s.date).toSet()) {
      for (final bound in c.constraints) {
        var sum = Exact.zero;
        var complete = true;
        for (final meal in meals.where((m) => m.slot.date == day)) {
          final n = meal.nutrients[bound.nutrient];
          if (n == null || !n.isComplete || n.includesEstimate) {
            complete = false;
          }
          sum += n?.exactValue ?? Exact.zero;
        }
        if (!complete) {
          errors.add('INSUFFICIENT_NUTRIENT_DATA');
        } else if (sum.compareTo(bound.minimum) < 0 ||
            sum.compareTo(bound.maximum) > 0) {
          errors.add('NUMERIC_CONSTRAINT');
        }
      }
    }
    return errors;
  }

  PlannerResult repair(PlannerContext c, List<PlannedMeal> existing) =>
      plan(c, existing: existing);
  PlannerResult plan(PlannerContext c,
      {List<PlannedMeal> existing = const []}) {
    if (existing.length == c.slots.length && validate(existing, c).isEmpty) {
      return PlannerResult(PlannerStatus.validPlan, List.unmodifiable(existing),
          const ['Original plan retained']);
    }
    final eligible = c.recipes
        .where((r) =>
            r.eligible(c.strictExclusions, c.dietaryTags) &&
            (c.maximumMinutes == null || r.minutes <= c.maximumMinutes!))
        .toList()
      ..sort((a, b) {
        final order = a.id.compareTo(b.id);
        return order == 0 ? a.revision.compareTo(b.revision) : order;
      });
    if (c.slots.isNotEmpty && eligible.isEmpty) {
      return PlannerResult(PlannerStatus.provenInfeasible, const [],
          const ['Empty eligible recipe set for mandatory slots']);
    }
    for (final meal in existing.where((m) => m.pinned)) {
      if (!eligible.contains(meal.recipe)) {
        return PlannerResult(PlannerStatus.targetConflict, const [],
            const ['Pinned meal conflicts with recipe revision or exclusions']);
      }
    }
    // Stable integer rotation: SDK/platform independent tie-breaking.
    if (eligible.isNotEmpty) {
      final rotation = c.seed.abs() % eligible.length;
      eligible.addAll(eligible.take(rotation).toList());
      eligible.removeRange(0, rotation);
    }
    var visited = 0;
    var hadMissing = false;
    var exhausted = false;
    List<PlannedMeal>? found;
    void search(List<PlannedMeal> current) {
      if (found != null || exhausted) return;
      if (++visited > c.maxNodes) {
        exhausted = true;
        return;
      }
      if (current.length == c.slots.length) {
        final errors = validate(current, c);
        if (errors.contains('INSUFFICIENT_NUTRIENT_DATA')) hadMissing = true;
        if (errors.isEmpty) found = List.unmodifiable(current);
        return;
      }
      final slot = c.slots[current.length];
      final original = existing.where((m) => m.slot.id == slot.id).firstOrNull;
      final choices = <PlannedMeal>[
        if (original != null && eligible.contains(original.recipe)) original,
        if (original?.pinned != true)
          for (final r in eligible)
            for (final portion in c.portions) PlannedMeal(slot, r, portion),
      ];
      for (final meal in choices) {
        if (c.maximumRepeats != null &&
            current.where((m) => m.recipe.id == meal.recipe.id).length >=
                c.maximumRepeats!) {
          continue;
        }
        search([...current, meal]);
        if (found != null || exhausted) return;
      }
    }

    search([]);
    if (found != null) {
      return PlannerResult(PlannerStatus.validPlan, found!,
          const ['Deterministic bounded search; no global optimization claim'],
          visited: visited);
    }
    if (exhausted) {
      return PlannerResult(PlannerStatus.searchExhausted, const [],
          const ['Search budget reached; constraints were not relaxed'],
          visited: visited);
    }
    if (hadMissing) {
      return PlannerResult(PlannerStatus.insufficientData, const [],
          const ['Binding nutrient data missing'],
          visited: visited);
    }
    return PlannerResult(
        PlannerStatus.provenInfeasible,
        const [],
        const [
          'All combinations in the declared finite recipe/portion space were enumerated'
        ],
        visited: visited);
  }
}

final class GroceryLine {
  const GroceryLine(this.foodId, this.name, this.grams, this.preparation);
  final String foodId, name;
  final Exact grams;
  final Preparation preparation;
}

List<GroceryLine> groceriesFor(List<PlannedMeal> meals) {
  final lines = <String, GroceryLine>{};
  for (final meal in meals) {
    for (final ingredient in meal.recipe.ingredients) {
      final key = '${ingredient.food.id}|${ingredient.food.preparation.name}';
      final quantity = ingredient.grams * meal.portions / meal.recipe.servings;
      final previous = lines[key];
      lines[key] = GroceryLine(
          ingredient.food.id,
          ingredient.food.name,
          (previous?.grams ?? Exact.zero) + quantity,
          ingredient.food.preparation);
    }
  }
  return lines.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}
