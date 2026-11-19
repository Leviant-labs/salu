# Startup, Architecture and Daily UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep catalogue growth off the startup path, move business operations out of widgets, and make daily use clearer in English and European Portuguese.

**Architecture:** Persist and incrementally maintain the search index, render a recoverable bootstrap shell, then extract existing behavior behind narrow services/controllers. Improve Today/library/editor presentation on those same tested interfaces rather than redesigning the entire app.

**Tech Stack:** Flutter 3.44.0, Dart application services, Drift/FTS5, Riverpod, Flutter localization/ARB and intl.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`, sections 2, 9 and 10. Final integration follows plans 2–5.

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

- Data `catalogue/search_index.dart`: index format/version check, rebuild and atomic incremental maintenance.
- App `bootstrap.dart`, `features/startup/startup_screen.dart`: app-owned initialization state and retry.
- Core `application/revise_meal_item.dart`, `application/plan_service.dart`: extracted deterministic behavior.
- Data `repositories/food_library_repository.dart`, `recipe_library_repository.dart`, `week_plan_repository.dart`: typed persistence moved out of widget files, preserving compatibility wrappers.
- App feature controllers: mutation/draft orchestration and data-write gating; widgets receive state/actions.
- App `features/search/library_screen.dart`, `features/today/diary_summary.dart`, `l10n/*.arb`: focused daily surfaces and localized strings.
- `docs/performance-baseline.md`: measured, named-device evidence, not invented targets.

### Task 1: Persistent indexing and recoverable startup

**Files:** Create `packages/salu_data/lib/src/catalogue/search_index.dart`, `packages/salu_data/test/search_index_test.dart`, `app/lib/src/bootstrap.dart`, `app/lib/src/features/startup/startup_screen.dart`, `app/test/startup/bootstrap_test.dart`, `tool/benchmark_catalogue.dart`, `docs/performance-baseline.md`; modify `drift_food_repository.dart:18–53,81–113,154–259`, `bundled_catalogue.dart`, `app/lib/main.dart:11–24`, `app/lib/src/app.dart`, export barrels as needed.

**Interfaces:** `SearchIndex(AppDatabase db,{bool forceFallback=false})` with `Future<bool> ensureReady()`, `Future<void> replaceRows(Iterable<Food> foods)`, `Future<void> removeDataset(String dataset)`, `Future<List<String>> searchIds(String query,{int limit=20})`; `const searchIndexVersion=1`. Persist `search-index-state` in local documents with `format:1` only after a completed rebuild transaction. Do not add another schema bump for this replaceable FTS table. `BootstrapController({required Future<AppDatabase> Function() openDatabase,required Future<void> Function(AppDatabase) initialize})` exposes `Future<void> start()`, `bool busy`, `String? error`, `AppDatabase? database` via ChangeNotifier. `BootstrapApp` renders startup/retry and then mounts `ProviderScope`/`SaluApp` with the opened DB; close failed/superseded instances and dispose owners once.

- [ ] **Step 1: Write red index-reopen and startup failure tests.** Data fixture:

```dart
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:salu_data/src/catalogue/search_index.dart';
import 'package:test/test.dart';

void main() {
  test('index metadata persists and incremental food is immediately searchable', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final index = SearchIndex(db);
    await index.ensureReady();
    final food = Food(id:'fixture:late', name:'Late indexed chickpeas',
        per100g:const NutrientProfile.empty(),
        source:const FoodSource(dataset:'fixture', datasetId:'late'));
    await DriftFoodRepository(db).replaceCatalogueBatch([food]);
    expect(await SearchIndex(db).searchIds('chickpeas'), contains('fixture:late'));
    expect((await LocalDocumentStore(db).read('search-index-state'))!.data['format'], 1);
  });
}
```

Run data `dart test test/search_index_test.dart`; expect missing class. Add a real file reopen test that records FTS table rowids before/after and proves no unconditional rebuild, interrupted rebuild rollback, pack replacement/removal, stale alias-format bump and FTS-unavailable search beyond ID 512. App test injects a failing initializer and expects a visible Retry screen before success, no unhandled pre-runApp exception and no duplicate open on double Retry.
- [ ] **Step 2: Implement index maintenance and bootstrap.** Move normalization/ranking from the repository to a shared data helper without changing Portuguese aliases/order; keep the existing public `search` contract. `ensureReady` checks FTS existence plus persisted format and rebuilds only when missing/outdated, in one transaction. Maintain FTS rows in the same transaction as insert/update/delete catalogue rows, using batch inserts. A failed pack install leaves catalogue/index/edition metadata unchanged. Unsupported FTS uses ordered keyset pages of 512 across the whole catalogue, retaining only bounded best candidates; it never silently excludes later packs. Yield between fallback pages and expose loading/cancellation at the app query layer. Avoid the existing full rebuild inside `insertMissingCatalogueBatch` at every open.

Call `runApp(BootstrapApp(...))` after binding initialization, before awaiting DB/catalogue work. Resume pending reset first (plan 5), open DB, migrate and install missing starter rows; index build can be deferred until first search if no valid index exists. Show progress/error/retry; never catch initialization failure and replace the real DB with an empty one. No provider initialization/handshake is a startup prerequisite.
- [ ] **Step 3: Run green and collect real benchmarks.** Run index/catalogue/data/startup tests. `tool/benchmark_catalogue.dart` is run from data with its package config and generates 25,000 synthetic foods labelled fixture, never shipping them. Report cold/warm open/search sample lists and p50/p95, DB footprint and peak memory on named Android/iOS devices; document commands, dataset count and SDK. Compare reopen query logs/rowids to prove no rebuild. Set performance release budgets only after these measurements; do not claim a millisecond target in advance.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_data/lib/src/catalogue/search_index.dart packages/salu_data/lib/src/repositories/drift_food_repository.dart packages/salu_data/lib/src/catalogue/bundled_catalogue.dart packages/salu_data/test/search_index_test.dart app/lib/src/bootstrap.dart app/lib/src/features/startup/startup_screen.dart app/lib/main.dart app/lib/src/app.dart app/test/startup/bootstrap_test.dart tool/benchmark_catalogue.dart docs/performance-baseline.md
git commit -m "perf: maintain catalogue indexes incrementally and recover startup failures"
```

### Task 2: Extract existing behavior into narrow services and controllers

**Files:** Create `packages/salu_core/lib/src/application/revise_meal_item.dart`, `application/plan_service.dart`, `packages/salu_core/test/meal_revision_test.dart`, `plan_service_test.dart`; create data `repositories/food_library_repository.dart`, `recipe_library_repository.dart`, `week_plan_repository.dart` with tests; create app `features/meals/meal_editor_controller.dart`, `features/plan/plan_controller.dart`, `features/search/library_controller.dart`, `app/test/meals/meal_editor_controller_test.dart`, `app/test/plan/plan_controller_test.dart`; modify core/data exports, app `meal_editor_data.dart`, `meal_editor.dart`, `recipe_planning.dart`, `plan_screen.dart`, `food_library.dart`, `recipe_library.dart`, `week_plan.dart`, `providers.dart`, `router.dart`, `tool/check_boundaries.sh`, `docs/architecture.md`.

**Interfaces:** Core exports existing-signature `PhotoMealItem reviseMealItem(PhotoMealItem original,String name,MealPortion? portion)` and moves planner value types (`PlannedMeal`, `GroceryItem`, `MealPosition`, planning-specific slot enum renamed `PlanMealSlot`) from `week_plan.dart` to core. `PlanService` exposes `Map<NutrientKey,RecipeTotal> dayTotals(Map<MealPosition,PlannedMeal> meals,int day,Map<String,RecipeVersion> recipes)` and `WeekPlan reconcileGroceries(WeekPlan plan,Map<String,RecipeVersion> recipes)` with current behavior. Keep intake `MealSlot` distinct, and explicit conversion at log-separately; never rely on enum index equivalence.

Data repositories retain old public operations: food `foods/meals/favorites/toggleFavorite/saveFood/saveMeal`; recipe `load/add`; week `load/save`. Keep app wrapper classes/re-exports with their current constructor signatures until consumers migrate. App controllers expose state plus async actions; `MealEditorController` constructor receives repository/mutation repository, assistant, media, write gate, `Clock`, `IdGenerator`; `PlanController` receives week/profile repositories, recipe planning source and write gate; `LibraryController` receives food/recipe/batch repositories and write gate. No controller reads a global singleton, builds a widget, or navigates.

- [ ] **Step 1: Add red characterization tests before moving code.** Extract the existing same-food scaling cases into core:

```dart
import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('portion correction scales once and keeps estimate provenance', () {
    final before = PhotoMealItem(id:'item', name:'Soup',
        portion:MealPortion(100, MealUnit.grams),
        nutrients:NutrientProfile({NutrientKey.energyKcal:
            NutrientEstimated(50,basis:'fixture')}));
    final after = reviseMealItem(before,'Soup',MealPortion(200,MealUnit.grams));
    expect(after.nutrients[NutrientKey.energyKcal].numericValue,100);
    expect(after.nutrients[NutrientKey.energyKcal],isA<NutrientEstimated>());
    expect(after.id,'item');
  });
}
```

Run core `dart test test/meal_revision_test.dart`; expect missing core export (current function is app-only). Add renaming-clears-evidence, incompatible units, stable IDs, issues/provenance preservation, pinned-slot preservation, checked/overridden grocery rows and all existing planner fixtures. App controller tests use the existing fake HTTP/repositories and controlled Completers to check cancellation, stale result, one save and write-gate blocking; compare snapshots to pre-extraction fixtures.
- [ ] **Step 2: Move behavior without changing rules.** Core holds deterministic scaling/plan math; data holds JSON/SQLite adapters; app controllers own await/save/preview-request status; widgets only collect input, display state and route confirmed actions. Follow the existing constructor injection style, preserving old forwarding APIs during migration. Replace widget-local `DateTime.now()`/ID creation with injected `Clock`/`IdGenerator` in operations. Keep preview separate from commit, batch stock+meal atomicity and unknown nutrient rules. Remove duplicated logic only after all consumers/tests use one implementation. Extend boundaries to reject app imports from `salu_data`, and add static checks that the specifically extracted widget files no longer import `dart:io`/data repositories for direct persistence. Do not impose an arbitrary line-count rule or rewrite unrelated screens.
- [ ] **Step 3: Verify before/after equivalence.** Run core/data/controller/widget suites and root boundary checks. Diff serialized fixtures and planner/grocery results; any intended behavior change must be isolated to another reviewed task, not slipped into this extraction. Verify route state survives tab switches and old imports still compile until deliberately removed.
- [ ] **Step 4: Commit extraction in reviewed slices.** Stage only the core/data/app files listed in this task and explicit accompanying tests; run `git diff --cached --stat` before committing. Use:

```bash
git commit -m "refactor: isolate diary and planning behavior from widgets"
```

### Task 3: Daily summary, usable library, localization and accessibility

**Files:** Create `app/lib/src/features/today/diary_summary.dart`, `features/search/library_screen.dart`, `features/search/library_sections.dart`, `app/l10n.yaml`, `app/lib/l10n/app_en.arb`, `app_pt_PT.arb`, `app/lib/src/formatting/localized_numbers.dart`, `app/test/search/library_screen_test.dart`, `app/test/accessibility/core_flows_test.dart`, `app/test/formatting/localized_numbers_test.dart`; modify `app/pubspec.yaml`, lockfile, `app.dart`, `router.dart`, `today_screen.dart`, `search_screen.dart`, `meal_editor.dart`, settings/onboarding/plan widgets and app-facing labels, `app/test/today_screen_test.dart`, `README.md`, `docs/architecture.md`, `docs/platform-release-checklist.md`, `docs/performance-baseline.md`.

**Interfaces:** `DiarySummary({required List<NutrientProfile> profiles})` uses existing rollup semantics; `LibraryScreen` accepts Task 2's `LibraryController` and callbacks to use a food/meal/recipe/batch. `double? parseLocalizedNumber(String input,String locale)` and `String formatLocalizedNumber(num value,String locale,{int maximumFractionDigits=2})`; UI locale changes never affect machine IDs, source text, wire JSON or archive dates. Add `library` route under the Food branch while retaining shell state. Provide reusable `String get localizedProviderName` only from profile display names, not credential/URL query content.

- [ ] **Step 1: Write red summary-position and locale regressions.** Add this to existing Today tests, using their `_pumpToday`/`_chickenEntry` fixtures:

```dart
testWidgets('recorded summary appears before meal content', (tester) async {
  await _pumpToday(tester, [_chickenEntry()]);
  final summary = tester.getTopLeft(find.text('Recorded today'));
  final food = tester.getTopLeft(find.text('Chicken breast, cooked'));
  expect(summary.dy, lessThan(food.dy));
});
```

Run `flutter test --no-pub test/today_screen_test.dart`; expect the current bottom-summary ordering to fail. Add full `parseLocalizedNumber` tests for `75,5` in pt_PT, `75.5` in en, whitespace, grouping separators from intl's locale symbols, invalid mixed grouping, NaN/infinity and empty input. Library widget tests search/filter each of Foods, Meals, Recipes and Leftovers; tapping a result invokes a callback once without writing intake until the normal editor confirms. Accessibility tests mount core screens at 320x640 and 200% text, check no overflow via `tester.takeException`, tap-target/label guidelines and focus/keyboard reachability.
- [ ] **Step 2: Implement focused daily surfaces and localization.** Move rollups above diary cards without changing `_total` semantics; expose partial/estimated/unknown labels semantically, not only via color or the approximately symbol. Keep optional targets separate from recorded totals. Put recent/favorites reuse on logging/library entry, retaining new-meal IDs and portion review. Replace the large modal in `_openLibrary` with the stateful searchable route and four section tabs; use builders/pagination for long lists, retain search/scroll on tab navigation and show explicit empty/error/retry states. Keep Save in an editor footer inside SafeArea with keyboard-aware scrolling and preview gating.

Add SDK `flutter_localizations` and SDK-compatible `intl`, `flutter.generate:true`, ARB templates and generated localization under `app/lib/l10n`; update import paths to current Flutter gen-l10n output. `l10n.yaml` sets `arb-dir: lib/l10n`, `template-arb-file: app_en.arb`, `output-localization-file: app_localizations.dart`. Wire supported locales `[Locale('en'),Locale('pt','PT')]` and generated delegates in `MaterialApp.router`. Migrate all user-visible app strings touched by these plans, including validation/errors, accessibility labels and pluralized counts; keep provider output and catalogue source names identified rather than automatically translated. Use intl locale symbols for parse/format with explicit grouping validation and one supported decimal separator per locale. Keep existing comma-input compatibility documented when editing old profiles. Replace duplicate app label extensions with localization helpers; core error/status codes map to localized UI messages, not English in domain logic.

Add semantics for progress, estimated/partial totals, image-unavailable and busy/error states. Respect `MediaQuery.disableAnimations`, system contrast/dark theme, logical focus order and labelled actions. No new animation/design package or analytics SDK. Use the relevant UI-reference/design skill only at execution time for a visual design pass, not to invent a backend dependency.
- [ ] **Step 3: Verify green, both locales and device usability.** Run `flutter gen-l10n`, formatting, `flutter analyze`, complete app tests and root checks. Exercise onboarding→offline log→correction→library→plan→data controls in both locales, 200% text, dark mode and screen reader on Android/iOS. Record actual tap count/time to log/reuse/correct and Portuguese catalogue/label misses on named fixtures; preserve honest 78-food/8-recipe baseline and separately licensed pack gaps. Update docs to distinguish measured UX improvements from new target features that remain out of scope.
- [ ] **Step 4: Commit.** Stage exact localization/widgets/tests listed above, check for unexpected generated/native files, then:

```bash
git commit -m "feat: simplify daily logging and localize accessible core flows"
```
