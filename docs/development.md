# Development

Use Flutter stable (Dart >=3.9) on PATH. The project-local Codex configuration
starts the official Dart MCP server with roots fallback; register the repository
root before using analyzer/test tools. It is a development tool, never app inference.
After pub get, inspect dependency `skills/` directories and `dart pub` help for
package-skill support; only install skills actually supplied by resolved packages.

Run `bash tool/verify.sh`. The Android/iOS host bootstrap must preserve app/lib,
app/test, pubspec and platform permissions. iOS compilation requires a macOS
runner/Xcode; Linux cannot validate an iOS binary. Device and review gates are
tracked separately from unit tests in release-checklist.md.

Resolved dependency skill discovery found only transitive petitparser skills; no
parser authoring is involved in this change, so none were installed. The official
Dart MCP server was initialized, roots registered, and its analysis, fix, pub and
test tools used. The Work session used the verified SDK 3.9.2 server for MCP and
Flutter 3.47.9 for app tools; SDK 3.13.7 server startup did not complete its
handshake in the initial probe. The checked-in configuration uses the server
from the developer's Dart on PATH; verify it when starting a new client.

Flutter's SDK startup can probe Azure instance metadata while detecting CI. In
this environment CI=true short-circuits that probe (verified in bot_detector.dart).
All subsequent Flutter commands used CI=true and suppressed analytics.

## Guided experience

Startup installs the pinned INSA catalogue followed by the authored starter-meal
asset. A missing source binding must fail that library transaction, never select
development nutrition. Existing user records remain accessible. Guided setup
stores unfinished answers separately from the committed profile; accepting the
review writes the profile, optional estimate, week and grocery overlays atomically.
Week documents use `plan/week:<startDate>`; `plan/current` remains real legacy data.

Focused checks:

```sh
cd packages/salu_core
dart test test/starting_estimate_test.dart test/guided_planner_test.dart test/plan_assistance_test.dart test/daily_recommendation_test.dart
cd ../salu_data
dart test test/starter_meal_library_test.dart test/guided_plan_service_test.dart test/plan_meal_state_test.dart
cd ../../app
flutter test test/starter_meals_source_test.dart test/onboarding_plan_test.dart test/guided_today_test.dart test/chatgpt_auth_test.dart test/chatgpt_plan_provider_test.dart
```

On the configured Windows workstation, prepend `C:/temp/flutter/bin` to PATH
or invoke its `dart.bat`/`flutter.bat` directly, with `CI=true`. Run the existing
`bash tool/verify.sh` from the repository root for boundary and full-suite checks.

ChatGPT fixtures must use injected HTTP/token-store/browser seams and test signing
keys, never personal credentials. Unit tests do not prove mobile browser return,
secure storage or subscription admission. Physical Android and iPhone acceptance
requires the documented loopback callback, background/resume/cancel/reconnect,
a server-ordered model catalogue and one **completed live Responses inference**.
Windows cannot certify the iPhone path; an Android emulator is not physical-device
proof. Keep unavailable platform/provider evidence explicit rather than adding an
API-key, desktop-companion or private-endpoint fallback.
