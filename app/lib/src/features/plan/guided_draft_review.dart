/// Pure helpers for turning a frozen guided draft into the shared
/// before/after review surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'guided_plan_review.dart';
import '../../providers.dart';
import '../../ui_support.dart';

/// Decodes one frozen meal row from `draft.values['meals']` /
/// `['previousMeals']` — the exact `_mealJson` shape written by
/// `GuidedPlanService.propose`.
PlannedMeal plannedMealFromDraftJson(Map<String, Object?> value) {
  final use = value['batchUse'] == null
      ? null
      : Map<String, Object?>.from(value['batchUse'] as Map);
  return PlannedMeal(
    MealSlot(
      value['slot']! as String,
      value['date']! as String,
      value['label']! as String,
    ),
    recipeFromSnapshot(Map<String, Object?>.from(value['recipe'] as Map)),
    Exact.fromJson(Map<String, Object?>.from(value['portions'] as Map)),
    pinned: value['pinned'] == true,
    batchUse: use == null
        ? null
        : PlannedBatchUse(
            use['batchId']! as String,
            use['batchRevision']! as int,
            use['allocationId']! as String,
          ),
  );
}

/// Locally computed daily-totals line for before/after comparison. INSA
/// available carbohydrate is excluded here; it never enters the EU legacy
/// carbohydrate projection.
String nutritionDeltaFor({
  required List<PlannedMeal> before,
  required List<PlannedMeal> after,
  required BuildContext context,
}) {
  final settings = ProviderScope.containerOf(context).read(settingsProvider);
  final hideNumbers = settings['support'] == true ||
      settings['hideCalorieNudges'] == true;
  String totals(List<PlannedMeal> meals) {
    final rows = <String>[];
    for (final key in [if(!hideNumbers)NutrientKey.energyKcal,
        NutrientKey.proteinG,NutrientKey.fatG]) {
      var sum = Exact.zero;
      var complete = true;
      for(final meal in meals) {
        final value = meal.nutrients[key];
        if(value == null || !value.isComplete) complete = false;
        if(value != null) sum += value.exactValue;
      }
      rows.add('${nutrientLabel(context,key.wire)} '
          '${number(sum.toDouble())} ${key.unit}'
          '${complete ? '' : ' (${tr(context,'partial','parcial')})'}');
    }
    return rows.join(' · ');
  }

  return '${tr(context, 'Before', 'Antes')}: ${totals(before)}\n'
      '${tr(context, 'After', 'Depois')}: ${totals(after)}';
}

/// Grocery additions/removals between two frozen requirement lists.
({List<String> additions, List<String> removals}) groceryDelta(
  List<Map<String, Object?>> before,
  List<Map<String, Object?>> after,
) {
  String key(Map<String, Object?> row) =>
      '${row['foodId']}|${row['preparation']}';
  final old = {for(final row in before)key(row):row};
  final next = {for(final row in after)key(row):row};
  final additions = <String>[], removals = <String>[];
  for(final id in {...old.keys,...next.keys}) {
    Exact grams(Map<String,Object?>? row) => row == null ? Exact.zero :
        Exact.fromJson(Map<String,Object?>.from(row['grams']! as Map));
    final difference = grams(next[id]) - grams(old[id]);
    if(difference == Exact.zero) continue;
    final name = (next[id] ?? old[id])!['name']?.toString() ?? id;
    final amount = difference.compareTo(Exact.zero) < 0
        ? Exact.zero - difference : difference;
    final line = '$name · ${amount.toDouble().round()} g';
    (difference.positive ? additions : removals).add(line);
  }
  return (additions:additions,removals:removals);
}

/// Assembles and shows the shared before/after review. Apply calls the
/// guided `accept` for [draftId]; Keep returns without writing anything.
Future<bool> showGuidedDraftReview(
  BuildContext context, {
  required MealDraft draft,
  String? rationale,
}) async {
  final values = draft.values;
  final before = [
    for (final raw in (values['previousMeals'] as List?) ?? [])
      plannedMealFromDraftJson(Map<String, Object?>.from(raw as Map))
  ];
  final after = [
    for (final raw in (values['meals'] as List?) ?? [])
      plannedMealFromDraftJson(Map<String, Object?>.from(raw as Map))
  ];
  final beforeBySlot = {for (final meal in before) meal.slot.id: meal};
  final afterBySlot = {for (final meal in after) meal.slot.id: meal};
  final slotIds = <String>{
    ...beforeBySlot.keys,
    ...afterBySlot.keys,
  }.toList()
    ..sort();
  final changes = <GuidedMealChange>[];
  for (final slotId in slotIds) {
    final b = beforeBySlot[slotId];
    final a = afterBySlot[slotId];
    if (b == null && a == null) continue;
    if (b != null &&
        a != null &&
        b.recipe.id == a.recipe.id &&
        b.portions == a.portions) {
      continue;
    }
    final slot = a?.slot ?? b!.slot;
    changes.add(GuidedMealChange(
      slotLabel: slot.label,
      date: slot.date,
      beforeTitle: b?.recipe.name ?? '—',
      afterTitle: a?.recipe.name ?? '—',
    ));
  }
  final groceryBefore =
      ((values['groceryBefore'] as List?) ?? []).cast<Map<String, Object?>>();
  final groceryAfter =
      ((values['groceryAfter'] as List?) ?? []).cast<Map<String, Object?>>();
  final delta = groceryDelta(groceryBefore, groceryAfter);
  return showGuidedPlanReview(
    context,
    changes: changes,
    rationale: rationale,
    nutritionDelta: nutritionDeltaFor(
      before: before,
      after: after,
      context: context,
    ),
    groceryAdditions: delta.additions,
    groceryRemovals: delta.removals,
    onApply: () async {
      final container = ProviderScope.containerOf(context);
      await container.read(guidedPlanServiceProvider).accept(
            draftId: draft.id,
            expectedDraftRevision: draft.revision,
            expectedPlanRevision: values['expectedPlanRevision']! as int,
            requestId: 'guided:accept:${draft.id}:${draft.revision}',
          );
      container.invalidate(nutritionProfileProvider);
      container.invalidate(planForDateProvider);
      container.invalidate(mealContentProvider);
      container.invalidate(groceryListProvider);
      container.invalidate(planMealStateProvider);
    },
    onKeep: () => Navigator.pop(context, false),
  );
}
