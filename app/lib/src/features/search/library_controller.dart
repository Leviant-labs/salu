import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';

import '../../data_transfer/data_write_gate.dart';
import '../plan/cooked_batches.dart';
import '../plan/recipe_library.dart';
import 'food_library.dart';

/// Unified state and mutation controller for the user's Food, Meal, Recipe,
/// and Cooked Batch (Leftovers) library.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.foodLibrary,
    required this.recipeLibrary,
    required this.cookedBatches,
    this.gate,
  });

  final FoodLibrary foodLibrary;
  final RecipeLibrary recipeLibrary;
  final CookedBatches cookedBatches;
  final DataWriteGate? gate;

  List<SavedFood> _foods = const [];
  List<SavedMeal> _meals = const [];
  Set<String> _favorites = const {};
  List<RecipeVersion> _recipes = const [];
  List<StoredBatch> _batches = const [];
  String _query = '';
  bool _loading = false;
  bool _disposed = false;

  List<SavedFood> get foods => _foods;
  List<SavedMeal> get meals => _meals;
  Set<String> get favorites => _favorites;
  List<RecipeVersion> get recipes => _recipes;
  List<StoredBatch> get batches => _batches;
  String get query => _query;
  bool get loading => _loading;

  List<SavedFood> get filteredFoods {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _foods;
    return [
      for (final food in _foods)
        if (food.name.toLowerCase().contains(q) ||
            (food.barcode?.contains(q) ?? false))
          food,
    ];
  }

  List<SavedMeal> get filteredMeals {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _meals;
    return [
      for (final meal in _meals)
        if (meal.name.toLowerCase().contains(q)) meal,
    ];
  }

  List<RecipeVersion> get filteredRecipes {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _recipes;
    return [
      for (final recipe in _recipes)
        if (recipe.name.toLowerCase().contains(q)) recipe,
    ];
  }

  List<StoredBatch> get filteredBatches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _batches;
    return [
      for (final row in _batches)
        if (row.batch.recipe.name.toLowerCase().contains(q)) row,
    ];
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      gate != null ? gate!.runWrite(work) : work();

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _safeNotify();
  }

  Future<void> refresh() async {
    _loading = true;
    _safeNotify();
    try {
      final results = await Future.wait([
        foodLibrary.foods(),
        foodLibrary.meals(),
        foodLibrary.favorites(),
        recipeLibrary.load(),
        cookedBatches.available(),
      ]);
      if (_disposed) return;
      _foods = results[0] as List<SavedFood>;
      _meals = results[1] as List<SavedMeal>;
      _favorites = results[2] as Set<String>;
      _recipes = results[3] as List<RecipeVersion>;
      _batches = results[4] as List<StoredBatch>;
    } finally {
      if (!_disposed) {
        _loading = false;
        _safeNotify();
      }
    }
  }

  Future<void> toggleFavorite(String id) async {
    await _runWrite(() => foodLibrary.toggleFavorite(id));
    if (_disposed) return;
    _favorites = await foodLibrary.favorites();
    _safeNotify();
  }

  Future<void> saveFood(SavedFood food) async {
    await _runWrite(() => foodLibrary.saveFood(food));
    if (_disposed) return;
    _foods = await foodLibrary.foods();
    _safeNotify();
  }

  Future<void> saveMeal(SavedMeal meal) async {
    await _runWrite(() => foodLibrary.saveMeal(meal));
    if (_disposed) return;
    _meals = await foodLibrary.meals();
    _safeNotify();
  }

  Future<void> addRecipe(RecipeVersion recipe) async {
    await _runWrite(() => recipeLibrary.add(recipe));
    if (_disposed) return;
    _recipes = await recipeLibrary.load();
    _safeNotify();
  }

  Future<void> addBatch(String id, CookedRecipeBatch batch) async {
    await _runWrite(() => cookedBatches.add(id, batch));
    if (_disposed) return;
    _batches = await cookedBatches.available();
    _safeNotify();
  }

  Future<bool> logBatch(String id, MealPortion portion, PhotoMeal meal) async {
    final logged = await _runWrite(() => cookedBatches.log(id, portion, meal));
    if (_disposed) return logged;
    _batches = await cookedBatches.available();
    _safeNotify();
    return logged;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
