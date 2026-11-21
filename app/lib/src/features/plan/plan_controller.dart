import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart' hide MealSlot;

import '../../data_transfer/data_write_gate.dart';
import '../onboarding/planning_profile.dart';
import 'plan_suggestions.dart';
import 'recipe_planning.dart';
import 'week_plan.dart';

/// Coordinates weekly meal plan loading, saving, grocery updates, and
/// suggestion/reconciliation workflows.
class PlanController extends ChangeNotifier {
  PlanController({
    required this.store,
    required this.profileStore,
    this.recipePlanning,
    this.suggestions,
    this.gate,
    DateTime? initialWeek,
  }) : _week = initialWeek ?? startOfPlanWeek(DateTime.now());

  final WeekPlanStore store;
  final PlanningProfileStore profileStore;
  final RecipePlanning? recipePlanning;
  final PlanSuggestionSource? suggestions;
  final DataWriteGate? gate;

  DateTime _week;
  WeekPlan? _plan;
  bool _loadFailed = false;
  bool _saving = false;
  bool _drafting = false;
  bool _reviewing = false;
  PlanningProfile? _profile;
  Map<String, RecipeVersion> _recipes = const {};
  bool _disposed = false;

  DateTime get week => _week;
  WeekPlan? get plan => _plan;
  bool get loadFailed => _loadFailed;
  bool get saving => _saving;
  bool get drafting => _drafting;
  bool get reviewing => _reviewing;
  PlanningProfile? get profile => _profile;
  Map<String, RecipeVersion> get recipes => _recipes;
  bool get busy => _plan == null || _saving || _drafting || _reviewing;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      gate != null ? gate!.runWrite(work) : work();

  Future<void> loadProfile() async {
    try {
      final loaded = await profileStore.load();
      if (_disposed) return;
      _profile = loaded;
      _safeNotify();
    } catch (_) {
      // A missing profile does not prevent editing this week.
    }
  }

  Future<void> loadWeek(DateTime week) async {
    _week = week;
    _plan = null;
    _loadFailed = false;
    _safeNotify();
    try {
      final loadedPlan = await store.load(week);
      final loadedRecipes = await recipePlanning?.library.load();
      if (_disposed || _week != week) return;
      _plan = loadedPlan;
      if (loadedRecipes != null) {
        _recipes = {for (final recipe in loadedRecipes) recipe.key: recipe};
      }
      _safeNotify();
    } catch (_) {
      if (_disposed || _week != week) return;
      _loadFailed = true;
      _safeNotify();
    }
  }

  Future<bool> savePlan(WeekPlan next) async {
    _saving = true;
    _safeNotify();
    try {
      await _runWrite(() => store.save(next));
      if (_disposed) return false;
      _plan = next.copyWith(revision: next.revision + 1);
      _safeNotify();
      return true;
    } catch (_) {
      return false;
    } finally {
      if (!_disposed) {
        _saving = false;
        _safeNotify();
      }
    }
  }

  Future<bool> toggleGrocery(int index, bool checked) async {
    final current = _plan;
    if (current == null || index < 0 || index >= current.groceries.length) {
      return false;
    }
    final next = current.groceries.toList();
    next[index] = next[index].withChecked(checked);
    return savePlan(current.copyWith(groceries: next));
  }

  Future<bool> editGrocery({
    int? index,
    String? name,
    String details = '',
  }) async {
    final current = _plan;
    if (current == null) return false;
    final item = index == null ? null : current.groceries[index];
    final groceries = current.groceries.toList();
    if (name == null) {
      if (index == null) return false;
      groceries.removeAt(index);
    } else {
      final next = GroceryItem(
        name,
        amount: details,
        checked: item?.checked ?? false,
        requirementKey: item?.requirementKey,
        requiredGrams: item?.requiredGrams,
        override: item?.requirementKey != null,
        changed: item?.changed ?? false,
      );
      if (index == null) {
        groceries.add(next);
      } else {
        groceries[index] = next;
      }
    }
    return savePlan(current.copyWith(groceries: groceries));
  }

  void setDrafting(bool value) {
    _drafting = value;
    _safeNotify();
  }

  void setReviewing(bool value) {
    _reviewing = value;
    _safeNotify();
  }

  void updateRecipes(Iterable<RecipeVersion> loaded) {
    _recipes = {for (final recipe in loaded) recipe.key: recipe};
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
