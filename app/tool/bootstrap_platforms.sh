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

stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

flutter create \
  --project-name salu \
  --org "${SALU_PLATFORM_ORG:-pt.salu}" \
  --platforms android,ios \
  --no-pub \
  "$stage_dir"

copy_missing_tree() {
  local src_root="$1"
  local dst_root="$2"
  (
    cd "$src_root"
    find . -type d | while IFS= read -r dir; do
      mkdir -p "$dst_root/$dir"
    done
    find . -type f | while IFS= read -r file; do
      if [[ ! -e "$dst_root/$file" ]]; then
        cp -p "$file" "$dst_root/$file"
      fi
    done
  )
}

for platform_dir in android ios; do
  if [[ -d "$stage_dir/$platform_dir" ]]; then
    copy_missing_tree "$stage_dir/$platform_dir" "$(pwd)/$platform_dir"
  fi
done

plist=ios/Runner/Info.plist
camera_desc="Take photos of meals and nutrition labels for your diary."
photo_desc="Choose photos of meals and nutrition labels for your diary."

insert_plist_string() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "<key>${key}</key>" "$file"; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    !added && /^[[:space:]]*<dict>[[:space:]]*\r?$/ {
      print
      printf "\t<key>%s</key>\n\t<string>%s</string>\n", k, v
      added = 1
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [[ -f "$plist" ]]; then
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string $camera_desc" "$plist" 2>/dev/null || :
    /usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryUsageDescription string $photo_desc" "$plist" 2>/dev/null || :
  else
    insert_plist_string "NSCameraUsageDescription" "$camera_desc" "$plist"
    insert_plist_string "NSPhotoLibraryUsageDescription" "$photo_desc" "$plist"
  fi
fi

# Flutter's default main manifest omits permissions and Auto Backup exclusion.
manifest=android/app/src/main/AndroidManifest.xml
if [[ -f "$manifest" ]]; then
  if ! grep -q 'android.permission.INTERNET' "$manifest"; then
    tmp="$(mktemp)"
    awk '/<application/ && !added {print "    <uses-permission android:name=\"android.permission.INTERNET\" />"; added = 1} {print}' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
  fi

  if ! grep -q 'android.permission.CAMERA' "$manifest"; then
    tmp="$(mktemp)"
    awk '/<application/ && !added {print "    <uses-permission android:name=\"android.permission.CAMERA\" />"; added = 1} {print}' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
  fi

  if ! grep -q 'android:allowBackup=' "$manifest"; then
    tmp="$(mktemp)"
    awk '
      !added && /<application([[:space:]>]|$)/ {
        if ($0 ~ /<application[[:space:]]*\r?$/) {
          print
          print "        android:allowBackup=\"false\""
        } else {
          sub(/<application/, "<application android:allowBackup=\"false\"")
          print
        }
        added = 1
        next
      }
      { print }
    ' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
  fi
fi

echo "Platform folders generated. Run: flutter pub get && flutter run"
