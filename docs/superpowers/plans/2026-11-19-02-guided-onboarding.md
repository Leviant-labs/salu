# Guided Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore resumable, page-by-page first-run guidance without turning profile editing into a wizard or making AI mandatory.

**Architecture:** A typed draft and Drift-backed draft store hold validated progress independently of the committed profile. A small wizard controller manages navigation and completion; existing profile/preference forms remain available for later editing.

**Tech Stack:** Flutter 3.44.0, Riverpod, Drift `LocalDocumentStore`, existing `PlanningProfileStore`.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`, sections 2 and 4.

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

- `packages/salu_core/lib/src/domain/planning_profile.dart`: move the existing profile/value classes without UI labels; keep re-exports at the old app import path during migration.
- `packages/salu_core/lib/src/domain/onboarding_draft.dart`: draft version/current-step/profile, no widget or credential fields.
- `packages/salu_data/lib/src/repositories/onboarding_store.dart`: transactional resume/save/finish/skip over the existing documents table.
- `app/lib/src/features/onboarding/onboarding_controller.dart`: async busy/error/navigation state.
- `app/lib/src/features/onboarding/onboarding_wizard.dart`: page shell/progress/footer/back handling.
- `app/lib/src/features/onboarding/onboarding_pages.dart`: small page widgets and labels, reusing profile fields where practical.
- Existing `onboarding_screen.dart`: dispatcher for first run versus compact editing; no duplicate data model.

### Task 1: Persist a resumable draft and complete atomically

**Files:** Create the three core/data files above, `packages/salu_data/test/onboarding_store_test.dart`; modify core/data export barrels, `app/lib/src/features/onboarding/planning_profile.dart:8–117`, `packages/salu_data/lib/src/repositories/local_document_store.dart`.

**Interfaces:** Consumes `LocalDocumentStore.read/put`, `PlanningProfile.toJson/fromJson`. Produces `enum OnboardingStep { welcome, goals, startingPoint, preferences, targets, aiSetup, review }`; `OnboardingDraft({this.step=OnboardingStep.welcome, this.profile=const PlanningProfile(), this.revision=0})`, with `step`, `profile`, `revision`, `copyWith`, version-1 `toJson/fromJson`; `OnboardingStore(LocalDocumentStore documents)` with `Future<OnboardingDraft> load()`, `Future<bool> save(OnboardingDraft draft)`, `Future<bool> complete(OnboardingDraft draft)`, `Future<void> skip()`. Add `Future<void> LocalDocumentStore.remove(String id)` used only inside the caller's transaction for atomic completion. Profiles keep all existing constructor names and JSON keys.

- [ ] **Step 1: Add the failing persistence test.**

```dart
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('draft resumes without marking setup complete', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = OnboardingStore(documents);
    final draft = OnboardingDraft(step: OnboardingStep.preferences,
        profile: const PlanningProfile(startingWeight: 75.5));
    expect(await store.save(draft), isTrue);
    final resumed = await OnboardingStore(documents).load();
    expect(resumed.step, OnboardingStep.preferences);
    expect(resumed.profile.startingWeight, 75.5);
    expect(await documents.read('planning-profile'), isNull);
    expect(await store.complete(resumed), isTrue);
    expect(await documents.read('onboarding-draft'), isNull);
    expect((await documents.read('planning-profile'))!.data['onboarded'], isTrue);
  });
}
```

From data run `dart test test/onboarding_store_test.dart`; expect missing draft/store symbols. Add stale-draft rejection, future-version rejection, transaction rollback, skip-preserves-existing-profile and already-onboarded fixtures in this file.
- [ ] **Step 2: Implement exact storage semantics.** Move only profile value types to core, leaving UI labels in app and the legacy file importer intact. Core `WeightUnit` keeps the cases `kilograms`/`pounds` but no display constructor; app adds `extension WeightUnitLabel on WeightUnit` returning `kg`/`lb` so current `.label` consumers still compile. Draft JSON is `{'version':1,'step':step.name,'profile':profile.toJson()}`; row revision is external to payload. `save` uses compare-and-put; `complete` transaction checks the expected draft revision, reads the current `planning-profile` revision (handling both absent revision 0 and an existing committed profile), writes validated `planning-profile` with `onboarded:true`, and removes the draft; a conflict returns false and makes no changes. `skip` transaction marks an existing committed profile onboarded while preserving fields and removes the draft. Validate optional positive finite numbers at this boundary; absent is allowed. No raw numeric editing text, key or token field exists in the draft. Add explicit exports so existing imports compile without renaming application types.
- [ ] **Step 3: Run green and existing profile/migration tests.** Run the new data test; from app run `flutter test --no-pub test/onboarding/planning_profile_test.dart`. Confirm no SQLite schema bump is needed and no draft triggers network access.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_core/lib/src/domain/planning_profile.dart packages/salu_core/lib/src/domain/onboarding_draft.dart packages/salu_core/lib/salu_core.dart packages/salu_data/lib/src/repositories/onboarding_store.dart packages/salu_data/lib/src/repositories/local_document_store.dart packages/salu_data/lib/salu_data.dart packages/salu_data/test/onboarding_store_test.dart app/lib/src/features/onboarding/planning_profile.dart
git commit -m "feat: persist onboarding progress and finish setup atomically"
```

