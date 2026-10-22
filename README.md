# Spectacle

Easily organize windows without using a mouse.

This repository now contains only [`ModernSpectacle`](ModernSpectacle/README.md), a Swift rewrite of Spectacle for current macOS with Smart Arrange (window layouts ranked by Apple's on-device model). The original Objective-C app by Eric Czarny is in this repository's git history.

## Build and run

```sh
swift test --package-path ModernSpectacle
ModernSpectacle/build-app.sh
open ModernSpectacle/dist/ModernSpectacle.app
```

For a universal binary, set `ARCHS="arm64 x86_64"` when running `build-app.sh`.

The app runs from the menu bar and needs Accessibility permission in System Settings.

## License

Copyright (c) 2017 Eric Czarny. See [LICENSE.md](LICENSE.md).
