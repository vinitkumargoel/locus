#!/usr/bin/env bash
#
# notarize.sh — build, sign, notarize, and staple a Developer ID release of Locus.
#
# Locus ships outside the Mac App Store (the App Sandbox blocks the CoreAudio
# process-tap used for meeting capture), so distribution is Developer ID +
# notarization with the Hardened Runtime enabled. This script automates the
# full pipeline:
#
#   1. xcodegen generate        — regenerate the .xcodeproj from project.yml
#   2. xcodebuild archive       — Release archive, Manual Developer ID signing
#   3. xcodebuild -exportArchive — export a signed, Hardened-Runtime .app
#   4. ditto -> .zip            — zip the .app for submission
#   5. notarytool submit --wait — upload to Apple and block until notarized
#   6. stapler staple           — attach the notarization ticket to the .app
#   7. spctl / stapler validate — verify Gatekeeper will accept it offline
#
# Prerequisites (see RELEASE.md for the full setup):
#   - Xcode + command-line tools (provides xcodebuild, notarytool, stapler).
#   - xcodegen on PATH (brew install xcodegen).
#   - A "Developer ID Application" certificate + private key in your keychain.
#   - A stored notarytool credential profile created once with:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#         --apple-id "you@example.com" --team-id "$TEAM_ID" \
#         --password "app-specific-password"
#
# ---------------------------------------------------------------------------
# CONFIG — edit these placeholders (or override via the environment) before use
# ---------------------------------------------------------------------------
#   TEAM_ID         your 10-character Apple Developer Team ID (also in project.yml)
#   SIGN_IDENTITY   the Developer ID Application identity to sign with
#   NOTARY_PROFILE  the keychain profile name passed to notarytool store-credentials
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Configuration (placeholders — replace before running) -----------------
TEAM_ID="${TEAM_ID:-YOUR_TEAM_ID}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Your Name (YOUR_TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-LocusNotary}"

SCHEME="Locus"
CONFIGURATION="Release"
APP_NAME="Locus"

# --- Paths ------------------------------------------------------------------
# Resolve the repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_PLIST="${BUILD_DIR}/ExportOptions.plist"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

step "Preparing build directory: ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

step "Regenerating Xcode project from project.yml (xcodegen)"
( cd "${ROOT_DIR}" && xcodegen generate )

step "Writing Developer ID export options plist: ${EXPORT_PLIST}"
# Generated inline so the release pipeline is self-contained. "developer-id"
# method = Developer ID distribution (notarized, non-App-Store). signingStyle
# manual matches the Release config in project.yml.
cat > "${EXPORT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingCertificate</key>
    <string>${SIGN_IDENTITY}</string>
    <!-- Notarization is performed explicitly below via notarytool, not here. -->
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

step "Archiving (${SCHEME} / ${CONFIGURATION}) with Hardened Runtime"
xcodebuild archive \
    -project "${ROOT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"

step "Exporting signed .app: ${APP_PATH}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_PLIST}"

step "Zipping app for notarization: ${ZIP_PATH}"
# ditto preserves the bundle structure / symlinks notarytool expects.
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

step "Submitting to Apple notary service (profile: ${NOTARY_PROFILE}) — waiting"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

step "Stapling notarization ticket to ${APP_PATH}"
xcrun stapler staple "${APP_PATH}"

step "Verifying ticket + Gatekeeper acceptance"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose "${APP_PATH}"

step "Done. Notarized, stapled app: ${APP_PATH}"
echo "Distribute either the stapled .app (re-zip with ditto) or wrap it in a"
echo "signed+notarized .dmg. See RELEASE.md for distribution options."
