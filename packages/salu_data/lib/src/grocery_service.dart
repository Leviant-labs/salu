import 'package:salu_core/salu_core.dart' as salu_core;
import 'package:salu_core/salu_core.dart' show Exact, GroceryLine, PlannedMeal, Preparation;

import 'database/app_database.dart';
import 'workspace_store.dart';

/// One derived grocery requirement for a plan.
///
/// [key] is the override key `'<foodId>|<preparation.name>'`. [grams] is the
/// computed household requirement: the plan's raw demand multiplied by the
/// plan snapshot's household-servings multiplier. It is never the stored
/// `grams` override. [name] is the derived food name used as the fallback
/// when the name override is blank/invalid. [gramsOverrideValid] is false
/// when a stored override fails to parse; the computed requirement is used
/// instead and the row is surfaced for correction rather than silently
/// becoming a source quantity.
final class GroceryEntry {
  const GroceryEntry({
    required this.key,
    required this.foodId,
    required this.name,
    required this.grams,
    required this.preparation,
    required this.checked,
    required this.removed,
    required this.gramsOverrideValid,
    required this.hasGramOverride,
    required this.hasNameOverride,
  });
  final String key;
  final String foodId;
  final String name;
  final Exact grams;
  final Preparation preparation;
  final bool checked;
  final bool removed;
  final bool gramsOverrideValid;
  final bool hasGramOverride;
  final bool hasNameOverride;
}

/// A generated grocery line plus its retained overrides, or one manual row.
final class GroceryLineView {
  const GroceryLineView({
    required this.entry,
    required this.name,
    required this.grams,
    required this.checked,
    required this.removed,
    required this.gramsOverrideValid,
  });
  final GroceryEntry entry;
  final String name;
  final Exact grams;
  final bool checked;
  final bool removed;
  final bool gramsOverrideValid;
}

/// Result of folding one plan's requirements against its overlay.
final class GroceryList {
  const GroceryList({
    required this.visible,
    required this.removed,
    required this.householdServings,
    required this.planDocumentId,
  });
  final List<GroceryLineView> visible;
  final List<GroceryLineView> removed;
  final int householdServings;
  final String planDocumentId;
}

/// Guided/legacy grocery overlays derived from a plan's meals.
///
/// Legacy current-plan overlays live in `groceries/current`; each guided
/// week's overlays live in `groceries/<planDocumentId>`, so viewing or
/// accepting next week cannot erase this week's checks. `groceries/manual`
/// is the shared user-added map.
final class GroceryService {
  GroceryService(this.db) : _workspace = LocalWorkspace(db);
  final AppDatabase db;
  final LocalWorkspace _workspace;

  static String overlayDocumentIdFor(String planDocumentId) =>
      planDocumentId == 'current' ? 'current' : planDocumentId;

  static String groceryKey(String foodId, Preparation preparation) =>
      '$foodId|${preparation.name}';

  /// Normalizes a stored overlay value: a bare bool becomes `{checked: v}` so
  /// legacy documents keep loading, mirroring the plan screen `_groceryItem`.
  static Map<String, Object?> normalizeItem(Object? raw) {
    if (raw is Map) return Map<String, Object?>.from(raw);
    if (raw is bool) return {'checked': raw};
    return <String, Object?>{};
  }

  /// Raw base requirements before household scaling (stock excluded).
  static List<GroceryLine> baseRequirements(List<PlannedMeal> meals) =>
      salu_core.groceriesFor(meals);

  /// Household requirements: base grams scaled by [householdServings].
  /// Stocked meals stay excluded; their ingredients are not re-required.
  static List<GroceryLine> requirementsFor(
      List<PlannedMeal> meals, int householdServings) {
    if (householdServings <= 0) {
      throw ArgumentError('householdServings must be positive');
    }
    final multiplier = Exact.parse('$householdServings');
    return [
      for (final line in salu_core.groceriesFor(meals))
        GroceryLine(line.foodId, line.name, line.grams * multiplier,
            line.preparation)
    ];
  }
  /// Household multiplier recorded on the plan snapshot, or 1 for a legacy
  /// plan without guided metadata.
  static int householdServingsForPlan(Map<String, Object?> document) {
    final guided = document['guided'];
    if (guided is Map) {
      final raw = guided['householdServings'];
      if (raw is int && raw > 0) return raw;
    }
    return 1;
  }

