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
  --org pt.salu \
  --platforms android,ios \
  --no-pub \
  .

echo "Platform folders generated. Run: flutter pub get && flutter run"
