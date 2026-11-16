import 'nutrition_profile.dart';
import 'planning.dart';
import 'time.dart';

/// The single highest-priority offline action for Today.
///
/// Pure value: the app persists dismissals keyed by [dismissalKey] and passes
/// them back in. No I/O, scheduling, AI, nutrient-shortfall inference, or
/// intake compensation lives here.
enum RecommendationAction {
  completeSetup,
  replaceMeals,
  reviewPreferences,
  createNextWeek,
}

/// One actionable recommendation (or `null` when none is warranted).
final class DailyRecommendation {
  const DailyRecommendation({
    required this.action,
    required this.reasonCode,
    required this.slotIds,
    required this.dependencyRevisions,
    required this.dismissalKey,
  });

  final RecommendationAction action;

  /// Stable code, e.g. `profile-required`, `disliked-upcoming`,
  /// `profile-plan-mismatch`, `cold-lunch-mismatch`, `week-ended`.
  final String reasonCode;

  /// Affected slots, in plan order; may be empty for setup actions.
  final List<String> slotIds;

  /// Revisions the recommendation depends on.
  final Map<String, int> dependencyRevisions;

  /// `'$reasonCode|$date|profile:$profileRevision|plan:$planRevision|slots:${slotIds.join(',')}'`.
  final String dismissalKey;

  static String dismissalKeyFor({
    required String reasonCode,
    required DiaryDate date,
    required int profileRevision,
    required int planRevision,
    required List<String> slotIds,
  }) =>
      '$reasonCode|${date.toIso()}|profile:$profileRevision|plan:$planRevision|slots:${slotIds.join(',')}';
}

/// Pure offline recommender for Today.
final class DailyRecommendationService {
  const DailyRecommendationService();

  /// Returns one highest-priority actionable recommendation or `null`.
  ///
  /// Priority: (1) finish an unfinished profile/plan; (2) replace a disliked
  /// upcoming meal; (3) resolve a plan/profile mismatch; (4) prepare a cold
  /// lunch when configured and mismatched; (5) offer next-week review at end
  /// of week. A dismissed recommendation for the same `(reason, slot/profile
  /// revision, date)` is suppressed until its underlying context changes.
  ///
  /// [slotStates] maps slotId to `consumed`/`skipped`/anything else (pending).
  /// [coldSuitableByRecipeId] maps recipeId to its `coldSuitable` flag.
  /// Never infers nutrient shortfalls from incomplete logs.
  DailyRecommendation? recommend({
    required DiaryDate date,
    required NutritionProfile? profile,
    required int profileRevision,
    required int planRevision,
    required int? planProfileRevision,
    required List<PlannedMeal> meals,
    required Map<String, String> slotStates,
    required Map<String, bool> coldSuitableByRecipeId,
    required Set<String> dismissedKeys,
  }) {
    DailyRecommendation? candidate(
        RecommendationAction action, String reason, List<String> slots) {
      final key = DailyRecommendation.dismissalKeyFor(
        reasonCode: reason,
        date: date,
        profileRevision: profileRevision,
        planRevision: planRevision,
        slotIds: slots,
      );
      if (dismissedKeys.contains(key)) return null;
      return DailyRecommendation(
        action: action,
        reasonCode: reason,
        slotIds: List<String>.unmodifiable(slots),
        dependencyRevisions: Map<String, int>.unmodifiable({
          'profile': profileRevision,
          'plan': planRevision,
          if (planProfileRevision != null) 'planProfile': planProfileRevision,
        }),
        dismissalKey: key,
      );
    }

    final todayIso = date.toIso();
    final todayMeals = [
      for (final meal in meals) if (meal.slot.date == todayIso) meal
    ];

    bool isPending(PlannedMeal meal) {
      final state = slotStates[meal.slot.id];
      return state != 'consumed' && state != 'skipped';
    }

    // 1. Finish setup: missing profile or no meals at all.
    if (profile == null || meals.isEmpty) {
      final reason = profile == null ? 'profile-required' : 'plan-required';
      return candidate(RecommendationAction.completeSetup, reason, const []);
    }

    // 2. Replace a disliked upcoming meal (today).
    for (final meal in todayMeals) {
      if (isPending(meal) &&
          profile.dislikedRecipeIds.contains(meal.recipe.id)) {
        final result = candidate(RecommendationAction.replaceMeals,
            'disliked-upcoming', [meal.slot.id]);
        if (result != null) return result;
      }
    }

    // 3. Plan/profile mismatch.
    if (planProfileRevision != null &&
        planProfileRevision != profileRevision) {
      final result = candidate(RecommendationAction.reviewPreferences,
          'profile-plan-mismatch', const []);
      if (result != null) return result;
    }

    // 4. Cold lunch when configured and mismatched.
    if (profile.coldLunches) {
      for (final meal in todayMeals) {
        if (isPending(meal) &&
            meal.slot.label == 'lunch' &&
            coldSuitableByRecipeId[meal.recipe.id] == false) {
          final result = candidate(RecommendationAction.replaceMeals,
              'cold-lunch-mismatch', [meal.slot.id]);
          if (result != null) return result;
        }
      }
    }

    // 5. Offer next-week review at end of week.
    final dates = meals.map((meal) => meal.slot.date).toList()..sort();
    if (dates.isNotEmpty && dates.last == todayIso) {
      return candidate(RecommendationAction.createNextWeek, 'week-ended',
          [for (final meal in todayMeals) meal.slot.id]);
    }

    return null;
  }
}
