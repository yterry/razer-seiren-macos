#!/usr/bin/env bash
# scripts/notarize.sh — notarize + staple a signed Seiren.app (requires a paid
# Apple Developer ID; only used when packaging with SIGN_ID set).
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials seiren-notary \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "<app-specific-pw>"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION}"
APP="dist/Seiren.app"
ZIP="dist/Seiren-${VERSION}.zip"
PROFILE="${NOTARY_PROFILE:-seiren-notary}"

# CI has no stored keychain profile, so credentials can also come from the
# environment (APPLE_ID + APPLE_TEAM_ID + NOTARY_PASSWORD, the app-specific
# password). Locally, the stored profile keeps working as before.
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  echo "==> submitting to Apple notary service (Apple ID from environment)"
  xcrun notarytool submit "${ZIP}" \
    --apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" \
    --password "${NOTARY_PASSWORD}" --wait
else
  echo "==> submitting to Apple notary service (profile: ${PROFILE})"
  xcrun notarytool submit "${ZIP}" --keychain-profile "${PROFILE}" --wait
fi

echo "==> stapling the ticket to ${APP}"
xcrun stapler staple "${APP}"

echo "==> re-zipping the stapled app"
( cd dist && rm -f "Seiren-${VERSION}.zip" \
  && ditto -c -k --sequesterRsrc --keepParent "Seiren.app" "Seiren-${VERSION}.zip" )
shasum -a 256 "${ZIP}" | tee "${ZIP}.sha256"
echo "==> notarized + stapled. Gatekeeper opens this with no warning."
