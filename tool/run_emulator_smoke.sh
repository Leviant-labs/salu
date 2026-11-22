#!/usr/bin/env bash
set -euo pipefail

mkdir -p artifacts/emulator-smoke
flutter devices --machine > artifacts/emulator-smoke/flutter-devices.json
device_id="$(python3 -c '
import json, sys
devices = json.load(sys.stdin)
for d in devices:
    if str(d.get("id", "")).startswith("emulator-"):
        print(d["id"])
        break
' < artifacts/emulator-smoke/flutter-devices.json)"

if [[ -z "$device_id" ]]; then
  echo "No Android emulator device discovered by flutter devices" >&2
  flutter devices >&2
  exit 1
fi

echo "Running offline smoke test on $device_id"
trap 'adb -s "$device_id" logcat -d -s flutter:I AndroidRuntime:E TestRunner:I > artifacts/emulator-smoke/device-logcat.txt 2>/dev/null || true' EXIT
(cd app && flutter test --no-pub integration_test/offline_diary_test.dart -d "$device_id") 2>&1 | tee artifacts/emulator-smoke/test-output.log
