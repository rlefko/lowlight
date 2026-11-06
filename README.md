# Lowlight

Lowlight is an iPhone app in development for original, ongoing lo-fi music that works entirely offline. The accepted sound uses soft guitar and piano, rounded bass, restrained drums, and a shared room.

Lowlight plays an ongoing sequence of original lo-fi music from its bundled lossless note bank. Play/Pause keeps your place; Next moves into a prepared piece at a musical phrase. Background audio and lock-screen transport are integrated, and saved sessions reopen silently until you press Play. Instrument preparation and voices match the frozen reference within measured tolerances. Five presets and seven listening controls shape the sound and the music. See the [milestone status](docs/status.md) and [playback validation](docs/validation-playback-integration.md) for measured limits and device checks.

## Build

Requires macOS, Xcode 26.6 (17F113), Swift 6.3.3, and an iOS 26.5 simulator. The deployment target is iOS 18. Run from the repository root:

```sh
./scripts/setup
./scripts/test-planner
./scripts/test-dsp
./scripts/test-audio
./scripts/build test
./scripts/build release
./scripts/size-report .build/DerivedData/Build/Products/Release-iphoneos/Lowlight.app
```

Open `Lowlight.xcodeproj` and choose the shared **Lowlight** scheme for interactive development. Device signing requires your own development team. The test destination can be overridden with `SIMULATOR_DESTINATION`.

## Listening controls

Use Warmth to soften guitar, piano, and the room while the music plays. Energy changes activity and Mood steers harmony at a musical handoff. **More Controls** contains Auto or manual Tempo, Space for the room, Texture for quiet synthetic air, and Variation for changes between pieces. A preset sets all seven values. Settings are saved when you finish an adjustment.

No account, server, tracking, ads, microphone, or runtime downloads are required. The app makes no network requests and follows system appearance and Dynamic Type. Physical-device lock-screen/route behavior, accessibility, output quality, and energy measurements remain release gates; simulator results do not establish battery equivalence to local-file playback.

See [project documentation](docs/index.md) for architecture, sound provenance, testing, and performance targets.

## License and credits

Copyright © 2026 Ryan Lefkowitz. Original project code is licensed under [GPL-3.0-only](LICENSE). The 77 bundled recorded notes are CC0-1.0; see the [sound-bank provenance and notices](docs/sound-bank.md). Small adapted NumPy/PCG noise-generation and pyloudnorm loudness-meter subsets retain their [third-party code notices](docs/third-party-code.md), also available offline in About. Python reference tools and test audio are developer resources outside the app; no NumPy runtime or external runtime package is bundled.

Development accelerated with Codex
