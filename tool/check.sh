#!/usr/bin/env bash
set -euo pipefail

ORIG_DIR="$(pwd)"
trap 'cd "$ORIG_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

pin="$(tr -d '[:space:]' < "$SCRIPT_DIR/flutter-version.txt")"
version_json="$(flutter --version --machine)"
actual="$(printf '%s\n' "$version_json" | sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
if [[ "$actual" != "$pin" ]]; then
  echo "Flutter $pin required; found ${actual:-<unknown>}" >&2
  exit 1
fi

(cd packages/salu_core && dart pub get --enforce-lockfile)
(cd packages/salu_data && dart pub get --enforce-lockfile)
(cd app && flutter pub get --enforce-lockfile && flutter gen-l10n)

(cd packages/salu_data && dart run build_runner build)

bash tool/check_boundaries.sh

format_files=()
while IFS= read -r -d '' file; do
  format_files+=("$file")
done < <(
  find \
    packages/salu_core/lib \
    packages/salu_core/test \
    packages/salu_data/lib \
    packages/salu_data/test \
    app/lib \
    app/test \
    tool \
    -type f -name '*.dart' ! -name '*.g.dart' \
    ! -path '*/.dart_tool/*' ! -path '*/build/*' ! -path '*/android/*' ! -path '*/ios/*' ! -path '*/linked_list_merge/*' \
    -print0
)
if [[ ${#format_files[@]} -gt 0 ]]; then
  dart format --output=none --set-exit-if-changed "${format_files[@]}"
fi

(cd packages/salu_core && dart analyze && dart test)
(cd packages/salu_data && dart analyze && dart test)
(cd app && flutter analyze && flutter test --no-pub)
