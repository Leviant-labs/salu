#!/usr/bin/env bash
# Existing platform code is authoritative. Never regenerate app source or hosts
# over user permissions, signing, or bootstrap changes.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v flutter >/dev/null || { echo 'flutter not found on PATH' >&2; exit 1; }
if [[ -d android && -d ios ]]; then
  echo 'Android and iOS hosts already exist; preserved.'
  exit 0
fi
salu_platform_tmp=$(mktemp -d)
trap 'rm -rf "$salu_platform_tmp"' EXIT
flutter create --empty --project-name salu --org pt.salu --platforms android,ios --no-pub "$salu_platform_tmp/host"
for platform in android ios; do
  if [[ ! -d "$platform" ]]; then cp -R "$salu_platform_tmp/host/$platform" "$platform"; fi
done
