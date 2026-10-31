# Native song-planning validation

PR 3 covers song-level plans and planner checkpoints. Note-event expansion, transition clocks, playback, and DSP remain separate work. The native generator has its own versioned sequence; frozen v9 sound fixtures remain unchanged.

Local validation used Xcode 26.6 (17F113), Swift 6.3.3, and the iOS 26.5 simulator:

- `./scripts/test-planner`: 11 Swift Testing tests passed in 0.833 seconds. Independent reference vectors cover RNG output, rejected integer draws, and the first four native plans. The suite covers 3,000 song plans, all 26 families and six keys, bounded four-family/64-signature history, registers, quarter-beat anchors, and organic tempo limits. This represents more than 24 hours of nominal score time, not a real-time audio soak.
- Checkpoint tests preserve pending work and changed settings across 200 further plans, verify deterministic encoding, and reject malformed/version-incompatible state. Generated checkpoints remain below 40,000 bytes; restoration rejects inputs over 65,536 bytes.
- A forced 128-attempt exhaustion case preserves the family restriction and newer signatures while relaxing only the required oldest prefix. Four 256-plan mood/energy cases verify harmonic bias at low and high energy. Invalid controls, fixed tempo, and zero variation are covered.
- `./scripts/build test`: the iOS package resource/checkpoint test, all 77 bank decoding checks, and the launch/About/relaunch smoke passed. `./scripts/build release` passed.
- `tools/reference/verify-grammar.py` confirms exact grammar agreement with the frozen source. The reproducible Python RNG adapter agrees with the four independent native test vectors. Frozen audio/source integrity remains intact.

The unsigned Release arm64 app measures 9,490,091 bytes, versus 9,187,668 bytes for the merged PR 2 built with the same configuration. The 302,423-byte increase passes the ordinary 1 MiB growth limit and unchanged 12 MiB cap; no budget exception was added. These are local unsigned bundle sizes, not App Store download estimates or hardware memory measurements.

The [native planning decision](adrs/002-native-planning.md) documents versioning and checkpoint scope. Hosted CI must also pass before owner review and merge. iOS 18 and physical-device evidence remain pending.
