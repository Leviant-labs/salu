# Foundation and Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Salu reproducibly bootstrappable and validate native/offline behavior before feature changes.

**Architecture:** Retain the current three-package layout and generated native hosts. One repo check script drives dependency resolution, Drift generation, analysis and tests; CI adds native build and device smoke gates.

**Tech Stack:** Flutter 3.44.0, bundled Dart, Drift build_runner, GitHub Actions, Flutter integration_test.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`, sections 2, 3 and 10.

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

- `tool/flutter-version.txt`: single SDK pin, consumed by both check scripts and CI.
- `tool/check.ps1`, `tool/check.sh`: bootstrap/check entrypoints, fail immediately on failed commands.
- `tool/verify_platforms.dart`: verify generated permission/app-ID/signing inputs without modifying hosts.
- `app/tool/bootstrap_platforms.sh`: apply only the reviewed host inputs; never overwrite native work without inspection.
- `app/integration_test/offline_diary_test.dart`: real persisted offline smoke test without provider credentials.
- `.github/workflows/ci.yml`: checks plus Android/iOS build and emulator jobs.

### Task 1: Locked bootstrap and baseline

**Files:** Create `tool/flutter-version.txt`, `tool/check.ps1`, `tool/check.sh`; modify `.gitignore:16–18`, `README.md:26–41`; track `app/pubspec.lock`, `packages/salu_core/pubspec.lock`, `packages/salu_data/pubspec.lock` after resolution.

**Interfaces:** Consumes existing package pubspecs and `tool/check_boundaries.sh`. Produces `pwsh -File tool/check.ps1` and `bash tool/check.sh`, both exit nonzero on any bootstrap/check failure.

- [ ] **Step 1: Establish the failing bootstrap case.** In an isolated worktree with generated output absent, run `pwsh -File tool/check.ps1`; expect missing-script failure, not a claim that current feature tests fail. Record current `flutter --version` and `git status --short`. Do not remove ignored output in the user's working directory.
- [ ] **Step 2: Implement the pinned check scripts.** Write `3.44.0` to the version file. Resolve with the pinned SDK, core first, data second, app third. The PowerShell implementation uses this checked runner for every external invocation:

```powershell
$ErrorActionPreference = 'Stop'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE" }
}
$pin = (Get-Content "$PSScriptRoot/flutter-version.txt" -Raw).Trim()
$actual = (& flutter --version --machine | ConvertFrom-Json).frameworkVersion
if ($actual -ne $pin) { throw "Flutter $pin required; found $actual" }
```

POSIX uses `set -euo pipefail`, a trap restoring the original directory, and the same explicit package order. Run `dart pub get --enforce-lockfile` / `flutter pub get --enforce-lockfile` in check mode; initial lock generation uses plain `pub get` once. Run `dart run build_runner build` in data before any data/app analysis. Then boundary check, `dart format --output=none --set-exit-if-changed` on Salu source/test/tool paths, core/data analyze+test and `flutter analyze`/`flutter test --no-pub` in app. Never scan `linked_list_merge` or generated/native/build folders for formatting. Remove only the lockfile ignore rule and stage exact three locks. Document Windows SDK PATH setup and both commands.
- [ ] **Step 3: Verify green baseline.** Run the new repo check command from root. Re-run it without modifications; confirm generated output is stable and `git diff` contains no source edits caused by checks. Record real failures separately rather than masking them with SDK/dependency upgrades.
- [ ] **Step 4: Commit the deliverable after review.**

```bash
git add tool/flutter-version.txt tool/check.ps1 tool/check.sh .gitignore README.md app/pubspec.lock packages/salu_core/pubspec.lock packages/salu_data/pubspec.lock
git commit -m "build: pin toolchain and add reproducible repo checks"
```

### Task 2: Native configuration and build gates

**Files:** Create `tool/verify_platforms.dart`, `tool/platform_configuration.dart`, `tool/test/verify_platforms_test.dart`, `docs/platform-release-checklist.md`; modify `app/tool/bootstrap_platforms.sh:19–40`, `.github/workflows/ci.yml`, `.github/workflows/android-preview.yml`.

**Interfaces:** Consumes `tool/flutter-version.txt`. Produces `dart tool/verify_platforms.dart <app-directory>` with exit 0 only if Android INTERNET/camera inputs, iOS camera/photo usage descriptions and intended bundle-ID inputs are present; release builds are Android `flutter build apk --release` and iOS `flutter build ios --release --no-codesign`.

- [ ] **Step 1: Write and run a failing verifier fixture.** Create `tool/test/verify_platforms_test.dart` with a temp minimal app directory lacking the required iOS keys. Add `Future<List<String>> platformConfigurationErrors(Directory app)` in a separate `tool/platform_configuration.dart` imported by the verifier and the test. This test is a Dart script run with assertions enabled, avoiding a new root pubspec:

```dart
import 'dart:io';
import '../platform_configuration.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('salu-platform-test-');
  try {
    await Directory('${root.path}/ios/Runner').create(recursive: true);
    await File('${root.path}/ios/Runner/Info.plist').writeAsString('<plist><dict/></plist>');
    final errors = await platformConfigurationErrors(root);
    assert(errors.any((e) => e.contains('NSCameraUsageDescription')));
    assert(errors.any((e) => e.contains('NSPhotoLibraryUsageDescription')));
  } finally {
    await root.delete(recursive: true);
  }
}
```

Run `dart --enable-asserts tool/test/verify_platforms_test.dart`; expect missing library/function before implementation. Add companion valid/missing-INTERNET fixtures. Define the function above to read only known host files and return named missing settings; CLI prints errors and sets `exitCode=1`. Do not infer release signing correctness from XML alone.
- [ ] **Step 2: Implement verifier, configuration and CI.** Preserve host modifications; inspect diffs before running `flutter create` in the execution worktree. Generate hosts in a disposable CI checkout, add plist descriptions on macOS, INTERNET in release manifest, and explicit camera permission required by barcode use. Have CI load the pin, use Java 21 and the Android SDK configuration already used by preview, then run Task 1's check command. Add Android release compilation without production signing credentials and macOS iOS no-codesign compilation; neither job publishes artifacts publicly. Run verifier fixtures and actual generated-host verification before builds. Make preview consume the same pin, preserving its explicit opt-in branch trigger. Document unsigned/debug versus production-signed status and the still-manual signing/real-account gates.
- [ ] **Step 3: Verify fixtures and both build commands.** Run the verifier script locally; run Android build on a configured host and iOS build on macOS/CI. Record unsupported local platform as unverified, not passed. A failing build blocks release even if widget tests pass.
- [ ] **Step 4: Commit only configuration inputs.**

```bash
git add tool/verify_platforms.dart tool/platform_configuration.dart tool/test/verify_platforms_test.dart app/tool/bootstrap_platforms.sh .github/workflows/ci.yml .github/workflows/android-preview.yml docs/platform-release-checklist.md
git commit -m "ci: verify native configuration and compile both mobile hosts"
```

### Task 3: Persisted offline device smoke gate

**Files:** Modify `app/pubspec.yaml`; create `app/integration_test/offline_diary_test.dart`, `app/integration_test/support/test_database.dart`; modify `.github/workflows/ci.yml`, `docs/platform-release-checklist.md`.

**Interfaces:** Consumes real `AppDatabase`, `DriftPhotoMealRepository`, `PhotoMeal`, `DiaryDate` and `SaluApp`. Produces a device test runnable with `flutter test integration_test/offline_diary_test.dart -d <device-id>` from `app/`; `<device-id>` is selected from `flutter devices`, not a literal command argument.

- [ ] **Step 1: Write the red smoke test before wiring the gate.** Add SDK `integration_test` as a dev dependency and write this persistence assertion, then a UI traversal using existing `Skip for now`, `Log a meal`, and `Save without AI` text:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:salu_core/salu_core.dart';
import 'support/test_database.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('offline meal survives reopening database', (tester) async {
    final fixture = await DeviceTestDatabase.create();
    addTearDown(fixture.dispose);
    final date = DiaryDate.parse('2026-11-19');
    final meal = PhotoMeal(id: 'offline', date: date, slot: MealSlot.lunch,
        caption: 'Offline lunch', createdAt: DateTime.utc(2026, 11, 19));
    expect(await fixture.meals.saveNew(meal), isTrue);
    await fixture.reopen();
    expect((await fixture.meals.listFor(date)).single.id, 'offline');
  });
}
```

