# Accepted rhythm bus

The optional bus output continues milestone 4 with the energy-dependent rhythm balance in the unchanged v9 `session_render.render_song`. It exposes dry guitar/piano, processed bass/drums, and a mono kick-duck factor. It does not produce a finished mix: the separate [harmonic glue stage](validation-glue.md) adds focus gains and compression; room, rack fades, air, mastering, and playback remain later work.

## Signal path and state

One existing 64-voice mixer feeds seven stereo instrument sums. Four independent second-order Butterworth low-pass filters run at 32 kHz: kick 280 Hz, side-stick 1,050 Hz, closed hat 1,450 Hz, and shaker 1,200 Hz. Coefficients and channel state are Double; each filter result converts to Float32 before its bus gain. Preserve this Float32 grouping, where energy factors are calculated in Double and then converted once:

```text
drums = (kick * .50 + stick * .44) * (.85 + .45 * energy)
drums += (hat * .42) * (.9 + .35 * energy)
drums += shaker * .24
bass = (bassStem * 1.20) * (.98 + .06 * energy)
```

Every scheduled kick triggers `Float32(1 - .055 * exp(-age / 32000 / .105))` for ages 0 through 8,959, then exactly 1. Overlapping dips use their minimum. Because the common curve increases monotonically, only the newest kick's age is needed. Silent kicks, denied voices, and delayed steals still trigger at the score timestamp. The finite 8,960-value table is prepared off the callback. Bass remains unducked so the future harmonic rack can preserve the accepted `(tonal + bass) * duck + drums` grouping.

`ll_mixer_configure_buses` accepts finite energy in 0…1 before the first score load. Setup owns filter design and table preparation; configuration is immutable once loaded. The Swift offline wrapper opts in with `busEnergy` and renders into preallocated `RhythmBusFrame` storage. Existing dry stereo output preserves its slot-order sum. Both output views advance configured filters and ducking, so switching views does not discard history or create another voice pool.

Each filter continues processing zero input after its last voice retires. `activeVoices == 0` therefore does not imply silent bus output. Explicit reset and valid score reload clear filter/duck state; rejected configuration, score loads, and renders preserve it. Rendering retains bounded 256-frame subblocks, no allocation/free/locks/I/O, scoped subnormal flushing, and the existing PCM/event limits. Bus storage adds a fixed roughly 36 KiB per mixer, independent of score duration.

The future rhythm handoff fade must precede these filters, as in `session_render`; fading already filtered output would cut different tails. Per-song racks and the global output stage remain later work.

## Independent evidence

The [rhythm fixtures](../tests/fixtures/rhythm-v9/README.md) capture intermediate buses from the unchanged accepted session renderer before final mixing. Their compact manifest freezes inputs and waveform fingerprints; CI regenerates complete reference waveforms and compares every native Float32 value. The mixed accepted prefix and low/high energy controls exercise all seven instruments, stereo routing, overlapping/silent kicks, and duck expiration. Limits remain maximum absolute error `1e-5` and RMS error `1e-6`, with tighter checks for duck factors.

At introduction, local full comparison passed all 736,000 nine-field frames. The mixed prefix's maximum/RMS error is `6.1844e-6` / `1.0455e-7`, dominated by the tonal endpoint rounding later corrected for [reference imports](validation-reference-timing.md); its new drum bus maximum error is `4.6566e-10` and bass maximum is `7.4506e-9`. Low/high controls have maximum/RMS errors `7.4506e-9` / `3.3543e-10` and `1.1176e-8` / `3.6062e-10`. Duck is bit-identical throughout, and exact late silence/unity checks pass. Re-freezing produces byte-identical fixtures. Eleven negative controls reject missing/extra/truncated candidates, NaNs, altered signal/probes, tiny nonzero tails, a one-ULP duck cutoff error, corrupt event hashes, and incorrect dimensions.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-rhythm.py --integrity
.tools/reference/bin/python tools/reference/verify-rhythm.py \
  --compare .build/tonal-native/rhythm --evidence .build/tonal-evidence/rhythm
```

The seven-day CI `tonal-preparation-comparison` artifact includes aligned reference/native rhythm WAV pairs and full metrics under `rhythm`. Compare the kick/stick balance and hat decay at unchanged playback volume, including the energy endpoints. These isolated buses have no loudness normalization or final peak protection; their levels are not full-song targets. Full-mix listening and physical-device validation remain pending.

All 15 audio tests pass in Debug and Release, including the existing tonal, bass, and percussion regressions. Optimized and ASan/UBSan kernel tests pass for independent filter impulses, energy gains, routing, dry-output preservation, view switching, partition/reset/reload identity, silent/dropped kick keying, persistent tails, invalid calls, allocation/free auditing, and exact floating-point control restoration. The iOS 26.5 simulator passes five integration tests plus the launch/About/relaunch UI test, including both render views from the bundled bank. The unsigned iPhone Release build passes with Xcode 26.6/Swift 6.3.3.

## Host rendering probe

An exploratory Apple M4 Max probe used Apple clang 21, C++17 `-O2 -ffp-contract=off`, 31 stereo piano readers, 32 mono percussion readers, one bass, and all bus processing. Each scenario measured 30,000 callbacks of 256 frames after 2,500 warmups. Steady p99/p99.9/worst were 72.5/80.3/93.4 µs; repeatedly stealing all 32 percussion slots measured 74.4/86.9/145.0 µs. Every callback retained 64 voices, zero drops, and the expected steal count. Prepared PCM occupied 21,120,164 bytes; peak process RSS reached 26.7 MB including the harness/runtime. Synthetic extended hits sustained the stress load. Setup/reset/checks were excluded, and host load/scheduling were uncontrolled. These measurements establish no iPhone deadline, whole-app memory, or energy guarantee.
