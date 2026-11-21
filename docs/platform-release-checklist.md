# Platform Release Checklist

This checklist separates automated CI verification from manual signing, device, and real-account release gates. Passing automated checks is necessary to unblock integration, not sufficient on its own to ship a production release.

## 1. Automated CI Gates

Every pull request and `main` push runs `.github/workflows/ci.yml` using the toolchain pinned in [`tool/flutter-version.txt`](../tool/flutter-version.txt):

| Gate | Command | What it verifies |
| --- | --- | --- |
| Toolchain & package checks | `bash tool/check.sh` (or `pwsh -File tool/check.ps1`) | Exact Flutter/Dart SDK pin, locked dependencies, Drift codegen, module boundaries, formatting, static analysis, and unit/widget tests across `salu_core`, `salu_data`, and `app`. |
| Platform verifier self-tests | `dart --enable-asserts tool/test/verify_platforms_test.dart` | Fixture coverage for missing iOS usage keys, missing Android permissions, missing Auto Backup exclusion, invalid/placeholder bundle IDs, and valid host inputs. |
| Native host bootstrap & verification | `bash app/tool/bootstrap_platforms.sh` then `dart tool/verify_platforms.dart app` | Generated Android/iOS host inputs contain `android.permission.INTERNET`, `android.permission.CAMERA`, explicit Auto Backup exclusion (`android:allowBackup="false"` or reviewed backup exclusion rules), `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, and `pt.salu.*` application/bundle IDs. |
| Android emulator offline smoke | `cd app && flutter test integration_test/offline_diary_test.dart -d <device-id>` (with `<device-id>` discovered from `flutter devices` at runtime) | Runs on an Android emulator with no real credentials and external HTTP blocked (`HttpOverrides`): onboarding skip, offline text-only meal logging (`Save without AI`), item quantity editing, unknown nutrition (`--` / `Nutrition unknown`), and persistence across `AppDatabase` reopen. Failure diagnostics exclude diary contents and keys; no APK is published. |
| Android release compilation | `cd app && flutter build apk --release` | Release Dart/AOT compilation and Android Gradle packaging succeed on Java 21 + Android SDK 36. |
| iOS release compilation | `cd app && flutter build ios --release --no-codesign` | Release Dart/AOT compilation and Xcode build succeed on macOS. |

Neither CI build job publishes public artifacts. `.github/workflows/android-preview.yml` uses the same SDK pin and platform verification on explicit `test/android-preview*` branches (`SALU_PLATFORM_ORG=pt.salu.preview`, debug APK).

## 2. Unsigned / Debug-Signed CI vs. Production-Signed Releases

- **CI Android release APK (`flutter build apk --release`):** Built without production signing secrets. Flutter's generated `android/app/build.gradle.kts` configures `release` with `signingConfig = signingConfigs.getByName("debug")` so release compilation can be gated in CI without exposing release keystores. This APK is **not** distributable to stores.
- **CI iOS release build (`flutter build ios --release --no-codesign`):** Compiles the Release runner bundle without distribution certificates or provisioning profiles. This proves compilation only and cannot be installed on a physical iOS device without signing.
- **Manifest/Gradle verification limit:** `tool/verify_platforms.dart` intentionally does **not** infer release signing correctness from XML or Gradle files alone.
- **Platform verification honesty:** A build or device test skipped or unsupported on the local host (for example, iOS on Windows/Linux, or an Android emulator test on a host with no emulator/device attached) must be recorded as **unverified locally**, never as passed. A failing build or device smoke gate blocks release even when unit and widget tests pass.

## 3. Manual Release Gates

Host widget tests (`flutter test` on macOS/Windows/Linux or `-d flutter-tester`) do **not** satisfy any manual release gate below. Later plans append their device verification flows to this checklist.

Complete and record evidence for every manual gate below before tagging a production release:

| Gate | Steps | Expected Result | Evidence (Date / Tester / Device / Notes) |
| --- | --- | --- | --- |
| **Android production signing** | Configure release keystore credentials in a secure local/release environment (never committed). Build signed AAB/APK and run `apksigner verify --verbose`. | Signature verifies with the production release key, `applicationId` is `pt.salu.salu`, and the APK is not debug-signed. | _Pending_ |
| **iOS code signing & archive** | Open `app/ios/Runner.xcworkspace` in Xcode with production team/provisioning profile, verify `PRODUCT_BUNDLE_IDENTIFIER` (`pt.salu.salu`), archive, and install via TestFlight / signed device build. | Archive succeeds with distribution profile, installs cleanly on physical iOS hardware, and launches to the app shell. | _Pending_ |
| **Android Auto Backup exclusion** | Inspect built APK manifest (`apkanalyzer manifest print`) and verify `adb backup` behavior on a test device. | `android:allowBackup="false"` (or reviewed backup exclusion rules) is present in the merged manifest; user SQLite DB and meal media are excluded from OS cloud backups. | _Pending_ |
| **Camera & photo library denial / recovery** | On physical Android and iOS devices, tap **Camera** and **Gallery** in the meal editor; test **Allow**, then **Deny** / **Don't Allow** (and revoke permissions in OS Settings), retry capture/selection, then continue logging a text-only meal. | OS prompts show Salu's usage descriptions; denying camera or photo library access shows an inline recoverable message without crashing, and manual/text meal logging remains functional. | _Pending_ |
| **Process kill & relaunch offline persistence** | Enable `Airplane Mode` on a physical Android and iOS device. Skip onboarding (`Skip setup`), tap `Log a meal`, log a text-only meal (`Save without AI`), open it, add/edit an item quantity, tap `Save changes`, force-kill the app from the OS task switcher, and relaunch while still offline. | Onboarding stays dismissed, the saved meal, edited item quantity, and unknown nutrition (`-- kcal` / `Nutrition unknown`, never `0`) survive full OS process termination and relaunch with no network access. | _Pending_ |
| **Guided onboarding kill & relaunch resume (page 4)** | Freshly install or reset app data, advance through onboarding pages 1–3 entering optional answers (goal, starting weight), reach Step 4 of 7 (`Food preferences`), type preferences and/or pause on page 4, force-kill the app process from the OS task switcher, relaunch the app, then navigate Back to inspect Steps 2–3 and forward through Step 7 (`Finish setup`), then force-kill and relaunch once more. | Relaunch opens directly at `Step 4 of 7` (`Food preferences`), navigating `Back` preserves previously saved answers from Steps 2–3, completing `Finish setup` opens the diary, and the final relaunch goes directly to the diary without re-showing the wizard. | _Pending_ |
| **Secure-store & OAuth browser return** | On a signed device build with a real test account (never in general CI), start ChatGPT sign-in in Settings, approve or cancel in the system browser, verify return via the local OAuth callback, force-kill and relaunch the app, test explicit meal/label AI submission, then disconnect. | Browser returns cleanly to Salu, session credentials persist in Android Keystore / iOS Keychain across process restarts, disclosed payloads upload only on explicit user action, and disconnect clears secure-store tokens. | _Pending_ |
| **iOS physical device smoke** | Install a signed Release or TestFlight build on physical iOS hardware (iPhone/iPad). Run `flutter test integration_test/offline_diary_test.dart -d <ios-device-id>` on a test build or execute the full offline diary, camera denial, and process kill/relaunch flow manually on the signed build. | App launches cleanly on physical iOS hardware, safe-area layout and scrolling work across screen sizes, offline diary persistence survives reopen/relaunch, and no runtime/sandbox errors occur. | _Pending_ |
