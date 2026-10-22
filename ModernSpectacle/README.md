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

For a distributable macOS app target, use Xcode or CI to archive an app target that depends on these package targets:

- `ModernSpectacleApp`
- `ModernSpectacleServices`
- `ModernSpectacleCore`

Use a Developer ID signing identity, enable hardened runtime, notarize the archive, and keep the app outside the App Sandbox. Accessibility-based window management needs to control other applications and is not a good fit for Mac App Store sandboxing.

Use `SMAppService` for launch-at-login registration. Do not restore the legacy helper app or AppleScript path.