  static GroceryList _foldLines({
    required String planDocumentId,
    required List<GroceryLine> lines,
    required Map<String, Object?> overlay,
    required int householdServings,
  }) {
    final visible = <GroceryLineView>[];
    final removed = <GroceryLineView>[];
    for (final line in lines) {
      final key = groceryKey(line.foodId, line.preparation);
      final item = normalizeItem(overlay[key]);
      final override = item['grams'];
      var grams = line.grams;
      var gramsValid = true;
      var hasOverride = false;
      if (override is Map) {
        hasOverride = true;
        try {
          grams = Exact.fromJson(Map<String, Object?>.from(override));
        } catch (_) {
          grams = line.grams;
          gramsValid = false;
        }
      }
      final rawName = item['name'];
      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : line.name;
      final view = GroceryLineView(
        entry: GroceryEntry(
          key: key,
          foodId: line.foodId,
          name: name,
          grams: grams,
          preparation: line.preparation,
          checked: item['checked'] == true,
          removed: item['removed'] == true,
          gramsOverrideValid: gramsValid,
          hasGramOverride: hasOverride,
          hasNameOverride: rawName is String && rawName.trim().isNotEmpty,
        ),
        name: name,
        grams: grams,
        checked: item['checked'] == true,
        removed: item['removed'] == true,
        gramsOverrideValid: gramsValid,
      );
      if (view.removed) {
        removed.add(view);
      } else {
        visible.add(view);
      }
    }
    return GroceryList(
      visible: visible,
      removed: removed,
      householdServings: householdServings,
      planDocumentId: planDocumentId,
    );
  }

  /// Folds [meals] (household 1) against [overlay].
  static GroceryList fold({
    required String planDocumentId,
    required List<PlannedMeal> meals,
    required Map<String, Object?> overlay,
  }) =>
      _foldLines(
        planDocumentId: planDocumentId,
        lines: baseRequirements(meals),
        overlay: overlay,
        householdServings: 1,
      );

  /// Folds with the plan snapshot household multiplier on computed
  /// requirements (never on stored overrides).
  static GroceryList foldForPlan({
    required String planDocumentId,
    required List<PlannedMeal> meals,
    required Map<String, Object?> overlay,
    required Map<String, Object?> planDocument,
  }) {
    final household = householdServingsForPlan(planDocument);
    return _foldLines(
      planDocumentId: planDocumentId,
      lines: requirementsFor(meals, household),
      overlay: overlay,
      householdServings: household,
    );
  }

  /// Reads one plan's grocery list: requirements scaled by the snapshot
  /// household multiplier, folded against that plan's overlay document.
  Future<GroceryList> groceriesFor(
      {required String planDocumentId,
      required List<PlannedMeal> meals}) async {
    final overlay =
        await _workspace.read('groceries', overlayDocumentIdFor(planDocumentId));
    final planDoc = await _workspace.read('plan', planDocumentId);
    final document = planDoc?.data ?? const <String, Object?>{};
    return foldForPlan(
      planDocumentId: planDocumentId,
      meals: meals,
      overlay: overlay?.data ?? const {},
      planDocument: document,
    );
  }

  /// The selected plan's computed household requirements (unfolded).
  Future<List<GroceryLine>> requirementsForPlan(
      {required String planDocumentId,
      required List<PlannedMeal> meals}) async {
    final planDoc = await _workspace.read('plan', planDocumentId);
    final household =
        planDoc == null ? 1 : householdServingsForPlan(planDoc.data);
    return requirementsFor(meals, household);
  }

