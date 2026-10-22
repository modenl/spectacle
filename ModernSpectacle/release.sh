#!/usr/bin/env bash
# Builds the universal app, signs it with Developer ID, packs it in a dmg, notarizes and staples it, and checks that
# Gatekeeper accepts it. Prints the dmg path; publish that file to the store.
#
# Needs a "Developer ID Application" certificate in the keychain and a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials modernspectacle
# (NOTARY_PROFILE=<name> to use another profile).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${NOTARY_PROFILE:-modernspectacle}"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"

if [[ -z "${IDENTITY}" ]]; then
  echo "error: no Developer ID Application certificate; create one in Xcode → Settings → Accounts → Manage Certificates" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
  echo "error: no notarytool profile \"${PROFILE}\"; run: xcrun notarytool store-credentials ${PROFILE}" >&2
  exit 1
fi

APP="$(CODE_SIGN_IDENTITY="${IDENTITY}" ARCHS="arm64 x86_64" "${SCRIPT_DIR}/build-app.sh" | tail -n 1)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")"
DMG="${SCRIPT_DIR}/dist/ModernSpectacle-${VERSION}-universal.dmg"

STAGING="$(mktemp -d)"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
rm -f "${DMG}"
hdiutil create -volname ModernSpectacle -srcfolder "${STAGING}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGING}"
codesign --sign "${IDENTITY}" --timestamp "${DMG}"

xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${DMG}" >/dev/null
spctl -a -vv -t open --context context:primary-signature "${DMG}" 2>&1 | grep -q "source=Notarized Developer ID" \
  || { echo "error: Gatekeeper does not accept ${DMG}" >&2; exit 1; }
echo "${DMG}"
