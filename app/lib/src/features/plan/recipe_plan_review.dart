import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart' hide MealSlot;

import 'recipe_planning.dart';
import 'week_plan.dart';

Future<bool> reviewRecipePlan(
    BuildContext context,
    WeekPlan before,
    WeekPlan after,
    Map<String, RecipeVersion> recipes,
    PlanningProfile profile,
    Set<MealPosition> changes) async {
  final days = changes.map((position) => position.day).toSet().toList()..sort();
  final original = {
    for (final item in before.groceries)
      if (item.requirementKey != null) item.requirementKey!: item
  };
  final next = {
    for (final item in after.groceries)
      if (item.requirementKey != null) item.requirementKey!: item
  };
  final keys = {...original.keys, ...next.keys}
      .where((key) =>
          !original.containsKey(key) ||
          !next.containsKey(key) ||
          original[key]?.requiredGrams != next[key]?.requiredGrams)
      .toList();
  return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Review plan and shopping changes'),
                scrollable: true,
                content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final day in days) ...[
                        Text(
                            MaterialLocalizations.of(context)
                                .formatMediumDate(before.dateFor(day)),
                            style: Theme.of(context).textTheme.titleSmall),
                        for (final position
                            in changes.where((position) => position.day == day))
                          Text(
                              '${position.slot.label}: ${before.meals[position]?.name ?? 'empty'} → ${after.meals[position]?.name ?? 'empty'} ${after.meals[position]?.details ?? ''}'),
                        for (final key in {
                          NutrientKey.energyKcal,
                          ...profile.targets.keys
                        })
                          Text(
                              '${nutrientTitle(key)}: ${_amount(dayTotals(before.meals, day, recipes)[key], key)} → ${_amount(dayTotals(after.meals, day, recipes)[key], key)}'),
                        if (profile.targets.isNotEmpty)
                          Text(targetSummary(
                              after.meals, day, recipes, profile.targets)),
                        const SizedBox(height: 8),
                      ],
                      const Text('Grocery requirements',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      if (keys.isEmpty)
                        const Text('No changes to ingredient requirements.'),
                      for (final key in keys)
                        Text(
                            '${(next[key] ?? original[key])!.name}: ${_required(original[key])} → ${_required(next[key])}${next[key]?.changed == true ? ' · check amount purchased' : ''}'),
                      const SizedBox(height: 8),
                      const Text(
                          'These totals describe the meals on the plan. They are not logged as eaten.'),
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Confirm plan and groceries'))
                ],
              )) ??
      false;
}

String _required(GroceryItem? item) => item == null
    ? 'not required'
    : item.requiredGrams == null
        ? 'amount unresolved'
        : '${displayAmount(item.requiredGrams!)} g';

String _amount(RecipeTotal? total, NutrientKey key) {
  final amount = total?.amount;
  return amount == null
      ? 'unknown'
      : '${total!.estimated ? '≈' : ''}${displayAmount(amount)} ${key.unit}${total.complete ? '' : ' (partial)'}';
}

String nutrientTitle(NutrientKey key) => switch (key) {
      NutrientKey.energyKcal => 'Energy',
      NutrientKey.proteinG => 'Protein',
      NutrientKey.carbohydrateG => 'Carbs',
      NutrientKey.fatG => 'Fat',
      _ => key.wire,
    };

String targetSummary(Map<MealPosition, PlannedMeal> meals, int day,
    Map<String, RecipeVersion> recipes, Map<NutrientKey, double> targets) {
  final totals = dayTotals(meals, day, recipes);
  return [
    for (final entry in targets.entries)
      '${nutrientTitle(entry.key)}: ${_amount(totals[entry.key], entry.key)} of ${displayAmount(entry.value)} ${entry.key.unit} declared${totals[entry.key]?.complete == true ? _difference(totals[entry.key]!.amount! - entry.value, entry.key.unit) : ''}',
  ].join(' · ');
}

String _difference(double delta, String unit) => delta.abs() < .01
    ? ' (on target)'
    : ' (${displayAmount(delta.abs())} $unit ${delta < 0 ? 'below' : 'above'})';

Future<({PlannedMeal? meal})?> chooseRecipe(BuildContext context,
    List<RecipeVersion> recipes, PlannedMeal? current) async {
  var selected =
      recipes.where((recipe) => recipe.key == current?.recipeKey).firstOrNull;
  var portions = current?.servings ?? 1.0;
  var pinned = current?.pinned ?? false;
  var manual = current != null && current.recipeKey == null;
  var name = manual ? current.name : '';
  return showDialog<({PlannedMeal? meal})>(
    context: context,
    builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
              title: const Text('Choose a recipe'),
              scrollable: true,
              content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (recipes.isEmpty)
                      const Text(
                          'No resolved recipes meet your current exclusions.'),
                    SwitchListTile(
                        value: manual,
                        title: const Text('Use a manual meal note'),
                        onChanged: (value) => refresh(() => manual = value)),
                    if (manual)
                      TextFormField(
                          initialValue: name,
                          maxLength: 120,
                          decoration:
                              const InputDecoration(labelText: 'Meal name'),
                          onChanged: (value) =>
                              refresh(() => name = value.trim())),
                    if (manual)
                      const Text(
                          'Notes appear on the schedule, but don’t produce nutrition or groceries.'),
                    if (!manual && recipes.isNotEmpty)
                      DropdownButton<RecipeVersion>(
                          value: selected,
                          isExpanded: true,
                          hint: const Text('Select a recipe'),
                          items: [
                            for (final recipe in recipes)
                              DropdownMenuItem(
                                  value: recipe,
                                  child: Text(recipe.name,
                                      overflow: TextOverflow.ellipsis))
                          ],
                          onChanged: (value) => refresh(() {
                                selected = value;
                                portions = 1;
                              })),
                    if (!manual && selected != null) ...[
                      for (final recipe in [selected!]) ...[
                        Text(recipe.method),
                        Text('Portions: ${displayAmount(portions)} servings'),
                        if (recipe.maxServings > recipe.minServings)
                          Slider(
                              min: recipe.minServings,
                              max: recipe.maxServings,
                              value: portions
                                  .clamp(recipe.minServings, recipe.maxServings)
                                  .toDouble(),
                              divisions:
                                  ((recipe.maxServings - recipe.minServings) *
                                          4)
                                      .ceil(),
                              onChanged: (value) =>
                                  refresh(() => portions = value)),
                      ],
                    ],
                    CheckboxListTile(
                        value: pinned,
                        title: const Text('Pin this slot'),
                        onChanged: (value) =>
                            refresh(() => pinned = value ?? false)),
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                if (current != null)
                  TextButton(
                      onPressed: () => Navigator.pop(context, (meal: null)),
                      child: const Text('Remove')),
                FilledButton(
                    onPressed: manual
                        ? (name.isEmpty
                            ? null
                            : () => Navigator.pop(context, (
                                  meal: PlannedMeal(name,
                                      details: 'Manual note', pinned: pinned)
                                )))
                        : selected?.accepts(portions) == true
                            ? () => Navigator.pop(context, (
                                  meal: plannedRecipe(selected!, portions,
                                      pinned: pinned)
                                ))
                            : null,
                    child: const Text('Review change'))
              ],
            )),
  );
}
