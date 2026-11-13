#!/usr/bin/env bash
# Verify the archive users download, including the bundled audio driver.
# Usage: SIGNED=true scripts/verify-release.sh <zip> <version>
# SIGNED defaults to false for ad-hoc builds without notarization.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <zip> <version>" >&2
  exit 1
fi

ZIP="$1"
VERSION="$2"

fail() {
  echo "error: $*" >&2
  exit 1
}

echo "==> checking ${ZIP}.sha256"
EXPECTED_SHA="$(awk '{print $1}' "${ZIP}.sha256")"
[[ "${EXPECTED_SHA}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 checksum file"
ACTUAL_SHA="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]] || fail "archive checksum does not match"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seiren-release.XXXXXX")"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
APP="${WORK_DIR}/Seiren.app"
DRIVER="${APP}/Contents/Resources/SeirenFX.driver"

echo "==> extracting ${ZIP}"
ditto -x -k "${ZIP}" "${WORK_DIR}"

echo "==> verifying app and driver signatures"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign --verify --deep --strict --verbose=2 "${DRIVER}"

echo "==> checking universal binaries and app version"
for ARCH in arm64 x86_64; do
  lipo "${APP}/Contents/MacOS/seiren-mac" -verify_arch "${ARCH}"
  lipo "${DRIVER}/Contents/MacOS/SeirenFX" -verify_arch "${ARCH}"
done
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
[[ "${APP_VERSION}" == "${VERSION}" ]] || fail "expected version ${VERSION}, found ${APP_VERSION}"

if [[ "${SIGNED:-false}" == true ]]; then
  echo "==> checking notarization and Gatekeeper assessment"
  xcrun stapler validate "${APP}"
  if ! ASSESSMENT="$(spctl --assess --type execute -vv "${APP}" 2>&1)"; then
    fail "Gatekeeper assessment failed: ${ASSESSMENT}"
  fi
  echo "${ASSESSMENT}"
  grep -Fxq 'source=Notarized Developer ID' <<< "${ASSESSMENT}" \
    || fail "Gatekeeper did not report a notarized Developer ID"

  echo "==> checking microphone entitlement and hardened runtime"
  codesign --display --entitlements - --xml "${APP}" > "${WORK_DIR}/entitlements.plist"
  AUDIO_INPUT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "${WORK_DIR}/entitlements.plist")"
  [[ "${AUDIO_INPUT}" == true ]] || fail "microphone entitlement is not enabled"
  APP_SIGNATURE="$(codesign --display --verbose=4 "${APP}" 2>&1)"
  grep -Eq '^CodeDirectory .*flags=0x[[:xdigit:]]+\(([^)]*,)?runtime(,|\))' <<< "${APP_SIGNATURE}" \
    || fail "app is missing the hardened runtime flag"

  echo "==> checking app and driver team identifiers"
  DRIVER_SIGNATURE="$(codesign --display --verbose=4 "${DRIVER}" 2>&1)"
  APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<< "${APP_SIGNATURE}")"
  DRIVER_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<< "${DRIVER_SIGNATURE}")"
  [[ -n "${APP_TEAM}" && "${APP_TEAM}" != 'not set' ]] || fail "app has no team identifier"
  [[ "${DRIVER_TEAM}" == "${APP_TEAM}" ]] || fail "driver and app team identifiers differ"
fi

echo "==> verified ${ZIP} (${VERSION})"
