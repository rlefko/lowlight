# Lowlight

Lowlight is an iPhone app in development for original, ongoing lo-fi music that works entirely offline. The accepted sound uses soft guitar and piano, rounded bass, restrained drums, and a shared room.

The app currently has a native shell, an offline About/licenses screen, and the accepted lossless note bank. A local Swift package adds deterministic song plans and checkpoint restoration; a frozen developer harness preserves the accepted sound fixtures. Music playback and controls are not implemented yet. See the [milestone status](docs/status.md) for validation and remaining work.

## Build

Requires macOS, Xcode 26.6 (17F113), Swift 6.3.3, and an iOS 26.5 simulator. The deployment target is iOS 18. Run from the repository root:

```sh
./scripts/setup
./scripts/test-planner
./scripts/build test
./scripts/build release
./scripts/size-report .build/DerivedData/Build/Products/Release-iphoneos/Lowlight.app
```

Open `Lowlight.xcodeproj` and choose the shared **Lowlight** scheme for interactive development. Device signing requires your own development team. The test destination can be overridden with `SIMULATOR_DESTINATION`.

## Product direction

Warmth, Energy, and Mood will be the primary controls. Tempo, Space, Texture, and Variation will be available in a secondary sheet. Playback will blend distinct pieces, with a bounded musical vocabulary that can recur over time.

No account, server, tracking, ads, microphone, or runtime downloads are planned. The shell makes no network requests and follows system appearance and Dynamic Type. Background audio, accessibility checks on devices, sound parity, and battery measurements remain future gates.

See [project documentation](docs/index.md) for architecture, sound provenance, testing, and performance targets.

## License and credits

Copyright © 2026 Ryan Lefkowitz. Original project code is licensed under [GPL-3.0-only](LICENSE). The 77 bundled recorded notes are CC0-1.0; see the [sound-bank provenance and notices](docs/sound-bank.md). Python reference tools and test audio are developer resources outside the app. There are no third-party app runtime dependencies.

Development accelerated with Codex
