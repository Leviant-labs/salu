import 'dart:convert';

import 'package:salu_core/salu_core.dart' hide MealSlot;

import '../../assistant/assistant.dart';
import 'plan_suggestions.dart';
import 'recipe_library.dart';
import 'week_plan.dart';

export 'package:salu_core/salu_core.dart' show PinnedMealConflict, PlanService;

const PlanService _planService = PlanService();

final class PinnedMealConflictException implements Exception {
  const PinnedMealConflictException(this.conflicts);

  final List<PinnedMealConflict> conflicts;
}

String describeIneligibilityReason(String reason) {
  if (reason == 'unknownAllergenStatus') {
    return 'Allergen status is unknown (excluded when strict allergies are active).';
  }
  if (reason == 'cookingLimit') {
    return 'Exceeds the cooking time limit.';
  }
  if (reason.startsWith('unresolvedStrictAllergen:')) {
    final term = reason.substring('unresolvedStrictAllergen:'.length);
    return 'Unrecognized strict allergy "$term" — select a canonical allergen category or move it to "Must exclude".';
  }
  if (reason.startsWith('containsAllergen:')) {
    final id = reason.substring('containsAllergen:'.length);
    final label = AllergenId.values
            .where((value) => value.name == id)
            .firstOrNull
            ?.label ??
        id;
    return 'Contains declared allergen: $label.';
  }
  if (reason.startsWith('excludedIngredient:')) {
    final term = reason.substring('excludedIngredient:'.length);
    return 'Contains excluded ingredient: $term.';
  }
  return reason;
}

List<PinnedMealConflict> findPinnedConflicts(
  WeekPlan plan,
  Map<String, RecipeVersion> recipes,
  PlanningProfile profile,
) =>
    _planService.findPinnedConflicts(plan, recipes, profile);

class RecipePlanning {
  const RecipePlanning(this.library, this.assistant);
  final RecipeLibrary library;
  final SaluAssistant assistant;

  List<RecipeVersion> eligible(
          Iterable<RecipeVersion> recipes, PlanningProfile profile,
          {int? cookingLimit}) =>
      [
        for (final recipe in recipes)
          if (recipeEligible(recipe,
              exclusions: profile.preferences.exclusionItems,
              strictAllergens: profile.preferences.allergenItems,
              cookingLimit: cookingLimit))
            recipe,
      ];

  Map<RecipeVersion, List<String>> ineligibilityReasons(
      Iterable<RecipeVersion> recipes, PlanningProfile profile,
      {int? cookingLimit}) {
    final result = <RecipeVersion, List<String>>{};
    for (final recipe in recipes) {
      final reasons = recipeIneligibilityReasons(
        recipe,
        exclusions: profile.preferences.exclusionItems,
        strictAllergens: profile.preferences.allergenItems,
        cookingLimit: cookingLimit,
      );
      if (reasons.isNotEmpty) {
        result[recipe] = reasons;
      }
    }
    return Map.unmodifiable(result);
  }

  List<PinnedMealConflict> pinnedConflicts(
    WeekPlan plan,
    Iterable<RecipeVersion> recipes,
    PlanningProfile profile,
  ) =>
      findPinnedConflicts(
        plan,
        {for (final recipe in recipes) recipe.key: recipe},
        profile,
      );

  static int? parseCookingLimit(String request) {
    final match = RegExp(
            r'\b(?:under|within|at most|max(?:imum)?)\s+(\d{1,3})\s*(?:min|minutes)\b',
            caseSensitive: false)
        .firstMatch(request);
    return match == null ? null : int.parse(match[1]!);
  }

