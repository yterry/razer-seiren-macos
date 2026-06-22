#!/usr/bin/env bash
# scripts/build-driver.sh — build the SeirenFX virtual audio driver bundle.
#
# Produces dist/SeirenFX.driver, an AudioServerPlugIn (CoreAudio HAL plug-in).
# Pure clang — no Xcode project, so it builds on a Command-Line-Tools-only Mac,
# matching the rest of seiren-mac's no-build-step promise.
#
# Usage:
#   scripts/build-driver.sh                 # ad-hoc signed (unsigned distribution)
#   SIGN_ID="Developer ID Application: …" scripts/build-driver.sh
#
# Install with scripts/install-driver.sh (needs sudo).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Driver/SeirenFX/SeirenFX.c"
PLIST="Driver/SeirenFX/Info.plist"
DIST="dist"
DRIVER="${DIST}/SeirenFX.driver"
CONTENTS="${DRIVER}/Contents"
EXE="${CONTENTS}/MacOS/SeirenFX"

# Universal so coreaudiod loads it whatever the host arch.
ARCHS=(-arch arm64 -arch x86_64)

echo "==> compiling ${SRC} (universal arm64 + x86_64)"
rm -rf "${DRIVER}"
mkdir -p "${CONTENTS}/MacOS"

clang "${ARCHS[@]}" \
  -bundle \
  -mmacosx-version-min=13.0 \
  -fobjc-arc -fmodules \
  -Wall -Wextra -Wno-unused-parameter \
  -O2 \
  -framework CoreAudio -framework CoreFoundation \
  -o "${EXE}" \
  "${SRC}"

cp "${PLIST}" "${CONTENTS}/Info.plist"

# --- Code signing --------------------------------------------------------
# coreaudiod will refuse to load an unsigned HAL plug-in. Ad-hoc signing gives
# it a valid (if not notarized) signature, which is enough for a local install
# on the machine that built it. A paid Developer ID + notarization is required
# to distribute it to other users without Gatekeeper friction.
if [[ -n "${SIGN_ID:-}" ]]; then
  echo "==> codesign with Developer ID: ${SIGN_ID}"
  codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${DRIVER}"
else
  echo "==> codesign ad-hoc (no Developer ID provided)"
  codesign --force --sign - "${DRIVER}"
fi
codesign --verify --strict --verbose=2 "${DRIVER}" || true

echo "==> built ${DRIVER}"
echo "    file: $(file -b "${EXE}")"
echo "    install with: sudo scripts/install-driver.sh"
