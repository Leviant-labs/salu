import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food _food(String id) => Food(
      id: id,
      name: id,
      per100g: NutrientProfile({}),
      source: FoodSource(dataset: 'test', datasetId: id),
      allergens: const <String>{},
    );

RecipeVersion _recipe(String id) => RecipeVersion(
      id: id,
      revision: 1,
      name: id,
      ingredients: [RecipeIngredient(_food('f-$id'), Exact.parse('100'))],
      servings: Exact.one,
      minutes: 10,
    );

PlannedMeal _meal(String slot, String date, String label, String recipe) =>
    PlannedMeal(MealSlot(slot, date, label), _recipe(recipe), Exact.one);

NutritionProfile _profile({bool coldLunches = false, Set<String> disliked = const {}}) =>
    NutritionProfile(
      goal: AdultGoal.maintainWeight,
      coldLunches: coldLunches,
      dislikedRecipeIds: disliked,
    );

class _UseProfile { const _UseProfile(); }

void main() {
  const service = DailyRecommendationService();
  final date = DiaryDate(2026, 11, 12);

  DailyRecommendation? recommend({
    Object? profile = const _UseProfile(),
    int profileRevision = 3,
    int planRevision = 5,
    int? planProfileRevision = 3,
    List<PlannedMeal>? meals,
    Map<String, String> slotStates = const {},
    Map<String, bool> cold = const {},
    Set<String> dismissed = const {},
  }) =>
      service.recommend(
        date: date,
        profile: identical(profile, const _UseProfile()) ? _profile() : profile as NutritionProfile?,
        profileRevision: profileRevision,
        planRevision: planRevision,
        planProfileRevision: planProfileRevision,
        meals: meals ??
            [_meal('a', '2026-11-12', 'lunch', 'r1')],
        slotStates: slotStates,
        coldSuitableByRecipeId: cold,
        dismissedKeys: dismissed,
      );

  group('priority order', () {
    test('missing profile beats everything', () {
      final result = recommend(
        profile: null,
        meals: [_meal('a', '2026-11-12', 'lunch', 'r1')],
      );
      expect(result?.action, RecommendationAction.completeSetup);
      expect(result?.reasonCode, 'profile-required');
    });

    test('empty meals means plan required', () {
      final result = recommend(meals: []);
      expect(result?.action, RecommendationAction.completeSetup);
      expect(result?.reasonCode, 'plan-required');
    });

    test('disliked upcoming beats mismatch and cold lunch', () {
      final result = recommend(
        profile: _profile(coldLunches: true, disliked: {'r1'}),
        planProfileRevision: 1,
        cold: {'r1': false},
      );
      expect(result?.reasonCode, 'disliked-upcoming');
      expect(result?.action, RecommendationAction.replaceMeals);
      expect(result?.slotIds, ['a']);
    });

    test('mismatch beats cold lunch', () {
      final result = recommend(
        profile: _profile(coldLunches: true),
        planProfileRevision: 1,
        cold: {'r1': false},
      );
      expect(result?.reasonCode, 'profile-plan-mismatch');
      expect(result?.action, RecommendationAction.reviewPreferences);
    });

    test('cold lunch mismatch beats week-ended', () {
      final result = recommend(
        profile: _profile(coldLunches: true),
        cold: {'r1': false},
      );
      expect(result?.reasonCode, 'cold-lunch-mismatch');
    });

    test('week end offers next week', () {
      final result = recommend();
      // Single meal on today is also the latest date -> week-ended.
      expect(result?.reasonCode, 'week-ended');
      expect(result?.action, RecommendationAction.createNextWeek);
    });

    test('mid-week healthy plan returns null', () {
      final result = recommend(meals: [
        _meal('a', '2026-11-12', 'lunch', 'r1'),
        _meal('b', '2026-11-13', 'lunch', 'r2'),
      ]);
      expect(result, isNull);
    });
  });

  group('dismissals', () {
    test('dismissed key suppresses until context changes', () {
      final first = recommend(profile: null)!;
      final suppressed = recommend(
        profile: null,
        dismissed: {first.dismissalKey},
      );
      expect(suppressed, isNull);
      final nextDay = service.recommend(
        date: DiaryDate(2026, 11, 13),
        profile: null,
        profileRevision: 3,
        planRevision: 5,
        planProfileRevision: null,
        meals: const [],
        slotStates: const {},
        coldSuitableByRecipeId: const {},
        dismissedKeys: {first.dismissalKey},
      );
      expect(nextDay, isNotNull);
    });

    test('dismissed recommendation allows the next applicable action', () {
      final profile = _profile(coldLunches: true, disliked: {'r1'});
      final first = recommend(profile: profile, planProfileRevision: 1,
          cold: {'r1': false})!;
      final next = recommend(profile: profile, planProfileRevision: 1,
          cold: {'r1': false}, dismissed: {first.dismissalKey});
      expect(next?.reasonCode, 'profile-plan-mismatch');
    });
  });

  group('no intake inference', () {
    test('consumed and skipped slots are not pending', () {
      final result = recommend(
        profile: _profile(disliked: {'r1'}),
        slotStates: {'a': 'consumed'},
        meals: [
          _meal('a', '2026-11-12', 'lunch', 'r1'),
          _meal('b', '2026-11-13', 'lunch', 'r2'),
        ],
      );
      expect(result, isNull);
    });

    test('skipped disliked meal does not trigger replace', () {
      final result = recommend(
        profile: _profile(disliked: {'r1'}),
        slotStates: {'a': 'skipped'},
        meals: [
          _meal('a', '2026-11-12', 'lunch', 'r1'),
          _meal('b', '2026-11-13', 'lunch', 'r2'),
        ],
      );
      expect(result, isNull);
    });
  });

  group('dismissal key', () {
    test('key includes reason date revisions and slots', () {
      final key = DailyRecommendation.dismissalKeyFor(
        reasonCode: 'week-ended',
        date: date,
        profileRevision: 3,
        planRevision: 5,
        slotIds: ['a', 'b'],
      );
      expect(key, 'week-ended|2026-11-12|profile:3|plan:5|slots:a,b');
    });
  });
}
