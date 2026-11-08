#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tool/check_boundaries.sh
(cd packages/salu_core && dart pub get && dart analyze && dart test)
(cd packages/salu_data && dart pub get && dart run build_runner build --delete-conflicting-outputs && dart analyze && dart test)
(cd app && flutter pub get && flutter analyze && flutter test)
