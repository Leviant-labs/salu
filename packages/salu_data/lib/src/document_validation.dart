import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import 'health_outbox_store.dart';
import 'snapshot_codec.dart';

/// Validate domain shapes before writes and before any restore can reach live data.
void validateUserDocument(String collection, Map<String, Object?> data) {
  switch (collection) {
    case 'nutrition-profile-v1':
      NutritionProfile.fromJson(data);
    case 'meal-content-v1':
      validateMealContent(data);
    case 'plan-meal-state-v1':
      if (data['schemaVersion'] != 1 ||
          data['planDocumentId'] is! String ||
          (data['planDocumentId']! as String).isEmpty ||
          data['slotId'] is! String || (data['slotId']! as String).isEmpty ||
          data['selectionSignature'] is! String ||
          (data['selectionSignature']! as String).isEmpty ||
          !const ['consumed', 'skipped'].contains(data['state'])) {
        throw const FormatException('Invalid planned meal feedback');
      }
      DiaryDate.parse(data['date']! as String);
      if (data['state'] == 'consumed') {
        if (data['entryId'] is! String ||
            (data['entryId']! as String).isEmpty ||
            !Exact.fromJson(Map<String, Object?>.from(data['portions']! as Map))
                .positive) {
          throw const FormatException('Invalid consumed meal link');
        }
      } else if (data['entryId'] != null || data['portions'] != null) {
        throw const FormatException('Skipped meals cannot record intake');
      }
    case 'health-outbox':
      decodeHealthOutbox(data['id']! as String, jsonEncode(data));
    case 'meal-draft-v1':
      final status = DraftStatus.values.byName(data['status']! as String);
      if (data['values'] is! Map ||
          (status == DraftStatus.committed &&
              (data['confirmationRequestId'] is! String ||
                  (data['confirmationRequestId']! as String).isEmpty))) {
        throw const FormatException('Invalid draft');
      }
    case 'favorite-food':
      if (data['favorite'] is! bool) {
        throw const FormatException('Invalid favourite flag');
      }
      foodFromSnapshot(Map<String, Object?>.from(data['food']! as Map));
    case 'saved-meal':
      if ((data['name']! as String).trim().isEmpty ||
          (data['items']! as List).isEmpty) {
        throw const FormatException('Empty saved meal');
      }
      for (final item in data['items']! as List) {
        loggedItemFromSnapshot(Map<String, Object?>.from(item as Map));
      }
    case 'target':
      DeclaredTarget.fromJson(data);
    case 'recipe':
      recipeFromSnapshot(data);
    case 'profile':
      SafetyProfile.fromJson(data);
    case 'health-declaration':
      AdultHealthDeclaration.fromJson(data);
    case 'day':
      DiaryCompleteness.values.byName(data['completeness']! as String);
    case 'weight':
    case 'water':
      final value =
          Exact.fromJson(Map<String, Object?>.from(data['value']! as Map));
      if (!value.positive ||
          data['unit'] != (collection == 'water' ? 'ml' : 'kg')) {
        throw const FormatException('Invalid tracking amount');
      }
      DateTime.parse(data['time']! as String);
    case 'batch':
      final r =
          recipeFromSnapshot(Map<String, Object?>.from(data['recipe']! as Map));
      CookedBatch(
          id: 'validate',
          recipe: r,
          revision: 1,
          available: Exact.fromJson(
              Map<String, Object?>.from(data['available']! as Map)),
          unit: FoodUnit.values.byName(data['unit']! as String),
          finishedWeightG: data['finishedWeightG'] == null
              ? null
              : Exact.fromJson(
                  Map<String, Object?>.from(data['finishedWeightG']! as Map)),
          allocations: [
            for (final a in data['allocations']! as List)
              BatchAllocation(
                  (a as Map)['id']! as String,
                  Exact.fromJson(
                      Map<String, Object?>.from(a['amount']! as Map)),
                  a['status']! as String,
                  intakeRequestId: a['intakeRequestId'] as String?)
          ]);
    case 'plan':
      final ids = <String>{};
      final batchAllocations = <(String, String)>{};
      for (final item in data['meals']! as List) {
        final m = Map<String, Object?>.from(item as Map);
        final recipe =
            recipeFromSnapshot(Map<String, Object?>.from(m['recipe']! as Map));
        DiaryDate.parse(m['date']! as String);
        if (!ids.add(m['slot']! as String)) {
          throw const FormatException('Duplicate meal slot');
        }
        final useData = m['batchUse'];
        PlannedBatchUse? use;
        if (useData != null) {
          final useMap = Map<String, Object?>.from(useData as Map);
          use = PlannedBatchUse(
              useMap['batchId']! as String,
              useMap['batchRevision']! as int,
              useMap['allocationId']! as String);
          if (!batchAllocations.add((use.batchId, use.allocationId))) {
            throw const FormatException('Duplicate batch allocation');
          }
        }
        PlannedMeal(
            MealSlot(m['slot']! as String, m['date']! as String,
                m['label']! as String),
            recipe,
            Exact.fromJson(Map<String, Object?>.from(m['portions']! as Map)),
            pinned: m['pinned'] == true,
            batchUse: use);
      }
      break;
    default:
      break;
  }
}

/// Authored recipe instructions, separate from the frozen nutrient definition.
void validateMealContent(Map<String, Object?> data) {
  if (data['schemaVersion'] != 1 ||
      data['recipeId'] is! String || (data['recipeId']! as String).isEmpty ||
      data['revision'] is! int || (data['revision']! as int) < 1 ||
      data['coldSuitable'] is! bool ||
      !const ['lowerCost', 'standard'].contains(data['costTier'])) {
    throw const FormatException('Invalid meal content');
  }
  if (data.containsKey('grainComposition') &&
      !const ['wholeGrain', 'refinedGrain']
          .contains(data['grainComposition'])) {
    throw const FormatException('Invalid grain composition metadata');
  }
  final labels = data['mealLabels'];
  if (labels is! List || labels.isEmpty ||
      labels.toSet().length != labels.length ||
      labels.any((label) =>
          !const ['breakfast','lunch','snack','dinner'].contains(label))) {
    throw const FormatException('Invalid meal categories');
  }
  for (final field in ['titles', 'descriptions', 'instructions']) {
    final localized = data[field];
    if (localized is! Map) throw FormatException('Missing meal $field');
    for (final locale in ['en', 'pt-PT']) {
      final value = localized[locale];
      if (field == 'instructions') {
        if (value is! List || value.isEmpty ||
            value.any((step) => step is! String || step.trim().isEmpty)) {
          throw const FormatException('Missing meal instructions');
        }
      } else if (value is! String || value.trim().isEmpty) {
        throw FormatException('Missing meal $field');
      }
    }
  }
}
