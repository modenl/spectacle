# ModernSpectacle

ModernSpectacle is a Swift rewrite of Spectacle's core macOS window-management behavior.

The rewrite intentionally avoids the riskiest parts of the legacy project:

- no Carthage dependency bootstrap;
- no Sparkle 1.x updater or DSA update signature chain;
- no bundled JavaScript execution for window-layout calculations;
- no AppleScript automation to drive System Settings;
- no network access except a once-a-day update check against the store, which sends only the app version and can be turned off in Settings. Windows are ranked by Apple's on-device model; nothing leaves the Mac.

The app is structured as a Swift package so the deterministic layout engine can be tested without launching a privileged UI process.

## Features

- The classic Spectacle shortcuts (halves, quarters, thirds, displays, undo/redo).
- Smart Arrange (⌃⌥⌘M): Apple's on-device model (Apple Intelligence) ranks the windows by what you are doing; the display's template is filled from that ranking. Press M again while still holding ⌃⌥⌘ to switch between the display's three templates. Where Apple Intelligence is not available, windows are ranked by focus and recency. Bring to Main (⌃⌥⌘↩) swaps the focused window into the main slot.
- Every shortcut can be changed in Settings.
- Saved layouts: Save Layout… in the menu names the current arrangement; ⌃⌥⌘1…9 restores it, matching windows by app and title and moving them back to their display.
- English and Simplified Chinese UI, following the system language or the choice in Settings.
- Update notice: once a day the app asks the store (store.alvumo.xyz) whether a newer version is out and offers to open the download. Nothing is downloaded or installed automatically.

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

`build-app.sh` builds two versions:

- Direct download (default): signed with Developer ID when that certificate is present, hardened runtime, notarized before publishing. Outside the App Sandbox; checks the store once a day for updates.
- Mac App Store (`DISTRIBUTION=appstore ./build-app.sh`, output in `dist/appstore`): App Sandbox on, no network entitlement, compiled with `APP_STORE`, which leaves out the update check, the store link and the `spectacle-cli trigger` hooks. Apple's developer support says sandboxed apps cannot use the Accessibility APIs, so this build may not be able to move windows at all; test it on a clean Mac before submitting. With an Apple Distribution certificate, a Mac Installer Distribution certificate and `MAS_PROFILE=<provisioning profile>` it signs the app and writes `dist/appstore/ModernSpectacle-<version>.pkg` for Transporter; without them it signs the sandboxed app for local testing.

`DEV_HOOKS=1 ./build-app.sh` keeps the `spectacle-cli trigger` hooks and writes `last-arrangement.json` for debugging. Never publish such a build: any local process could then move windows with the app's Accessibility permission.

Each upload to App Store Connect needs a higher build number: `BUILD_NUMBER=5 DISTRIBUTION=appstore ARCHS="arm64 x86_64" ./build-app.sh`.

Use `SMAppService` for launch-at-login registration. Do not restore the legacy helper app or AppleScript path.