`DeviceTestDatabase` is task-owned support with `static Future<DeviceTestDatabase> create()`, `DriftPhotoMealRepository get meals`, `Future<void> reopen()`, `Future<void> dispose()`. Back it with a uniquely named file under the device temporary directory and `NativeDatabase(File)`; dispose closes the DB before deleting only that temp directory. Run before implementing support; expect a missing-support failure. Also assert unknown nutrition stays unknown and no external HTTP is invoked by mounting the UI under a rejecting `HttpOverrides`.
- [ ] **Step 2: Implement support and device gate.** Add Android emulator execution in CI with an explicit emulator ID discovered at runtime. Never use real credentials. Expand the UI test to log a text-only meal offline, open it, edit a quantity, confirm correction, remount and verify. Put camera denial, process kill/relaunch, secure-store/OAuth return and iOS device smoke in the manual checklist with steps, expected results and evidence fields; host widget tests do not satisfy these entries.
- [ ] **Step 3: Run green and full regression.** Run the device test, then the repo check. Archive private test diagnostics with no diary contents/keys; do not automatically publish an APK. Later plans append their flows to this same device checklist.
- [ ] **Step 4: Commit.**

```bash
git add app/pubspec.yaml app/pubspec.lock app/integration_test/offline_diary_test.dart app/integration_test/support/test_database.dart .github/workflows/ci.yml docs/platform-release-checklist.md
git commit -m "test: gate offline diary persistence on a mobile emulator"
```
