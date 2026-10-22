# ModernSpectacle

ModernSpectacle is a Swift rewrite of Spectacle's core macOS window-management behavior.

The rewrite intentionally avoids the riskiest parts of the legacy project:

- no Carthage dependency bootstrap;
- no Sparkle 1.x updater or DSA update signature chain (updates use Sparkle 2 with EdDSA signatures);
- no bundled JavaScript execution for window-layout calculations;
- no AppleScript automation to drive System Settings;
- no network access except a once-a-day update check against the store's appcast, which can be turned off in Settings. With a Jev key, Smart Arrange sends app names and window titles to TypeSafe to rank them; without one, nothing leaves the Mac.

The app is structured as a Swift package so the deterministic layout engine can be tested without launching a privileged UI process.

## Features

- The classic Spectacle shortcuts (halves, quarters, thirds, displays, undo/redo).
- Smart Arrange (⌃⌥⌘M): Jev, TypeSafe's decision model, ranks the windows by what you are doing (one request, typed answers, about a second); the display's template is filled from that ranking. Press M again while still holding ⌃⌥⌘ to switch between the display's three templates. Without a Jev key, windows are ranked on the Mac by focus and recency. The key comes from Settings, or is built in: put it in `jev.key` next to `build-app.sh` (gitignored) and every build bundles it. Anyone who has the app can read a built-in key. Bring to Main (⌃⌥⌘↩) swaps the focused window into the main slot.
- Every shortcut can be changed in Settings.
- Saved layouts: Save Layout… in the menu names the current arrangement; ⌃⌥⌘1…9 restores it, matching windows by app and title and moving them back to their display.
- English and Simplified Chinese UI, following the system language or the choice in Settings.
- Self-update: Sparkle checks the store's appcast (store.alvumo.xyz/app/modern-spectacle/appcast.xml) once a day and from the menu. When a newer version is out it asks, then downloads, checks the EdDSA signature against `SUPublicEDKey`, replaces the app and relaunches it.

## Build and Test

```sh
swift test --package-path ModernSpectacle
swift run --package-path ModernSpectacle ModernSpectacle
```

Running the app requires Accessibility permission because it moves windows owned by other apps.

## Local App Bundle

For normal local use, build a `.app` bundle:

```sh
ModernSpectacle/build-app.sh
open ModernSpectacle/dist/ModernSpectacle.app
```

The script creates `ModernSpectacle/dist/ModernSpectacle.app` and signs it ad-hoc for local development. If macOS blocks it, run it once from Finder or use:

```sh
xattr -dr com.apple.quarantine ModernSpectacle/dist/ModernSpectacle.app
open ModernSpectacle/dist/ModernSpectacle.app
```

Then grant Accessibility permission in System Settings.

## Distribution Notes

`build-app.sh` signs with a Developer ID Application certificate when one is in the keychain (hardened runtime, secure timestamp), otherwise with the Apple Development certificate for local use. Publish only Developer ID builds, notarized and stapled: `./release.sh` does all of it and prints the dmg to upload (it needs that certificate and a notarytool keychain profile, created once with `xcrun notarytool store-credentials modernspectacle`). The app stays outside the App Sandbox: Apple's developer support confirms that sandboxed apps cannot use the Accessibility APIs, which is why there is no Mac App Store version.

To publish, sign the dmg for Sparkle so installed copies accept it:

```bash
SPARKLE_SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update node ~/.config/webstore/publish.mjs modern-spectacle <version> dist/ModernSpectacle-<version>-universal.dmg --sparkle --notes-file <notes>
```

The EdDSA private key is in the login keychain of the Mac that ran `generate_keys`. Without it no installed copy accepts another update, so keep a backup: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>` exports it (store the file somewhere safe, never in the repo). `CFBundleVersion` equals the version string, because the store's appcast puts the version string in `sparkle:version`.

`DEV_HOOKS=1 ./build-app.sh` keeps the `spectacle-cli trigger` hooks and writes `last-arrangement.json` for debugging. Never publish such a build: any local process could then move windows with the app's Accessibility permission.

Use `SMAppService` for launch-at-login registration. Do not restore the legacy helper app or AppleScript path.
