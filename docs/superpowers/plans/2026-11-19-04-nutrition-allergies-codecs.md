# Nutrition, Allergies and Codecs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop implausible automatic nutrition, make allergy exclusions actionable, and preserve full recipe meaning across persistence.

**Architecture:** Core owns screening and canonical matching; app-side task parsers retain untrusted evidence and present review issues. A pure-Dart versioned recipe codec in data replaces lossy widget-adjacent serialization without rewriting historical intake.

**Tech Stack:** Flutter 3.44.0, plain Dart domain tests, Drift documents, existing recipe/item models.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`, sections 2 and 6; nutrition policy remains governed by `docs/nutrition-engine-spec.md`.

## Global Constraints

- Flutter is pinned to `3.44.0`; Dart is the version bundled with that Flutter SDK.
- `salu_core` depends only on the Dart SDK; Flutter, SQLite, filesystem, cryptography, and HTTP adapters stay outside it.
- Unknown, trace, reported, measured, and estimated nutrition states survive writes, migrations, exports, and restoration.
- New meals save locally before optional inference; corrections and plan changes require review and revision-checked confirmation.
- Connecting, discovering models, restarting, or restoring never authorizes a meal/photo upload or automatic provider failover.
- Credentials live in platform secure storage and never enter ordinary documents, logs, fixtures, CSV, or archives.
- Automatic targets and adaptive expenditure remain gated; all onboarding health inputs and AI setup are optional.
- Preserve existing user changes, especially untracked `app/android/`, `app/ios/`, and `linked_list_merge/`; never stage them wholesale.

---

## File structure

- Core `domain/nutrition_screening.dart`: versioned screening, issues and safe automatic profile.
- Core `domain/allergens.dart`: canonical IDs, bilingual aliases, unresolved strict constraints.
- Data `codec/recipe_codec.dart`: complete recipe/ingredient round trips and legacy decoding.
- App meal parsers/dialogs: review issues, not new nutrition formulas.
- App recipe library/planning/onboarding: declaration entry, curation, blocked-reason presentation.
- `docs/recipe-allergen-provenance.md`: declarations actually reviewed; no blanket safety claim.

### Task 1: Screen automatic estimates and surface review issues

**Files:** Create `packages/salu_core/lib/src/domain/nutrition_screening.dart`, `packages/salu_core/test/nutrition_screening_test.dart`, `app/test/meals/nutrition_screening_test.dart`; modify core exports, `domain/photo_meal.dart`, `app/lib/src/features/meals/meal_editor_ai.dart:66–108`, `meal_editor_dialogs.dart`, `meal_editor.dart`, `packages/salu_data/lib/src/repositories/drift_photo_meal_repository.dart:89–118`.

**Interfaces:** `NutritionIssue({required String code,NutrientKey? nutrient,required bool blocksAutomaticUse})` with fields and JSON codec; `ScreenedNutrition({required NutrientProfile profile,required List<NutritionIssue> issues})`; `ScreenedNutrition screenNutrition(NutrientProfile profile,{MealPortion? portion})`, `ScreenedNutrition screenRawNutrition(Map<NutrientKey,Object?> raw,{required NutrientValue Function(double value) build,MealPortion? portion})` (so negative/non-finite raw numbers are screened and recorded as `NutritionIssue`s *before* constructing `NutrientMeasured`/`NutrientReported`/`NutrientEstimated`, whose constructors reject `< 0` and non-finite values), constant `nutritionScreeningVersion=1`. Add immutable `List<NutritionIssue> reviewIssues=const []` to `PhotoMealItem`, retaining it in every copy/revise/codec path. `parseMealEstimate` keeps its signature (with optional provenance override from plan 3) and uses `screenRawNutrition`. Extend `LabelTranscription` to include `List<NutritionIssue> issues`; update all record constructors and dialog consumers in the same task.

- [ ] **Step 1: Write a red unrealistic-value test.**

```dart
import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('implausible energy becomes unknown without losing safe protein', () {
    final result = screenNutrition(NutrientProfile({
      NutrientKey.energyKcal: NutrientEstimated(1000000, basis: 'fixture'),
      NutrientKey.proteinG: NutrientEstimated(3, basis: 'fixture'),
    }), portion: MealPortion(100, MealUnit.grams));
    expect(result.profile[NutrientKey.energyKcal].isKnown, isFalse);
    expect(result.profile[NutrientKey.proteinG].numericValue, 3);
    expect(result.issues.any((i) => i.code == 'absoluteLimit'), isTrue);
  });
}
```

Run core `dart test test/nutrition_screening_test.dart`; expect missing API. Add threshold boundaries, ml-without-density, zero, unknown, trace, finite overflow, salt/kJ ambiguity and a macro-energy-warning case that retains values. App tests pass raw model JSON through `parseMealEstimate` and verify absurd fields cannot reach counted totals. OCR tests show a warning before applying suspect label values and preserve safe fields.
- [ ] **Step 2: Implement version-1 screening and evidence preservation.** `screenRawNutrition` screens negative/non-finite raw numbers first (emitting `invalidValue` with `blocksAutomaticUse: true` and storing `NutrientUnknown`), builds valid `NutrientValue`s via `build`, and delegates to `screenNutrition`. `screenNutrition` iterates only known numeric states, enforces shared-design absolute/mass limits, and produces `absoluteLimit`, `massInconsistent`, or `macroEnergyMismatch` issues. Automatic blocked fields become `NutrientUnknown`, never zero or clamped numeric values. Macro-energy comparison uses `4*protein + 4*carbohydrate + 9*fat + 2*fiber` (including `fiberG` when known per `docs/nutrition-engine-spec.md:182–188`, and documenting EU available-carb vs. US total-carb caveats) solely as a warning when macros and energy exist; never rewrite reported energy. Portion mass rules require grams. Keep no guessed units. Persist review issues with optional JSON key `reviewIssues`; old rows default to an empty list. Manual reviewed entry can retain unusual finite nonnegative values and its source; display the review warning rather than relabel it measured/verified. Add issue serialization to saved-meal/library/batch paths as needed, and ensure new estimate logic does not overwrite intervening corrections.
- [ ] **Step 3: Verify green and existing unknown-state behavior.** Run core tests, new app tests, meal-editor tests and data photo-meal tests. Confirm the same suspect reply leaves the meal saved and editable with partial totals, not a failed save. Document these thresholds as versioned engineering choices requiring evaluation, not clinical limits.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_core/lib/src/domain/nutrition_screening.dart packages/salu_core/lib/src/domain/photo_meal.dart packages/salu_core/lib/salu_core.dart packages/salu_core/test/nutrition_screening_test.dart packages/salu_data/lib/src/repositories/drift_photo_meal_repository.dart app/lib/src/features/meals app/test/meals/nutrition_screening_test.dart
git commit -m "fix: screen automatic nutrition and retain review issues"
```

