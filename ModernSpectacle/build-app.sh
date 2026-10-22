#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ModernSpectacle"
PRODUCT_NAME="ModernSpectacle"
BUNDLE_ID="${BUNDLE_ID:-xyz.alvumo.ModernSpectacle}"
VERSION="0.3.0"
BUILD_NUMBER="${BUILD_NUMBER:-4}"
TEAM_ID="${TEAM_ID:-7MH8YWVA8U}"
CONFIGURATION="${CONFIGURATION:-release}"
# DISTRIBUTION=appstore builds the Mac App Store version into dist/appstore: sandboxed, without the update check,
# the store link or the developer hooks. It is signed for upload when an Apple Distribution certificate, an installer
# certificate and MAS_PROFILE=<path to the Mac App Store provisioning profile> are present, and for local testing
# otherwise.
DISTRIBUTION="${DISTRIBUTION:-direct}"
# Space-separated list, e.g. ARCHS="arm64 x86_64" for a universal binary.
ARCHS="${ARCHS:-}"
ARCH_FLAGS=()
for arch in ${ARCHS}; do
  ARCH_FLAGS+=(--arch "${arch}")
done
if [[ "${DISTRIBUTION}" == "appstore" ]]; then
  ARCH_FLAGS+=(-Xswiftc -DAPP_STORE)
fi
# DEV_HOOKS=1 keeps the `spectacle-cli trigger` hooks and the last-arrangement.json dump, for testing on this Mac.
# Never publish such a build: any local process could then move windows with this app's Accessibility permission.
if [[ "${DEV_HOOKS:-}" == "1" ]]; then
  ARCH_FLAGS+=(-Xswiftc -DDEV_HOOKS)
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
if [[ "${DISTRIBUTION}" == "appstore" ]]; then
  DIST_DIR="${DIST_DIR}/appstore"
fi
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

swift build \
  --package-path "${SCRIPT_DIR}" \
  --configuration "${CONFIGURATION}" \
  --product "${PRODUCT_NAME}" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_DIR="$(swift build \
  --package-path "${SCRIPT_DIR}" \
  --configuration "${CONFIGURATION}" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} \
  --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_DIR}/${PRODUCT_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "${SCRIPT_DIR}/Resources/PrivacyInfo.xcprivacy" "${RESOURCES_DIR}/"

# Build AppIcon.icns from the 1024px source PNG.
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${SCRIPT_DIR}/Resources/AppIcon.png" \
    --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "${SCRIPT_DIR}/Resources/AppIcon.png" \
    --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "${ICONSET_DIR}" --output "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "$(dirname "${ICONSET_DIR}")"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
	</array>
	<key>CFBundleAllowMixedLocalizations</key>
	<true/>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Alvumo. Based on Spectacle by Eric Czarny (MIT License).</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

cat > "${CONTENTS_DIR}/PkgInfo" <<'PKGINFO'
APPL????
PKGINFO

find_identity() {
  # Installer certificates are not code-signing identities, so search every valid identity.
  security find-identity -v 2>/dev/null | sed -n "s/.*\"\(${1}.*\)\"/\1/p" | head -n 1
}

if [[ "${DISTRIBUTION}" == "appstore" ]]; then
  APP_IDENTITY="$(find_identity "Apple Distribution:")"
  [[ -n "${APP_IDENTITY}" ]] || APP_IDENTITY="$(find_identity "3rd Party Mac Developer Application:")"
  INSTALLER_IDENTITY="$(find_identity "3rd Party Mac Developer Installer:")"
  [[ -n "${INSTALLER_IDENTITY}" ]] || INSTALLER_IDENTITY="$(find_identity "Mac Installer Distribution:")"
  PROFILE="${MAS_PROFILE:-}"

  if [[ -n "${APP_IDENTITY}" && -n "${INSTALLER_IDENTITY}" && -f "${PROFILE}" ]]; then
    cp "${PROFILE}" "${CONTENTS_DIR}/embedded.provisionprofile"
    ENTITLEMENTS="$(mktemp)"
    cp "${SCRIPT_DIR}/Resources/ModernSpectacle-AppStore.entitlements" "${ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${TEAM_ID}.${BUNDLE_ID}" \
      -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" "${ENTITLEMENTS}"
    codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS}" \
      --sign "${APP_IDENTITY}" "${APP_DIR}" >/dev/null
    rm -f "${ENTITLEMENTS}"
    PKG="${DIST_DIR}/${APP_NAME}-${VERSION}.pkg"
    productbuild --component "${APP_DIR}" /Applications --sign "${INSTALLER_IDENTITY}" "${PKG}" >/dev/null
    echo "${PKG}"
    exit 0
  fi

  # Not ready for upload: sign with the development identity so the sandboxed app can be tried on this Mac.
  DEV_IDENTITY="${CODE_SIGN_IDENTITY:-$(find_identity "Apple Development:")}"
  codesign --force --options runtime --entitlements "${SCRIPT_DIR}/Resources/ModernSpectacle-AppStore.entitlements" \
    --sign "${DEV_IDENTITY:--}" "${APP_DIR}" >/dev/null
  [[ -n "${APP_IDENTITY}" ]] || echo "missing: an Apple Distribution certificate" >&2
  [[ -n "${INSTALLER_IDENTITY}" ]] || echo "missing: a Mac Installer Distribution certificate" >&2
  [[ -f "${PROFILE}" ]] || echo "missing: MAS_PROFILE=<path to the Mac App Store provisioning profile>" >&2
  echo "signed for local testing only" >&2
  echo "${APP_DIR}"
  exit 0
fi

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
    | head -n 1)"
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
  # Hardened runtime always; a secure timestamp too unless signing for development (notarization needs both).
  TIMESTAMP=(--timestamp)
  [[ "${SIGN_IDENTITY}" == "Apple Development:"* ]] && TIMESTAMP=()
  codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} \
    --entitlements "${SCRIPT_DIR}/Resources/ModernSpectacle.entitlements" \
    --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  codesign --verify --strict "${APP_DIR}"
else
  codesign --force --sign - "${APP_DIR}" >/dev/null
  echo "warning: no Apple Development signing identity found; used ad-hoc signing." >&2
  echo "warning: macOS may require Accessibility permission again after each rebuild." >&2
fi

echo "${APP_DIR}"
