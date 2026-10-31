# Native event and transition validation

This change completes milestone 3's event and timeline preparation. It adds no audible playback. Validation uses Xcode 26.6 (17F113), Swift 6.3.3, and the iOS 26.5 simulator; physical-device and iOS 18 evidence remain pending.

The independent Python oracle contains three complete native-v1 scores: 603 Focus events, 856 events with incoming 60→100/outgoing 100→60 BPM ramps, and 863 events with an incoming 100→60 BPM ramp. Together they exercise all seven instruments, seven roles, and three articulations. Its manifest freezes source/fixture hashes, a one-frame endpoint tolerance, and 1e-12 scalar tolerance. The verifier rederives these expectations without consulting Swift. The original 621-event v9 score remains unchanged and imports through a separate validated path.

The Swift suite compares every event in order, including pitches, roles, takes, expressive offsets, velocities, pan, gate/release endpoints, and transition pivots. It checks repeated-pitch and bass damping, incompatible-chord releases, bounded event storage, and harmonic/bass interval occupancy. Those intervals do not account for rendered percussion or effect tails and do not prove a 64-voice engine budget.

`./scripts/test-planner` passed all 22 tests in 1.926 seconds; `./scripts/test-planner release` passed the same suite in 1.040 seconds. Release test compilation took 13 seconds locally. Both configurations run in hosted CI.

`./scripts/build test` passed both iOS planning/resource integration tests, all 77 decoded bank checks, and the launch/About/relaunch UI smoke. The final run includes native event generation, shared-frame agreement, and timeline restoration on iOS. `./scripts/build release`, strict formatting/lint, and repository checks also passed.

Timing coverage includes all 144 key/mode pairs in both 60↔100 BPM directions, quarter beats and small offsets, a 24-hour origin, complementary elapsed-time tonal fades, and the 75 ms outgoing rhythm cutoff. A 1,100-song timeline checks shared endpoints without accumulating overlap drift, bounded checkpoints, and restoration. Position/continuation tests also cover settings changes and malformed or incompatible state. This is accelerated score-time validation, not a real-time audio soak.

The frozen renderer reproduced both existing short FLAC fixtures with zero sample error and zero loudness difference; all 11 source/fixture integrity hashes remain intact. The grammar verifier and all 77 bank files also passed. These are reference-preservation checks, not native DSP parity.

The unsigned Release arm64 app measures 9,710,803 bytes: 721,880 bytes of executable and 8,988,923 bytes of resources. The merged PR 3 base, rebuilt with the same toolchain and configuration, measures 9,490,275 bytes. Growth is 220,528 bytes, within the ordinary 1 MiB allowance and unchanged 12 MiB total cap. No budget exception was added; these sizes are local unsigned bundle proxies, not App Store download estimates.

The [event/shared-time decision](adrs/003-events-and-shared-time.md) records implementation and checkpoint limits. Hosted CI and CodeQL must pass before owner review and merge. Native voices, effects, transport restoration, aligned listening comparisons, and device performance remain future gates.