### Task 2: Page-by-page wizard and optional AI seam

**Files:** Create `app/lib/src/features/onboarding/onboarding_controller.dart`, `onboarding_wizard.dart`, `onboarding_pages.dart`, `app/test/onboarding/onboarding_wizard_test.dart`; modify `app/lib/src/features/onboarding/onboarding_screen.dart:5–23`, `app/lib/src/providers.dart`, `app/lib/src/router.dart:130–180`, `app/integration_test/offline_diary_test.dart`.

**Interfaces:** Consumes Task 1 `OnboardingStore`. Produces `OnboardingWizard({required OnboardingStore store, required VoidCallback onCompleted, Future<void> Function(BuildContext)? openConnections})`. `OnboardingController` is a `ChangeNotifier` with `OnboardingDraft draft`, `bool busy`, `String? error`, `Future<void> load()`, `Future<bool> next(PlanningProfile profile)`, `Future<bool> back()`, `Future<bool> skipStep()`, `Future<bool> finish()`, `Future<bool> skipSetup()`. Successful transitions reload the stored revision. Expose `onboardingStoreProvider` using `documentStoreProvider`; no global controller instance.

- [ ] **Step 1: Write the failing separate-page test.**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/onboarding_wizard.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  testWidgets('Next advances one page and Back retains answers', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await tester.pumpWidget(MaterialApp(home: OnboardingWizard(
        store: store, onCompleted: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('Starting weight'), findsNothing);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 7'), findsOneWidget);
  });
}
```

Run `flutter test --no-pub test/onboarding/onboarding_wizard_test.dart`; expect missing wizard. Add tests for all seven pages, saved-answer resume after widget disposal, invalid-number stay-on-page, save-error no navigation, two rapid Next taps, Android back, empty optional pages, review summary, finish once, and skipped/failed AI setup with zero meal uploads.
- [ ] **Step 2: Implement controller and pages.** Navigation is a persisted state transition, not an uncontrolled `PageController.nextPage` race:

```dart
Future<bool> next(PlanningProfile profile) async {
  if (busy || draft.step == OnboardingStep.review) return false;
  busy = true;
  error = null;
  notifyListeners();
  try {
    final step = OnboardingStep.values[draft.step.index + 1];
    final candidate = draft.copyWith(step: step, profile: profile);
    if (!await store.save(candidate)) {
      error = 'Setup changed. Reopen the latest step and try again.';
      return false;
    }
    draft = await store.load();
    return true;
  } catch (_) {
    error = 'Could not save progress. Your answers are still here.';
    return false;
  } finally {
    busy = false;
    notifyListeners();
  }
}
```

The controller owns `final OnboardingStore store`; implement Back, skip and finish using the same serialized pattern and exact Task 1 semantics, not duplicated DB writes. Page fields retain raw editing text in widget/controller memory only; validate before next, and save only normalized values. Render one page at a time, persistent footer in `SafeArea` with `Next`, `Back`, and `Skip this step` controls, step semantics live region and optional-field copy. Use `PopScope` to route Android back to the preceding step; provide explicit `Skip setup` on Welcome. AI page says setup is optional, invokes `openConnections` if supplied, and always offers Skip. The router loads `PlanningProfileStore.load()` first (so any legacy `planning_profile_v1.json` migrates to SQLite before checking `onboarded`) and mounts the wizard only for unonboarded users. Do not show it again after updating the app.
- [ ] **Step 3: Verify green and startup behavior.** Run wizard tests and `test/onboarding/startup_test.dart`; update its fake wiring to override the draft store with an in-memory DB, and update `app/integration_test/offline_diary_test.dart` from `Skip for now` to `Skip setup`. Ensure skip-once/later-launch assertions remain. Add integration steps for kill/relaunch on page four to the device checklist; use actual process restart for release evidence.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/src/features/onboarding/onboarding_controller.dart app/lib/src/features/onboarding/onboarding_wizard.dart app/lib/src/features/onboarding/onboarding_pages.dart app/lib/src/features/onboarding/onboarding_screen.dart app/lib/src/providers.dart app/lib/src/router.dart app/test/onboarding/onboarding_wizard_test.dart app/test/onboarding/startup_test.dart app/integration_test/offline_diary_test.dart docs/platform-release-checklist.md
git commit -m "feat: restore guided resumable onboarding pages"
```

