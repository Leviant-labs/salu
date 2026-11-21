# Platform Release Checklist

This checklist separates automated CI verification from manual signing, device, and real-account release gates. Passing automated checks is necessary to unblock integration, not sufficient on its own to ship a production release.

## 1. Automated CI Gates

Every pull request and `main` push runs `.github/workflows/ci.yml` using the toolchain pinned in [`tool/flutter-version.txt`](../tool/flutter-version.txt):

| Gate | Command | What it verifies |
| --- | --- | --- |
| Toolchain & package checks | `bash tool/check.sh` (or `pwsh -File tool/check.ps1`) | Exact Flutter/Dart SDK pin, locked dependencies, Drift codegen, module boundaries, formatting, static analysis, and unit/widget tests across `salu_core`, `salu_data`, and `app`. |
| Platform verifier self-tests | `dart --enable-asserts tool/test/verify_platforms_test.dart` | Fixture coverage for missing iOS usage keys, missing Android permissions, missing Auto Backup exclusion, invalid/placeholder bundle IDs, and valid host inputs. |
| Native host bootstrap & verification | `bash app/tool/bootstrap_platforms.sh` then `dart tool/verify_platforms.dart app` | Generated Android/iOS host inputs contain `android.permission.INTERNET`, `android.permission.CAMERA`, explicit Auto Backup exclusion (`android:allowBackup="false"` or reviewed backup exclusion rules), `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, and `pt.salu.*` application/bundle IDs. |
| Android release compilation | `cd app && flutter build apk --release` | Release Dart/AOT compilation and Android Gradle packaging succeed on Java 21 + Android SDK 36. |
| iOS release compilation | `cd app && flutter build ios --release --no-codesign` | Release Dart/AOT compilation and Xcode build succeed on macOS. |

Neither CI build job publishes public artifacts. `.github/workflows/android-preview.yml` uses the same SDK pin and platform verification on explicit `test/android-preview*` branches (`SALU_PLATFORM_ORG=pt.salu.preview`, debug APK).

## 2. Unsigned / Debug-Signed CI vs. Production-Signed Releases

- **CI Android release APK (`flutter build apk --release`):** Built without production signing secrets. Flutter's generated `android/app/build.gradle.kts` configures `release` with `signingConfig = signingConfigs.getByName("debug")` so release compilation can be gated in CI without exposing release keystores. This APK is **not** distributable to stores.
- **CI iOS release build (`flutter build ios --release --no-codesign`):** Compiles the Release runner bundle without distribution certificates or provisioning profiles. This proves compilation only and cannot be installed on a physical iOS device without signing.
- **Manifest/Gradle verification limit:** `tool/verify_platforms.dart` intentionally does **not** infer release signing correctness from XML or Gradle files alone.
- **Platform verification honesty:** A build skipped or unsupported on the local host (for example, iOS on Windows/Linux, or Android on a host lacking JDK 17/21) must be recorded as **unverified locally**, never as passed. A failing build blocks release even when unit and widget tests pass.

## 3. Manual Release Gates

Complete and record evidence for every manual gate below before tagging a production release:

| Gate | Steps | Expected Result | Evidence (Date / Tester / Device / Notes) |
| --- | --- | --- | --- |
| **Android production signing** | Configure release keystore credentials in a secure local/release environment (never committed). Build signed AAB/APK and run `apksigner verify --verbose`. | Signature verifies with the production release key, `applicationId` is `pt.salu.salu`, and the APK is not debug-signed. | _Pending_ |
| **iOS code signing & archive** | Open `app/ios/Runner.xcworkspace` in Xcode with production team/provisioning profile, verify `PRODUCT_BUNDLE_IDENTIFIER` (`pt.salu.salu`), archive, and install via TestFlight / signed device build. | Archive succeeds with distribution profile, installs cleanly on physical iOS hardware, and launches to the app shell. | _Pending_ |
| **Android Auto Backup exclusion** | Inspect built APK manifest (`apkanalyzer manifest print`) and verify `adb backup` behavior on a test device. | `android:allowBackup="false"` (or reviewed backup exclusion rules) is present in the merged manifest; user SQLite DB and meal media are excluded from OS cloud backups. | _Pending_ |
| **Camera & photo library permissions** | On real Android and iOS devices, trigger photo capture and library selection, test **Allow**, and test **Deny** / **Don't Allow** in OS settings. | OS prompts show Salu's usage descriptions; denying camera/photo access degrades cleanly without crashing and leaves manual/text logging usable. | _Pending_ |
| **Real-account AI sign-in & image input** | On a signed device build with a real test account (never in general CI), test ChatGPT sign-in or BYOK setup, inspect disclosure copy, submit a meal photo + label image, then disconnect. | Sign-in completes via browser/secure store, disclosed payload uploads only after explicit user action, estimates/OCR attach to the saved meal, and disconnect revokes local session state. | _Pending_ |
| **Physical device offline & restart smoke** | Disable network (`Airplane Mode`), log a meal, edit a quantity, force-kill and relaunch the app. | Diary entry, quantities, and nutrition states survive process termination and reopen intact without network access. | _Pending_ |
