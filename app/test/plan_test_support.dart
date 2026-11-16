import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// Minimal deterministic planner fixtures for widget tests. Nutrients are
/// intentionally empty unless a test makes a numeric range binding, so no
/// adequacy claim is implied by the fixture.
Food planFood(String id,
        {String? name,
        Set<String>? allergens = const {},
        Preparation preparation = Preparation.raw,
        Map<NutrientKey, NutrientValue> nutrients = const {}}) =>
    Food(
        id: 'custom:$id',
        name: name ?? id,
        per100g: NutrientProfile(nutrients),
        source: FoodSource(dataset: 'custom-user-entry', datasetId: id),
        quality: DataQuality.userEntered,
        allergens: allergens,
        preparation: preparation);

RecipeVersion planRecipe({
  String id = 'soup',
  int revision = 1,
  String? name,
  String servings = '2',
  int minutes = 20,
  List<RecipeIngredient>? ingredients,
}) {
  final items = ingredients ??
      [
        RecipeIngredient(planFood('beans'), Exact.parse('300')),
      ];
  return RecipeVersion(
      id: id,
      revision: revision,
      name: name ?? id,
      servings: Exact.parse(servings),
      minutes: minutes,
      ingredients: items,
      allergens: items.any((i) => i.food.allergens == null)
          ? null
          : items.expand((i) => i.food.allergens!).toSet());
}

Future<void> seedRecipe(AppDatabase db, RecipeVersion recipe) async {
  // Plan save treats an active catalogue row as the current definition for
  // every provenance, so each fixture ingredient needs a real row.
  await DriftFoodRepository(db).replaceCatalogueBatch(
      [for (final ingredient in recipe.ingredients) ingredient.food]);
  await LocalWorkspace(db).put(
      requestId: 'test:recipe:${recipe.id}:${recipe.revision}',
      collection: 'recipe',
      id: '${recipe.id}:${recipe.revision}',
      expectedRevision: 0,
      data: recipeSnapshot(recipe));
}

Map<String, Object?> planAllocation(String id, String amount, String status) =>
    {'id': id, 'amount': Exact.parse(amount).toJson(), 'status': status};

/// Seeds cooked stock. Gram batches require a measured finished weight;
/// serving batches store an exact serving count and never invent grams.
Future<void> seedBatch(AppDatabase db,
        {required String id,
        required RecipeVersion recipe,
        String available = '600',
        String? finished = '600',
        FoodUnit unit = FoodUnit.g,
        List<Map<String, Object?>> allocations = const []}) async {
  if (unit == FoodUnit.g && finished == null) {
    throw ArgumentError('Gram batches need a measured finished weight');
  }
  await DriftFoodRepository(db).replaceCatalogueBatch(
      [for (final ingredient in recipe.ingredients) ingredient.food]);
  await LocalWorkspace(db).put(
      requestId: 'test:batch:$id',
      collection: 'batch',
      id: id,
      expectedRevision: 0,
      data: {
        'recipe': recipeSnapshot(recipe),
        'available': Exact.parse(available).toJson(),
        if (unit == FoodUnit.g)
          'finishedWeightG': Exact.parse(finished!).toJson(),
        'unit': unit.name,
        'allocations': allocations
      });
}

Future<void> seedServingBatch(AppDatabase db,
        {required String id,
        required RecipeVersion recipe,
        String available = '2',
        List<Map<String, Object?>> allocations = const []}) =>
    seedBatch(db,
        id: id,
        recipe: recipe,
        unit: FoodUnit.serving,
        available: available,
        finished: null,
        allocations: allocations);

Future<void> seedSafety(AppDatabase db, Set<String> exclusions) =>
    LocalWorkspace(db).put(
        requestId: 'test:safety',
        collection: 'profile',
        id: 'safety',
        expectedRevision: 0,
        data: SafetyProfile(strictExclusions: exclusions).toJson());

/// Seeds the same `health-declaration/current` document the settings UI
/// writes. Unknown/absent conditions stay null and are never rewritten false.
Future<void> seedHealthDeclaration(
    AppDatabase db, Map<String, bool?> conditions) async {
  final prior =
      await LocalWorkspace(db).read('health-declaration', 'current');
  final revision = prior?.revision ?? 0;
  await LocalWorkspace(db).put(
      requestId: 'test:health-declaration:$revision',
      collection: 'health-declaration',
      id: 'current',
      expectedRevision: revision,
      data: {
        'schemaVersion': 1,
        'goal': AdultGoal.notDeclared.name,
        'conditions': <String, Object?>{
          for (final condition in PlanningCondition.values)
            condition.name: conditions[condition.name],
        },
        'guidancePolicy': ConditionGuidancePolicy.version,
      });
}

/// Saves the plan through the same transactional service the UI uses.
Future<PlanSaveResult> seedPlan(AppDatabase db,
        {required List<PlannedMeal> meals,
        String startDate = '2026-01-01',
        int days = 1,
        String label = 'dinner',
        List<String> portions = const ['1'],
        List<String> excludedSlotIds = const [],
        List<String> unavailableFoodIds = const [],
        int? maximumMinutes}) =>
    PlanService(db, const SystemClock(), RandomIdGenerator()).save(
        requestId: 'test:plan',
        expectedPlanRevision: 0,
        meals: meals,
        metadata: {
          'schedule': {
            'startDate': startDate,
            'days': days,
            'label': label,
            'portions': [for (final p in portions) Exact.parse(p).toJson()],
            'excludedSlotIds': excludedSlotIds
          },
          'constraints': {
            'maximumMinutes': maximumMinutes,
            'maximumRepeats': null,
            'energyMinimum': null,
            'energyMaximum': null,
            'unavailableFoodIds': unavailableFoodIds
          },
          'constraintRevision': 1,
          'relaxations': <Object?>[],
          'acceptedRelaxations': <Object?>[]
        });

Future<StoredPlan?> loadPlan(AppDatabase db) =>
    PlanService(db, const SystemClock(), RandomIdGenerator()).load();

Exact exactJson(Object? json) =>
    Exact.fromJson(Map<String, Object?>.from(json! as Map));

Map<String, Object?> asMap(Object? value) =>
    Map<String, Object?>.from(value! as Map);

List<Map<String, Object?>> asMaps(Object? value) =>
    [for (final item in value! as List) Map<String, Object?>.from(item as Map)];