### Task 2: Canonical allergens and transparent eligibility

**Files:** Create `packages/salu_core/lib/src/domain/allergens.dart`, `packages/salu_core/test/allergens_test.dart`, `docs/recipe-allergen-provenance.md`; modify core exports, `domain/recipes.dart:40–84,276–310`, `app/lib/src/features/onboarding/planning_profile.dart`, `onboarding_pages.dart`, `onboarding_screen.dart`, `features/plan/recipe_library.dart`, `recipe_planning.dart`, `recipe_plan_review.dart`, `food_library.dart`, `app/test/plan/recipe_planning_test.dart`.

**Interfaces:** `enum AllergenId { milk,egg,fish,crustacean,mollusc,peanut,treeNut,soy,wheatGluten,sesame,celery,mustard,lupin,sulphite }`; `AllergenId? resolveAllergen(String text)`; `({Set<AllergenId> known,List<String> unresolved}) resolveStrictAllergens(Iterable<String> terms)`. Add `String? allergenSource` to `RecipeVersion`; existing `Set<String>? allergens` stores canonical `AllergenId.name` strings for compatibility. Add `List<String> recipeIneligibilityReasons(RecipeVersion recipe,{Iterable<String> exclusions=const [],Iterable<String> strictAllergens=const [],int? cookingLimit})`, and make `recipeEligible` return whether this list is empty.

- [ ] **Step 1: Write red bilingual and unknown tests.**

```dart
import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('English and Portuguese milk declarations share one identity', () {
    expect(resolveAllergen('leite'), AllergenId.milk);
    expect(resolveAllergen('dairy'), AllergenId.milk);
    final parsed = resolveStrictAllergens(['leite', 'unsupported ingredient']);
    expect(parsed.known, {AllergenId.milk});
    expect(parsed.unresolved, ['unsupported ingredient']);
  });
}
```

Run core `dart test test/allergens_test.dart`; expect missing API. Add milk/leite/yogurt declared-recipe exclusion, nuts versus named tree nuts, unknown declarations, explicit empty declarations, unresolved terms excluding candidates, ingredient exclusions distinct from dislikes, pinned-meal conflict with a strict allergen/exclusion, and profile reload/plan confirm revalidation. No test may equate a declaration with cross-contamination certification.
- [ ] **Step 2: Implement explicit aliases, provenance and UI.** Normalize accents/case/whitespace with a small tested alias table; support exact aliases only, not model-inferred medical associations. Include all 14 categories and European Portuguese aliases, preserve unresolved user terms. Eligibility returns named reasons (`unknownAllergenStatus`, `unresolvedStrictAllergen:<term>`, `containsAllergen:<id>`, `excludedIngredient:<term>`, `cookingLimit`). If any strict term is unresolved, fail closed and ask the user to select a canonical category or ingredient exclusion. Keep existing free text readable while adding category chips; never discard unmapped legacy terms.

