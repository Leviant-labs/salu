import 'package:flutter/services.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// The authored starter-meal asset bundled with this build.
///
/// This is Salu recipe content, not a nutrient fixture. Nutrition comes only
/// from the bundled INSA catalogue rows it references by exact id.
const String bundledStarterMealsAsset =
    'assets/meals/starter_meals_v1.json';

/// Reads the bundled starter-meal asset bytes.
Future<List<int>> loadBundledStarterMeals() async {
  final data = await rootBundle.load(bundledStarterMealsAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Decodes the bundled starter-meal asset.
Future<StarterMealAsset> loadStarterMealAsset() async {
  final bytes = await loadBundledStarterMeals();
  return decodeStarterMealAsset(bytes);
}

/// Outcome of the startup starter-library attempt.
///
/// A failure is retained so the UI can offer a repair action; it never
/// prevents the app from starting with existing user data.
final class StarterMealProvisioningOutcome {
  const StarterMealProvisioningOutcome.installed(
      StarterMealLibraryProvision this.provision)
      : failure = null;

  const StarterMealProvisioningOutcome.failed(this.failure)
      : provision = null;

  final StarterMealLibraryProvision? provision;
  final Object? failure;
}

/// Resolves exact `insa-bdca:<code>` ids against the catalogue.
Future<Map<String, Food>> resolveStarterMealFoods(
  AppDatabase db,
  List<int> codes, {
  Future<Food?> Function(String id)? lookup,
}) async {
  final find = lookup ?? DriftFoodRepository(db).findById;
  final foods = <String, Food>{};
  for (final code in codes) {
    final id = 'insa-bdca:$code';
    final food = await find(id);
    if (food != null) foods[id] = food;
  }
  return foods;
}

/// Ensures the starter-meal library is installed in [db].
///
/// Runs after catalogue provisioning. Every `insa-bdca:<code>` is resolved by
/// exact id first; a missing id aborts the whole install with
/// [StarterMealLibraryException] `STARTER_MEAL_SOURCE_MISSING` before any
/// write. The transaction is idempotent: an intact install is a no-op.
Future<StarterMealLibraryProvision> provisionStarterMeals(
  AppDatabase db, {
  Future<List<int>> Function()? loadMeals,
  Future<Map<String, Food>> Function(List<int> codes)? resolveFoods,
}) async {
  final bytes =
      await (loadMeals ?? loadBundledStarterMeals)();
  final asset = decodeStarterMealAsset(bytes);
  final codes = <int>{
    for (final meal in asset.meals)
      for (final ing in meal.ingredients) int.parse(ing.sourceCode),
  }.toList();
  final foods = await (resolveFoods ?? ((List<int> c) => resolveStarterMealFoods(db, c)))(codes);
  return StarterMealLibrary(db).ensureInstalled(
    asset: asset,
    resolveFoods: () async => foods,
  );
}