### Task 3: Preserve compact editing and document the restored flow

**Files:** Modify `app/lib/src/features/onboarding/onboarding_screen.dart:114–121,229–400`, `app/test/onboarding/planning_profile_test.dart:86–123`, `README.md`, `docs/product-spec.md:202–218`, `docs/architecture.md`.

**Interfaces:** Consumes unchanged `OnboardingScreen(firstRun:false)` and `FoodPreferencesScreen`; produces compact optional-field editing with the existing `PlanningProfileStore.save/savePreferences` signatures. The first-run route dispatches to Task 2 rather than reusing this form.

- [ ] **Step 1: Replace the mandatory-weight test with a red optional-edit regression.** In the existing `_MemoryProfile` test setup:

```dart
testWidgets('profile editing does not require a weight', (tester) async {
  final store = _MemoryProfile();
  var saved = false;
  await tester.pumpWidget(MaterialApp(home: OnboardingScreen(
      store: store, onSaved: () => saved = true)));
  await tester.pumpAndSettle();
  final save = find.widgetWithText(FilledButton, 'Save profile');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
  expect(saved, isTrue);
  expect(store.profile.startingWeight, isNull);
});
```

Run `flutter test --no-pub test/onboarding/planning_profile_test.dart`; it should fail on the current required-weight validator. Retain comma-decimal, preference preservation, error retention and nonfinite-number tests.
- [ ] **Step 2: Implement the small form correction and docs.** Set the starting-weight validator's `required` argument to false in compact editing too; blank stays null and positive finite validation remains for entered values. Keep compact Settings editing and preference-only editing, and remove obsolete first-run form branches once the dispatcher handles them. Document seven wizard pages, resume/skip semantics, no automatic targets and optional AI setup; do not describe a connection adapter as shipped until plan 3 is completed.
- [ ] **Step 3: Verify all onboarding tests and repo checks.** Run `flutter test --no-pub test/onboarding` and the root check script; test 320px/200% text with footer reachable and no overflow.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/src/features/onboarding/onboarding_screen.dart app/test/onboarding/planning_profile_test.dart README.md docs/product-spec.md docs/architecture.md
git commit -m "fix: keep profile editing compact and all setup inputs optional"
```
