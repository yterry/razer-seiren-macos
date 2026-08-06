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
CRED=(--keychain-profile "${PROFILE}")
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  CRED=(--apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}" --password "${NOTARY_PASSWORD}")
fi

json_field() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }

# Submit WITHOUT --wait and poll the status ourselves: Apple's processing runs
# for many minutes, and a single dropped connection inside `--wait` has failed
# a release before. Our own poll just retries through network blips.
SUB_ID=""
for attempt in 1 2 3; do
  echo "==> submitting to Apple notary service (attempt ${attempt})"
  SUB_ID="$(xcrun notarytool submit "${ZIP}" "${CRED[@]}" --output-format json \
    | json_field id)" && [[ -n "${SUB_ID}" ]] && break
  echo "    submit failed; retrying in 30s"
  sleep 30
done
[[ -n "${SUB_ID}" ]] || { echo "==> giving up: could not submit"; exit 1; }
echo "    submission id: ${SUB_ID}"

STATUS="In Progress"
for _ in $(seq 1 160); do   # up to ~40 minutes
  sleep 15
  STATUS="$(xcrun notarytool info "${SUB_ID}" "${CRED[@]}" --output-format json \
    2>/dev/null | json_field status || true)"
  [[ -n "${STATUS}" ]] || STATUS="(network error - retrying)"
  echo "    status: ${STATUS}"
  [[ "${STATUS}" == "In Progress" || "${STATUS}" == "(network error - retrying)" ]] || break
done

if [[ "${STATUS}" != "Accepted" ]]; then
  echo "==> notarization did not succeed (status: ${STATUS}); the notary log:"
  xcrun notarytool log "${SUB_ID}" "${CRED[@]}" || true
  exit 1
fi

echo "==> stapling the ticket to ${APP}"
xcrun stapler staple "${APP}"

echo "==> re-zipping the stapled app"
( cd dist && rm -f "Seiren-${VERSION}.zip" \
  && ditto -c -k --sequesterRsrc --keepParent "Seiren.app" "Seiren-${VERSION}.zip" )
shasum -a 256 "${ZIP}" | tee "${ZIP}.sha256"
echo "==> notarized + stapled. Gatekeeper opens this with no warning."
