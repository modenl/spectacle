#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ModernSpectacle"
PRODUCT_NAME="ModernSpectacle"
BUNDLE_ID="${BUNDLE_ID:-xyz.alvumo.ModernSpectacle}"
VERSION="0.3.8"
CONFIGURATION="${CONFIGURATION:-release}"
# Space-separated list, e.g. ARCHS="arm64 x86_64" for a universal binary.
ARCHS="${ARCHS:-}"
ARCH_FLAGS=()
for arch in ${ARCHS}; do
  ARCH_FLAGS+=(--arch "${arch}")
done
# DEV_HOOKS=1 keeps the `spectacle-cli trigger` hooks and the last-arrangement.json dump, for testing on this Mac.
# Never publish such a build: any local process could then move windows with this app's Accessibility permission.
if [[ "${DEV_HOOKS:-}" == "1" ]]; then
  ARCH_FLAGS+=(-Xswiftc -DDEV_HOOKS)
fi

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
mkdir -p "${CONTENTS_DIR}/Frameworks"
ditto "${BIN_DIR}/Sparkle.framework" "${CONTENTS_DIR}/Frameworks/Sparkle.framework"
# Declares both languages to AppKit and Sparkle, so the text they draw is translated too.
for lang in en zh-Hans; do
  mkdir -p "${RESOURCES_DIR}/${lang}.lproj"
  echo '/* Strings are in the code: L("English", "中文"). */' > "${RESOURCES_DIR}/${lang}.lproj/InfoPlist.strings"
done
# The Jev key built into the app, if jev.key exists (gitignored). Anyone with the app can read it.
if [[ -s "${SCRIPT_DIR}/jev.key" ]]; then
  cp "${SCRIPT_DIR}/jev.key" "${RESOURCES_DIR}/jev.key"
fi

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
	<string>${VERSION}</string>
	<key>SUFeedURL</key>
	<string>https://store.alvumo.xyz/app/modern-spectacle/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>b0k56U7FaPBkMteSMna1a94jHtf00w6sMXU2bUwPZLs=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
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

# Developer ID when available, so local builds carry the same signature as published ones: macOS keeps the
# Accessibility permission for one signature, and switching between the two leaves the switch on but not working.
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
for prefix in "Developer ID Application:" "Apple Development:"; do
  [[ -n "${SIGN_IDENTITY}" ]] && break
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/.*\"\(${prefix}.*\)\"/\1/p" \
    | head -n 1)"
done

if [[ -n "${SIGN_IDENTITY}" ]]; then
  # Hardened runtime always; a secure timestamp too unless signing for development (notarization needs both).
  TIMESTAMP=(--timestamp)
  [[ "${SIGN_IDENTITY}" == "Apple Development:"* ]] && TIMESTAMP=()
  # Sparkle's helpers first, inside out, then the framework, then the app.
  SPARKLE="${CONTENTS_DIR}/Frameworks/Sparkle.framework/Versions/B"
  for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --preserve-metadata=entitlements \
      --sign "${SIGN_IDENTITY}" "${SPARKLE}/${part}" >/dev/null
  done
  codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} \
    --sign "${SIGN_IDENTITY}" "${CONTENTS_DIR}/Frameworks/Sparkle.framework" >/dev/null
  codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} \
    --entitlements "${SCRIPT_DIR}/Resources/ModernSpectacle.entitlements" \
    --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  codesign --verify --strict "${APP_DIR}"
else
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null
  echo "warning: no Apple Development signing identity found; used ad-hoc signing." >&2
  echo "warning: macOS may require Accessibility permission again after each rebuild." >&2
fi

echo "${APP_DIR}"
