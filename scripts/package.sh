#!/usr/bin/env bash
# scripts/package.sh — assemble Seiren.app from a SwiftPM release build.
#
# Usage:
#   VERSION=0.1.0 scripts/package.sh                     # ad-hoc (unsigned) .app
#   VERSION=0.1.0 SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/package.sh
#   VERSION=0.1.0 ARCHS="arm64 x86_64" scripts/package.sh # universal binary
#
# Produces dist/Seiren.app, dist/Seiren-<version>.zip, and a .sha256 checksum.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
EXE="seiren-mac"                       # executable target name in Package.swift
APP_NAME="Seiren"
BUILD_DIR=".build/release"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
PLIST_SRC="Sources/seiren-mac/Info.plist"   # the canonical, linker-embedded plist

# Default to the host arch; opt into a universal build with ARCHS="arm64 x86_64".
# (Bash 3.2 on macOS treats an empty array under `set -u` as unbound, so guard
# every expansion with the ${arr[@]+...} idiom.)
ARCH_FLAGS=()
for a in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$a"); done

echo "==> swift build -c release ${ARCH_FLAGS[*]:-(native)}"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${BUILD_DIR}/${EXE}" "${CONTENTS}/MacOS/${EXE}"
chmod +x "${CONTENTS}/MacOS/${EXE}"

# Bundle Info.plist = the same plist embedded in the binary, with the version
# stamped in. PlistBuddy is always present on macOS and is robust vs. sed.
cp "${PLIST_SRC}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${CONTENTS}/Info.plist"

# Icon (optional): build AppIcon.icns from Resources/AppIcon.png if present.
if [[ -f Resources/AppIcon.png ]]; then
  echo "==> building AppIcon.icns"
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "${ICONSET}"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "${ICONSET}/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${CONTENTS}/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS}/Info.plist" 2>/dev/null || true
fi

# --- Bundle the SeirenFX virtual-audio driver ----------------------------
# Ship the driver inside the app so it can install itself from the menu
# (Voice ▸ Install Seiren FX…), enabling EQ in OBS/Zoom without Terminal.
# build-driver.sh signs it ad-hoc (or with SIGN_ID, passed through).
echo "==> building + bundling SeirenFX.driver"
SIGN_ID="${SIGN_ID:-}" scripts/build-driver.sh
cp -R "${DIST}/SeirenFX.driver" "${CONTENTS}/Resources/SeirenFX.driver"

# --- Code signing --------------------------------------------------------
if [[ -n "${SIGN_ID:-}" ]]; then
  echo "==> codesign with Developer ID: ${SIGN_ID}"
  # Hardened Runtime (--options runtime) is REQUIRED for notarization.
  codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${APP}"
else
  echo "==> codesign ad-hoc (no Developer ID provided)"
  # Ad-hoc gives the app a stable local identity so TCC can attribute the mic
  # grant. It does NOT pass notarization / Gatekeeper — users do a one-time
  # bypass (see README). Pass SIGN_ID to sign properly.
  codesign --force --sign - "${APP}"
fi
codesign --verify --strict --verbose=2 "${APP}" || true

# --- Zip for distribution (ditto preserves the bundle structure) ---------
ZIP="${DIST}/${APP_NAME}-${VERSION}.zip"
echo "==> zipping ${ZIP}"
( cd "${DIST}" && ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$(basename "${ZIP}")" )

shasum -a 256 "${ZIP}" | tee "${ZIP}.sha256"
echo "==> done: ${ZIP}"
