#!/bin/zsh
# Archive HoldfastBrick and upload to TestFlight (App Store Connect).
# Signing uses the team Admin key: -allowProvisioningUpdates with cloud signing
# needs Admin (App Manager keys get "Cloud signing permission error").
# The per-app App Manager key (43MZ6ZNH2R) is for API queries/registration
# checks only. Bump CURRENT_PROJECT_VERSION in project.yml before each upload.
set -euo pipefail

TEAM_ID="2MF4Q85LAQ"
KEY_ID="N8XGRXKFNL"
ISSUER_ID="569eebd8-ce9c-4d60-a85a-e7aae3377efe"
KEY_PATH="${HOME}/Downloads/AuthKey_${KEY_ID}.p8"
PROJECT="HoldfastBrick.xcodeproj"
SCHEME="HoldfastBrick"
APP_NAME="HoldfastBrick.app"
IOS_TARGET="17.0"
APP_ID="6821129281"
WORK="$(mktemp -d)"

cd "$(dirname "$0")/.."

EXPECTED_BUILD=$(xcodegen get-project 2>/dev/null | grep -m1 CURRENT_PROJECT_VERSION | awk '{print $NF}' || true)
if [ -z "${EXPECTED_BUILD}" ]; then
  # Fall back to reading the generated project: project.yml is the source of
  # truth, HoldfastBrick.xcodeproj is generated from it.
  EXPECTED_BUILD=$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" 2>/dev/null | awk '/CURRENT_PROJECT_VERSION/ {print $3; exit}')
fi
if [ -z "${EXPECTED_BUILD}" ]; then
  echo "ABORT: could not read CURRENT_PROJECT_VERSION from the project."
  exit 1
fi

echo "Shipping build ${EXPECTED_BUILD}"

xcodebuild archive \
  -project "$PROJECT" \
  -DEVELOPMENT_TEAM="${TEAM_ID}" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "${WORK}/HoldfastBrick.xcarchive" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${KEY_PATH}" \
  -authenticationKeyID "${KEY_ID}" \
  -authenticationKeyIssuerID "${ISSUER_ID}" | tail -1

BUILT_BUILD=$(plutil -extract CFBundleVersion raw "${WORK}/HoldfastBrick.xcarchive/Products/Applications/${APP_NAME}/Info.plist")
if [ "${BUILT_BUILD}" != "${EXPECTED_BUILD}" ]; then
  echo "ABORT: archive carries CFBundleVersion='${BUILT_BUILD}' but the project says '${EXPECTED_BUILD}'. The versioning pipeline is broken; fix before uploading."
  exit 1
fi
echo "Verified archive build number: ${BUILT_BUILD}"

# ITMS-90208 fix: embedded frameworks (Citadel's NIO stack) can declare an
# older MinimumOSVersion than this app's target; App Store validation rejects
# that. Stamp the app's minimum onto every embedded framework.
# exportArchive re-signs everything afterwards, so the modified plists stay
# validly signed.
APP_IN_ARCHIVE="${WORK}/HoldfastBrick.xcarchive/Products/Applications/${APP_NAME}"
find "${APP_IN_ARCHIVE}/Frameworks" -maxdepth 1 -name "*.framework" 2>/dev/null | while read -r FW; do
  plutil -replace MinimumOSVersion -string "${IOS_TARGET}" "${FW}/Info.plist"
  echo "Stamped MinimumOSVersion=${IOS_TARGET} on $(basename "${FW}")"
done

xcodebuild -exportArchive \
  -archivePath "${WORK}/HoldfastBrick.xcarchive" \
  -exportOptionsPlist deploy/exportOptions.plist \
  -exportPath "${WORK}/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${KEY_PATH}" \
  -authenticationKeyID "${KEY_ID}" \
  -authenticationKeyIssuerID "${ISSUER_ID}" | tail -3

echo "Uploaded. Monitor processing: https://appstoreconnect.apple.com/apps/${APP_ID}/testflight"
