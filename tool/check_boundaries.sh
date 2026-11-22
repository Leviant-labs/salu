#!/usr/bin/env bash
# Fails if the pure-Dart core starts depending on Flutter, a database driver, or
# network I/O, if salu_data depends on Flutter or the app, or if extracted
# presentation widgets import salu_data or dart:io directly.
#
# Run from anywhere: bash tool/check_boundaries.sh
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

check_in() {
  local label="$1" pattern="$2"
  shift 2
  local hits
  hits=$(grep -rnE "$pattern" "$@" || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: $label"
    echo "$hits"
    status=1
  else
    echo "ok: $label"
  fi
}

check_in "salu_core must not import Flutter" \
  "package:flutter" packages/salu_core/lib packages/salu_core/pubspec.yaml
check_in "salu_core must not import a database driver" \
  "package:(drift|sqlite3|sqflite|hive|isar)" packages/salu_core/lib packages/salu_core/pubspec.yaml
check_in "salu_core must not import an HTTP client" \
  "package:(http|dio|web_socket_channel)" packages/salu_core/lib packages/salu_core/pubspec.yaml
check_in "salu_core must not use dart:io" \
  "dart:io" packages/salu_core/lib packages/salu_core/pubspec.yaml
check_in "salu_core must not import salu_data or the app" \
  "package:(salu_data|salu/)" packages/salu_core/lib packages/salu_core/pubspec.yaml

check_in "salu_data must not import Flutter or the app" \
  "package:(flutter|salu/)" packages/salu_data/lib packages/salu_data/pubspec.yaml

check_in "extracted presentation widgets must not import salu_data or dart:io" \
  "(package:salu_data|dart:io)" \
  app/lib/src/features/meals/meal_editor.dart \
  app/lib/src/features/plan/plan_screen.dart \
  app/lib/src/features/search/library_screen.dart \
  app/lib/src/features/today/diary_summary.dart

exit "$status"