Curate recipe declarations in a documented table of recipe version, full ingredient statement, allergen set, source/reference and reviewer/date. Add only reviewed declarations to the eight starters; if a declaration cannot be established it stays null and the UI explains why. Provide declaration entry and provenance in recipe creation/adaptation; explicitly distinguish unknown from a declared empty set. Never infer an empty set merely because all ingredient names look safe. Show per-recipe/empty-state reasons and a route to edit preferences, not a suggestion to disable allergy constraints. Recheck current exclusions at plan confirmation as the current code already does, and explicitly detect/report when any previously pinned meal conflicts with a strict allergen or exclusion so pins can never override a medical exclusion (`docs/nutrition-engine-spec.md:559–560, 756`).
- [ ] **Step 3: Verify green core/planning/widget tests.** Test at least one documented eligible recipe for a supported strict-allergen profile and one documented rejected recipe, without weakening unknown-status rejection. Keep any unreviewed curation entry as a release blocker rather than fabricate source data.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_core/lib/src/domain/allergens.dart packages/salu_core/lib/src/domain/recipes.dart packages/salu_core/lib/salu_core.dart packages/salu_core/test/allergens_test.dart app/lib/src/features/onboarding app/lib/src/features/plan app/lib/src/features/search/food_library.dart app/test/plan/recipe_planning_test.dart docs/recipe-allergen-provenance.md
git commit -m "feat: canonicalize allergy constraints and explain recipe exclusions"
```

### Task 3: Lossless versioned recipe/document codecs

**Files:** Create `packages/salu_data/lib/src/codec/recipe_codec.dart`, `packages/salu_data/test/recipe_codec_test.dart`; modify data exports, `app/lib/src/features/plan/recipe_library.dart:64–119`, `cooked_batches.dart`, `features/search/food_library.dart`, `features/plan/week_plan.dart`, `features/onboarding/planning_profile.dart`, `app/test/plan/plan_data_test.dart`.

**Interfaces:** `Map<String,Object?> encodeRecipe(RecipeVersion recipe)`, `RecipeVersion decodeRecipe(Map<String,dynamic> row)` exported by data. Encoded recipe has `versionFormat:1`, distinct from the recipe's semantic `version`. Retain forwarding `RecipeLibrary.encodeRecipe/decodeRecipe` methods during migration. Add version tags to food-library, cooked-batches, week-plan and planning-profile payloads; existing untagged documents decode as legacy and unknown future format values throw `FormatException` before writes. Never reinterpret recipe semantic version as a document-format version.

- [ ] **Step 1: Write the red metadata round-trip test.**

```dart
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('recipe codec retains portion limits and allergy evidence', () {
    final food = Food(id: 'rice', name: 'Rice', per100g: const NutrientProfile.empty(),
        source: const FoodSource(dataset: 'fixture', datasetId: 'rice', licence: 'CC0'));
    final recipe = RecipeVersion(id: 'rice-bowl', name: 'Rice bowl', prepMinutes: 10,
        minServings: .75, maxServings: 2, allergens: {}, allergenSource: 'review-fixture',
        ingredients: [RecipeIngredient(food: food, edibleGrams: 100,
            purchaseName: 'Rice', purchaseGrams: 100, purchaseId: 'dry-rice')]);
    final restored = decodeRecipe(encodeRecipe(recipe));
    expect(restored.minServings, .75);
    expect(restored.maxServings, 2);
    expect(restored.allergens, isEmpty);
    expect(restored.allergenSource, 'review-fixture');
    expect(restored.ingredients.single.purchaseId, 'dry-rice');
    expect(restored.ingredients.single.food.source.licence, 'CC0');
  });
}
```

Run data `dart test test/recipe_codec_test.dart`; expect missing codec. Add all nutrient-state round trips, unknown declarations, `Food.allergens`, `Food.isComposite`, quality/preparation/tags, portion/density, cooked-batch remainder/yield, old unversioned fixture, future-version rejection, malformed enum/numeric values and failure without overwriting source JSON.
- [ ] **Step 2: Implement full codecs and lazy migration.** Encode every field of `RecipeVersion`, `RecipeIngredient`, `Food` (including `allergens` and `isComposite`), `FoodSource` and `PortionDefinition` described in the shared design, and share one `PhotoMealItem` JSON codec across `DriftPhotoMealRepository` and `food_library.dart` so saved meals retain `id`, `labelPaths`, and Task 1 `reviewIssues`. Decode legacy fields using their existing defaults; missing licence/declaration stays unknown. Validate before constructing types and translate malformed persisted values to a named `FormatException`, not a silent empty library. Migrate payload versions only after successful decode, using document CAS and preserving unrelated fields. Keep cooked-stock debit and meal insertion in their existing transaction. Do not mutate historical diary snapshots when updating catalogue/recipe metadata.
- [ ] **Step 3: Verify green and old libraries/plans.** Run new data codec tests, existing plan-data/planning tests, core snapshot tests and root checks. Compare legacy fixture nutrition JSON before/after migration byte-for-byte where no representation change is required, and semantically for newly versioned enclosing documents.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_data/lib/src/codec/recipe_codec.dart packages/salu_data/lib/salu_data.dart packages/salu_data/test/recipe_codec_test.dart app/lib/src/features/plan/recipe_library.dart app/lib/src/features/plan/cooked_batches.dart app/lib/src/features/search/food_library.dart app/lib/src/features/plan/week_plan.dart app/lib/src/features/onboarding/planning_profile.dart app/test/plan/plan_data_test.dart
git commit -m "fix: preserve recipe metadata with versioned document codecs"
```
