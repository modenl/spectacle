# ModernSpectacle

ModernSpectacle is a Swift rewrite of Spectacle's core macOS window-management behavior.

The rewrite intentionally avoids the riskiest parts of the legacy project:

- no Carthage dependency bootstrap;
- no Sparkle 1.x updater or DSA update signature chain;
- no bundled JavaScript execution for window-layout calculations;
- no AppleScript automation to drive System Settings;
- no automatic network access.

The app is structured as a Swift package so the deterministic layout engine can be tested without launching a privileged UI process.

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
