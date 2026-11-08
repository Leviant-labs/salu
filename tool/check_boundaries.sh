#!/usr/bin/env bash
# Fails if the pure-Dart core starts depending on Flutter, a database driver, or
# network I/O. The dependency rule in docs/architecture.md must be mechanical:
# a convention that only lives in a document is a convention that erodes.
#
# Run from anywhere: bash tool/check_boundaries.sh
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

check() {
  local label="$1" pattern="$2"
  local hits
  hits=$(grep -rnE "$pattern" packages/salu_core/lib packages/salu_core/pubspec.yaml || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: $label"
    echo "$hits"
    status=1
  else
    echo "ok: $label"
  fi
}

check "salu_core must not import Flutter"          "package:flutter"
check "salu_core must not import a database driver" "package:(drift|sqlite3|sqflite|hive|isar)"
check "salu_core must not import an HTTP client"    "package:(http|dio|web_socket_channel)"
check "salu_core must not use dart:io"              "dart:io"
check "salu_core must not import salu_data or the app" "package:(salu_data|salu/)"

exit "$status"