  /// The shared user-added manual grocery map (`groceries/manual`),
  /// normalized so legacy bare-bool rows load.
  Future<Map<String, Map<String, Object?>>> manualGroceries() async {
    final doc = await _workspace.read('groceries', 'manual');
    return {
      for (final e in doc?.data.entries ?? const <MapEntry<String, Object?>>[])
        e.key: normalizeItem(e.value)
    };
  }

  /// Reconciles the overlay after a plan change.
  ///
  /// No-longer-required generated keys are pruned. Retained keys keep their
  /// name/removed/grams overrides; `checked` is retained only when the
  /// derived requirement is unchanged, otherwise reset to false (a new key
  /// starts unchecked). Manual rows (`groceries/manual`) are untouched.
  /// Callers run this inside their acceptance transaction.
  Future<void> reconcileOverlayWithPrior({
    required String planDocumentId,
    required List<PlannedMeal> priorMeals,
    required List<PlannedMeal> newMeals,
    required Map<String, Object?> priorPlanDocument,
    required Map<String, Object?> newPlanDocument,
    required String requestId,
    int? expectedRevision,
  }) async {
    final docId = overlayDocumentIdFor(planDocumentId);
    final prior = await _workspace.read('groceries', docId);
    final old = {
      for (final e in prior?.data.entries ?? const <MapEntry<String, Object?>>[])
        e.key: normalizeItem(e.value)
    };
    final priorRequirements =
        requirementsFor(priorMeals, householdServingsForPlan(priorPlanDocument));
    final priorByKey = {
      for (final line in priorRequirements)
        groceryKey(line.foodId, line.preparation): line.grams
    };
    final newRequirements =
        requirementsFor(newMeals, householdServingsForPlan(newPlanDocument));
    final newByKey = {
      for (final line in newRequirements)
        groceryKey(line.foodId, line.preparation): line.grams
    };
    final next = <String, Object?>{};
    for (final key in newByKey.keys) {
      final item = old[key] ?? <String, Object?>{};
      final entry = <String, Object?>{...item};
      if (entry['checked'] == true && priorByKey[key] != newByKey[key]) {
        entry['checked'] = false;
      }
      next[key] = entry;
    }
    await _workspace.put(
      requestId: requestId,
      collection: 'groceries',
      id: docId,
      expectedRevision: expectedRevision ?? prior?.revision ?? 0,
      data: next,
    );
  }

  /// Single-argument reconcile for callers without prior plan meals: retained
  /// rows keep every override (checked included); only pruned keys change.
  Future<void> reconcileOverlay({
    required String planDocumentId,
    required List<PlannedMeal> newMeals,
    required Map<String, Object?> planDocument,
    required String requestId,
    int? expectedRevision,
  }) async {
    final docId = overlayDocumentIdFor(planDocumentId);
    final prior = await _workspace.read('groceries', docId);
    final old = {
      for (final e in prior?.data.entries ?? const <MapEntry<String, Object?>>[])
        e.key: normalizeItem(e.value)
    };
    final newRequirements =
        requirementsFor(newMeals, householdServingsForPlan(planDocument));
    final newKeys = {
      for (final line in newRequirements)
        groceryKey(line.foodId, line.preparation),
    };
    final next = <String, Object?>{
      for (final key in newKeys) key: old[key] ?? <String, Object?>{},
    };
    await _workspace.put(
      requestId: requestId,
      collection: 'groceries',
      id: docId,
      expectedRevision: expectedRevision ?? prior?.revision ?? 0,
      data: next,
    );
  }

  Future<void> saveGenerated({required String planDocumentId,
      required String requestId,required int expectedRevision,
      required Map<String,Object?> data}) async {
    await _workspace.put(requestId:requestId,collection:'groceries',
        id:overlayDocumentIdFor(planDocumentId),expectedRevision:expectedRevision,
        data:data);
  }

  Future<void> saveManual({required String requestId,
      required int expectedRevision,required Map<String,Object?> data}) async {
    await _workspace.put(requestId:requestId,collection:'groceries',id:'manual',
        expectedRevision:expectedRevision,data:data);
  }
}