  Future<Map<MealPosition, PlannedMeal>> propose(
      WeekPlan plan,
      List<RecipeVersion> recipes,
      PlanningProfile profile,
      PlanSuggestionContext request,
      {required bool useAI}) async {
    final byKey = {for (final recipe in recipes) recipe.key: recipe};
    final conflicts = findPinnedConflicts(plan, byKey, profile);
    if (conflicts.isNotEmpty) {
      throw PinnedMealConflictException(conflicts);
    }
    final limit = parseCookingLimit(request.request);
    final latest = <String, RecipeVersion>{};
    for (final recipe in recipes) {
      if ((latest[recipe.id]?.version ?? 0) < recipe.version) {
        latest[recipe.id] = recipe;
      }
    }
    final eligibleRecipes =
        eligible(latest.values, profile, cookingLimit: limit);
    if (eligibleRecipes.isEmpty) return {};
    final slots = <MealPosition>[
      for (var day = 0; day < 7; day++)
        if (!request.keepDays.contains(day))
          for (final slot in MealSlot.values)
            if (plan.meals[(day: day, slot: slot)]?.pinned != true &&
                (plan.meals[(day: day, slot: slot)] == null ||
                    (useAI && request.request.isNotEmpty)))
              (day: day, slot: slot),
    ];
    if (slots.isEmpty) return {};
    if (useAI) {
      if (!await assistant.isConnected) throw const PlanAssistantNotConnected();
      final response = await assistant.ask(
          instructions: '''
Choose meals using only the eligible recipe candidates and editable slots in the input.
Interpret request as a preference about these meals only. Leave slots unchanged unless a change is requested or empty slots are to be filled. Never touch a slot outside editableSlots or suggest a name, ingredients, nutrition or groceries yourself.
Return {"meals":[{"day":0,"slot":"dinner","recipeKey":"id@1","servings":1}]}.
Use valid portion bounds. When available, prefer the app's suggested portion for that slot. Honor dislikes, omit unsupported slots, and keep the reply compact.
''',
          task: InferenceTask.planSuggestions,
          prompt: jsonEncode({
            'request': request.request,
            'dislikes': profile.preferences.dislikeItems,
            'likes': profile.preferences.likes,
            'editableSlots': [
              for (final slot in slots)
                {
                  'day': slot.day,
                  'slot': slot.slot.name,
                  if (plan.meals[slot] case final current?)
                    'current': current.name
                }
            ],
            'recipes': [
              for (final recipe in eligibleRecipes.take(36))
                {
                  'key': recipe.key,
                  'name': recipe.name,
                  'minutes': recipe.prepMinutes,
                  'min': recipe.minServings,
                  'max': recipe.maxServings,
                  if (profile.targets.isNotEmpty)
                    'preferredServings': rankRecipePortions(recipes: [
                      recipe
                    ], remaining: {
                      for (final target in profile.targets.entries)
                        target.key: target.value / MealSlot.values.length
                    }).firstOrNull?.servings
                }
            ],
          }));
      final rows = response['meals'];
      if (rows is! List || rows.length > slots.length) {
        throw const FormatException('Invalid plan');
      }
      final candidateByKey = {
        for (final recipe in eligibleRecipes.take(36)) recipe.key: recipe
      };
      final result = <MealPosition, PlannedMeal>{};
      for (final row in rows) {
        if (row is! Map) throw const FormatException('Invalid meal');
        final day = row['day'];
        final slot = MealSlot.values
            .where((slot) => slot.name == row['slot'])
            .firstOrNull;
        final recipe = candidateByKey[row['recipeKey']];
        final amount = row['servings'];
        if (day is! int ||
            slot == null ||
            recipe == null ||
            amount is! num ||
            !recipe.accepts(amount.toDouble())) {
          throw const FormatException('Invalid recipe choice');
        }
        final position = (day: day, slot: slot);
        if (!slots.contains(position) || result.containsKey(position)) {
          throw const FormatException('Unexpected slot');
        }
        result[position] = plannedRecipe(recipe, amount.toDouble());
      }
      return result;
    }

    final result = <MealPosition, PlannedMeal>{};
    final uses = <String, int>{};
    for (final meal in plan.meals.values) {
      if (meal.recipeKey case final key?) {
        uses.update(key, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    for (final position in slots) {
      final current =
          dayTotals({...plan.meals, ...result}, position.day, byKey);
      final toFill = slots
          .where(
              (slot) => slot.day == position.day && !result.containsKey(slot))
          .length;
      final ranked = rankRecipePortions(
          recipes: eligibleRecipes,
          uses: uses,
          dislikes: profile.preferences.dislikeItems,
          exclusions: profile.preferences.exclusionItems,
          strictAllergens: profile.preferences.allergenItems,
          cookingLimit: limit,
          remaining: {
            for (final target in profile.targets.entries)
              if (current[target.key]?.complete == true ||
                  !({...plan.meals, ...result})
                      .keys
                      .any((slot) => slot.day == position.day))
                target.key:
                    ((target.value - (current[target.key]?.amount ?? 0)) /
                            toFill)
                        .clamp(0, double.infinity)
                        .toDouble(),
          });
      if (ranked.isEmpty) continue;
      final choice = ranked.first;
      result[position] = plannedRecipe(choice.recipe, choice.servings);
      uses.update(choice.recipe.key, (count) => count + 1, ifAbsent: () => 1);
    }
    return result;
  }
}

PlannedMeal plannedRecipe(RecipeVersion recipe, double servings,
        {bool pinned = false}) =>
    PlannedMeal(
      recipe.name,
      details:
          '${displayAmount(servings)} servings · ${recipe.prepMinutes} min',
      recipeKey: recipe.key,
      servings: servings,
      pinned: pinned,
    );

String displayAmount(double value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

Map<NutrientKey, RecipeTotal> dayTotals(
  Map<MealPosition, PlannedMeal> meals,
  int day,
  Map<String, RecipeVersion> recipes,
) =>
    _planService.dayTotals(meals, day, recipes);

WeekPlan reconcileGroceries(
  WeekPlan plan,
  Map<String, RecipeVersion> recipes,
) =>
    _planService.reconcileGroceries(plan, recipes);
