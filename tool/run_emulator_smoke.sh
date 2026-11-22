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
adb -s "$device_id" logcat -c 2>/dev/null || true

dump_logcat() {
  local rc=$?
  adb -s "$device_id" logcat -d -s flutter:I AndroidRuntime:E TestRunner:I DEBUG:V libc:V ActivityManager:W > artifacts/emulator-smoke/device-logcat.txt 2>/dev/null || true
  if [[ "$rc" -ne 0 && -s artifacts/emulator-smoke/device-logcat.txt ]]; then
    echo "=== Tail of Android emulator logcat ===" >&2
    tail -n 120 artifacts/emulator-smoke/device-logcat.txt >&2
  fi
}
trap dump_logcat EXIT

# Software SwiftShader GPUs on headless Linux emulators can crash Impeller OpenGLES;
# use Skia for the emulator smoke test without disabling Impeller in production builds.
(cd app && flutter test --no-pub --no-enable-impeller integration_test/offline_diary_test.dart -d "$device_id") 2>&1 | tee artifacts/emulator-smoke/test-output.log
