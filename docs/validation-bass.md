# Native accepted bass

The offline mixer now includes the accepted `render_room.bass_voice` alongside guitar and piano. This continues milestone 4. [Percussion is now implemented](validation-percussion.md); room/compression, bus gains, mastering, continuous transport, and app playback remain separate work.

## Sound and ownership

The existing preparer selects layer-one recorded bass in manifest order, with two takes per root and round-robin modulo two. MIDI 31–57 uses shifts from −3 to +8 semitones. Ties retain the reference choices: 31/36 select root 34, and 41 selects 38. The ten mono source assets remain unchanged. Metadata enforces root order, distinct asset paths, and at most 80,000 input frames; takes retain manifest order. Prepared bodies contain at most 89,797 frames.

Preparation runs off the callback: the existing denominator-2048 polyphase resampler, second-order low-pass at 1,800 Hz, high-pass at 180 Hz, low-pass at 650 Hz, then Float32 scaling by 0.08. These are three distinct zero-state filters with Float32 conversion after each. The existing guitar/piano filter defaults are unchanged. Bass preparation ignores finite warmth values and adds no normalization or tonal attack shaping.

The C++ voice adds the original three sine harmonics (amplitudes 0.21/0.105/0.037), exponential attack/decay, velocity exponent 1.10, gain 0.24, and cosine-squared release. Phase derives from integer sample age at 32 kHz, so buffer partitions cannot change it. Synthesis continues after the recorded touch ends, up to the supported 16-second hold plus five-second release. Double arithmetic is retained until the final Float32 conversion; centered output preserves the reference's Float32 center factor. Pan and connected articulation do not alter bass. The later bass bus gain of 1.20, ducking, and mastering are intentionally outside this voice comparison.

The same 32 MiB PCM arena, 64 sample descriptors, and 2,048 copied events remain in force. Scores containing bass reserve one existing voice slot: at most 63 guitar/piano/percussion readers plus one bass reader, including fades. Scores without bass retain all 64 slots. Tonal stealing cannot displace bass. Unexpected overlapping bass requests reuse its slot with the existing 160-frame fade and one pending replacement; additional requests while that replacement is pending are dropped and counted. This preserves strict monophony and bounds any accepted replacement's onset delay to five milliseconds. The accepted planner already produces nonoverlapping bass, so its normal score needs no such correction.

Sample/event copies remain immutable during rendering. Setup, loading, reset, and destruction require an idle single-owner renderer. Bass loads validate MIDI 31–57, mono touch PCM, duration bounds, and `start + hold + release ≤ 2^52` before changing state. The render path retains the allocation/free audit, floating-point control restoration, and bounded subblocks described in [tonal voice validation](validation-voices.md).

## Reference evidence

The [frozen bass fixture](../tests/fixtures/bass-v9/README.md) contains six unchanged note-ons from the first 12 seconds of the accepted score, rendered for 13 seconds including tails. It exercises all four selected roots, both takes, repeated pitch, short/long notes, and synthesis beyond recorded PCM. Five prepared bodies occupy 1,459,884 bytes. Both channels are exactly equal, and silence begins at frame 385,743. The raw reference and canonical absolute endpoints agree exactly for this excerpt; five later events in the full accepted score have the existing one-frame rounding distinction, so broader comparisons must account for that clock contract.

Predeclared limits are maximum absolute sample error ≤ `1e-5` and RMS error ≤ `1e-6`. Across all 54 supported note/take preparations (3,819,940 mono values), the local worst absolute error is `7.4506e-9`, with worst per-case RMS `3.8981e-10`. Across all 832,000 stereo excerpt values, maximum error is `3.7253e-9` and RMS error is `4.9112e-10`. Native/reference dry levels are approximately −38.298 LUFS and −30.001 dBTP with 4× oversampling. These are isolated bass levels, not full-song targets. No level correction is hidden in the A/B files.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-bass.py --integrity
.tools/reference/bin/python tools/reference/verify-bass.py \
  --compare .build/tonal-native/bass --evidence .build/tonal-evidence/bass
```

Local optimized and ASan/UBSan kernel tests pass, including a complete 672,000-frame bass lifetime, touch exhaustion, zero/tiny releases, velocity, ignored pan/articulation, bounds, invalid-load preservation, mono replacement/drop behavior, mixed saturation, partition identity, reset, allocation/free counts, and floating-point controls. All nine audio tests pass in Debug and Release. The iOS 26.5 simulator passes five integration tests and the launch/About/relaunch UI test, including bass synthesis after the recorded touch ends; the unsigned iPhone Release build also passes with Xcode 26.6/Swift 6.3.3.

The Python verifier compares every prepared and rendered native sample. It rejects corruption, NaNs, truncation, missing/extra candidates, even tiny nonzero tails, and channel asymmetry. Re-freezing in the pinned local environment is byte-identical; replacement requires explicit review and is never run by CI. The seven-day `tonal-preparation-comparison` artifact includes `bass/comparison.json` and the aligned `bass-prefix-reference.wav` / `bass-prefix-native.wav` pair. At unchanged playback volume, compare the pluck/body balance and the sustained decay.

An exploratory Apple M4 Max host probe used Apple clang 21, C++17 `-O2 -ffp-contract=off`, 63 stereo piano voices plus one bass, 256-frame callbacks, and 32 kHz. Each scenario measured 30,000 callbacks after 2,500 warmups. Steady p99/p99.9/worst were 102/112/594 µs; repeated whole-pool tonal stealing while bass continued measured 129/139/307 µs. Every callback retained 64 active voices with zero drops. Peak process RSS was about 23.6 MB, including the harness/runtime. Setup/reset/checks were excluded and scheduling/load were uncontrolled; these results do not establish device deadlines, whole-app memory, or energy use. Physical iPhone validation remains pending.
