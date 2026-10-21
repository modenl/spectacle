#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ModernSpectacle"
PRODUCT_NAME="ModernSpectacle"
BUNDLE_ID="${BUNDLE_ID:-dev.local.ModernSpectacle}"
CONFIGURATION="${CONFIGURATION:-release}"
# Space-separated list, e.g. ARCHS="arm64 x86_64" for a universal binary.
ARCHS="${ARCHS:-}"
ARCH_FLAGS=()
for arch in ${ARCHS}; do
  ARCH_FLAGS+=(--arch "${arch}")
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
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

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
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

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
    | head -n 1)"
fi

if [[ "${SIGN_IDENTITY}" == "Developer ID Application:"* ]]; then
  # Distribution build: hardened runtime and secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp \
    --entitlements "${SCRIPT_DIR}/Resources/ModernSpectacle.entitlements" \
    --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
elif [[ -n "${SIGN_IDENTITY}" ]]; then
  codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
else
  codesign --force --sign - "${APP_DIR}" >/dev/null
  echo "warning: no Apple Development signing identity found; used ad-hoc signing." >&2
  echo "warning: macOS may require Accessibility permission again after each rebuild." >&2
fi

echo "${APP_DIR}"
