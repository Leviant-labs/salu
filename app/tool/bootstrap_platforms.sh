#!/usr/bin/env bash
# Generates the Android and iOS host projects that `flutter create` owns.
#
# The Dart code, package layout and tests in this repo are hand-written and
# version-controlled. The platform folders contain generated Gradle/Xcode
# boilerplate plus large binary assets (the Gradle wrapper jar), so they are
# created once on a machine with the Flutter SDK rather than committed blindly.
#
# Run from `app/`:   bash tool/bootstrap_platforms.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH" >&2
  exit 1
fi

flutter create \
  --project-name salu \
  --org "${SALU_PLATFORM_ORG:-pt.salu}" \
  --platforms android,ios \
  --no-pub \
  .

if [[ -f ios/Runner/Info.plist ]]; then
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string Take photos of meals and nutrition labels for your diary.' ios/Runner/Info.plist 2>/dev/null || :
    /usr/libexec/PlistBuddy -c 'Add :NSPhotoLibraryUsageDescription string Choose photos of meals and nutrition labels for your diary.' ios/Runner/Info.plist 2>/dev/null || :
  else
    echo 'On macOS, rerun this script to add iOS photo and camera usage descriptions.'
  fi
fi

# Flutter's default main manifest omits INTERNET for release builds.
manifest=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.INTERNET' "$manifest"; then
  tmp="$(mktemp)"
  awk '/<application/ && !added {print "    <uses-permission android:name=\"android.permission.INTERNET\" />"; added = 1} {print}' "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
fi

echo "Platform folders generated. Run: flutter pub get && flutter run"
