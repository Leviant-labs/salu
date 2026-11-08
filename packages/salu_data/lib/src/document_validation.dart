import 'package:salu_core/salu_core.dart';
import 'snapshot_codec.dart';

/// Validate domain shapes before writes and before any restore can reach live data.
void validateUserDocument(String collection, Map<String, Object?> data) {
  switch (collection) {
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
          finishedWeightG: Exact.fromJson(
              Map<String, Object?>.from(data['finishedWeightG']! as Map)),
          allocations: [
            for (final a in data['allocations']! as List)
              BatchAllocation(
                  (a as Map)['id']! as String,
                  Exact.fromJson(
                      Map<String, Object?>.from(a['amount']! as Map)),
                  a['status']! as String)
          ]);
    case 'plan':
      final ids = <String>{};
      for (final item in data['meals']! as List) {
        final m = Map<String, Object?>.from(item as Map);
        final recipe =
            recipeFromSnapshot(Map<String, Object?>.from(m['recipe']! as Map));
        DiaryDate.parse(m['date']! as String);
        if (!ids.add(m['slot']! as String)) {
          throw const FormatException('Duplicate meal slot');
        }
        PlannedMeal(
            MealSlot(m['slot']! as String, m['date']! as String,
                m['label']! as String),
            recipe,
            Exact.fromJson(Map<String, Object?>.from(m['portions']! as Map)),
            pinned: m['pinned'] == true);
      }
    default:
      break;
  }
}
