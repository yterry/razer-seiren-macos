#!/usr/bin/env bash
# scripts/install-driver.sh — install (or reinstall) the SeirenFX driver.
#
# Copies dist/SeirenFX.driver into the system HAL plug-in directory and bounces
# coreaudiod so it loads. Requires sudo (writes to /Library and restarts a
# system daemon). Run scripts/build-driver.sh first.
#
#   sudo scripts/install-driver.sh
#
# Uninstall:  sudo scripts/install-driver.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_NAME="SeirenFX.driver"
SRC="dist/${DRIVER_NAME}"
DEST="${HAL_DIR}/${DRIVER_NAME}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "error: must run as root — use: sudo scripts/install-driver.sh" >&2
  exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> removing ${DEST}"
  rm -rf "${DEST}"
  echo "==> restarting coreaudiod"
  killall coreaudiod 2>/dev/null || true
  echo "==> uninstalled."
  exit 0
fi

if [[ ! -d "${SRC}" ]]; then
  echo "error: ${SRC} not found — run scripts/build-driver.sh first" >&2
  exit 1
fi

echo "==> installing ${SRC} → ${DEST}"
mkdir -p "${HAL_DIR}"
rm -rf "${DEST}"
cp -R "${SRC}" "${DEST}"
# The HAL plug-in must be owned by root and not group/other-writable.
chown -R root:wheel "${DEST}"
chmod -R 755 "${DEST}"

echo "==> restarting coreaudiod (audio will glitch for ~1s)"
killall coreaudiod 2>/dev/null || true

echo "==> done. Check it loaded with:"
echo "    system_profiler SPAudioDataType | grep -A2 'Seiren FX'"
echo "    # or open Audio MIDI Setup — 'Seiren FX' should appear."
