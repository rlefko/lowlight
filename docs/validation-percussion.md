# Native accepted percussion

The offline mixer now renders the accepted kick, side-stick snare, closed hat, and shaker through the existing bounded C++ kernel. This continues milestone 4 with dry voices. Per-instrument bus filtering/gains, rhythm handoff fades, room/compression, mastering, and app playback remain separate work.

## Preparation and rendering

The unchanged `instruments.pitched` and `instruments.add_note` functions define the reference. The native event contract already represents kick/hat/shaker note 0 and side-stick snare note 1; open hats and ordinary snare hits remain outside that contract. Percussion introduces no random number generator or noise synthesizer. All twelve selected recorded bodies are mono, with two kick takes, two stick takes, two takes in each closed-hat layer, and four shaker takes in manifest order. The existing sound bank and its licenses are unchanged.

Preparation runs off the callback. Kick uses the first 16,640 recorded frames through a second-order 260 Hz low-pass, combined with the accepted cumulative-phase sine sweep and decay. The recorded contribution is scaled by 0.18 in Float32 before adding the Double sine contribution scaled by 0.82. Side-stick uses a second-order 3,200 Hz low-pass and 85 ms exponential decay over all 22,400 frames. Closed hat uses a second-order 6,500 Hz low-pass, truncation to 4,160 frames, and 52 ms exponential decay. Shaker preserves its full recorded take (2,644–5,419 frames). These are reusable finite bodies; all synthesis, filtering, and exponential shaping happen before rendering.

Hat layer selection uses the original Double velocity: below 0.72 selects layer one, otherwise layer two. The sample cache includes that layer and the wrapped take, so adjacent velocities that round to the same Float32 cannot reuse the wrong recording. Finite warmth values do not alter percussion. Metadata validates selected counts, unique contained asset paths, instrument directories, mono channels, 32 kHz, absent pitch roots, and bounded source lengths before decoding.

The callback reads mono PCM, applies the original pan factors, then Float32 gain: kick 0.31, stick 0.25, hat 0.27, shaker 0.11, each multiplied by velocity to the power 1.25. Note gates, releases, and connected articulation do not shorten or reshape these hits. Their natural sample ends retire the voices; future rhythm transitions require rack-level fades as in the prototype. Prepared PCM and event copies retain the 32 MiB / 64-sample / 2,048-event limits.

Percussion shares the existing 64-slot pool, or 63 slots when one is reserved for bass. It always uses the lowest priority and cannot steal a protected melody or bass. Hits count as decaying from onset for victim selection, independent of ignored gate lengths. The existing 160-frame steal fade and bounded pending/drop policy still apply. C loads require mono percussion, the supported note variant, priority zero, and a complete PCM lifetime within the timeline bound; invalid loads preserve the prior state. Rendering remains allocation/free/lock/I/O-free and independent of buffer partitions.

## Reference evidence

The [percussion fixtures](../tests/fixtures/percussion-v9/README.md) combine 36 unchanged accepted note-ons rendered for 13 seconds with a clearly labeled five-second, 20-event control score. The accepted excerpt uses six bodies (345,600 bytes); the controls cover all twelve (441,152 bytes), including shaker and the stronger hat layer absent from the excerpt. Exact silence begins at frames 392,079 and 126,400 respectively. Tests also change gates, releases, articulation, warmth, and buffer partitions while requiring identical output.

All twelve prepared bodies and every rendered sample are compared with the original Python functions. Predeclared limits remain maximum absolute error ≤ `1e-5` and RMS error ≤ `1e-6`; exact tail silence and finite values are checked separately. Locally, all 110,288 prepared mono values are bit-identical. The accepted excerpt has maximum/RMS error `9.3132e-10` / `1.8312e-11`; controls have `7.4506e-9` / `6.1620e-11`. Reference/native dry levels agree at about −34.775 LUFS / −18.227 dBTP for the excerpt and −30.467 LUFS / −9.388 dBTP for controls, using 4× peak oversampling. These are isolated voice levels, not full-song targets.

Fixtures are developer resources, never app assets, and replacement requires explicit review. Re-freezing in the pinned local environment is byte-identical. Negative controls reject corruption, NaNs, truncation, missing/extra candidates, tiny nonzero tails, and selecting the hat layer after Float32 conversion. The last error produces a maximum difference of about 0.175; the test uses adjacent Double velocities that collapse to the same Float32 value.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-percussion.py --integrity
.tools/reference/bin/python tools/reference/verify-percussion.py \
  --compare .build/tonal-native/percussion --evidence .build/tonal-evidence/percussion
```

The seven-day CI `tonal-preparation-comparison` artifact contains the `percussion` directory with full comparison metrics and aligned reference/native WAV pairs. At unchanged playback volume, compare the kick's body, stick attack, hat decay/layer change, and shaker articulation. Bus processing and mastering are excluded from both sides, and no hidden loudness correction is applied. Physical iPhone timing, memory, energy, and playback validation remain pending.

## Bounded rendering evidence

All twelve audio tests pass in Debug and Release, including the earlier tonal and bass regressions; their full Python comparisons also pass. Optimized and ASan/UBSan C++ tests pass for all four gain laws, exact pan/gain ordering, ignored gates/releases/articulation, full PCM lifetimes, invalid-load state preservation, timeline bounds, mono/variant/priority validation, melody/bass protection, steal fades, pending drops, partition identity, reset, allocation/free auditing, and floating-point control restoration. The iOS 26.5 simulator passes five integration tests plus the launch/About/relaunch UI test, including all seven instruments from the bundled bank. The unsigned iPhone Release build passes with Xcode 26.6/Swift 6.3.3.

An exploratory Apple M4 Max host probe used Apple clang 21, C++17 `-O2 -ffp-contract=off`, 31 stereo piano readers, 32 mono percussion readers, and one continuing bass. At 256 frames / 32 kHz, each scenario measured 30,000 callbacks after 2,500 warmups. Steady p99/p99.9/worst were 66/72/85 µs; repeatedly stealing all 32 percussion slots measured 68/78/152 µs. Every callback retained 64 voices, zero drops, and the expected steal count. Prepared PCM occupied 21,120,164 bytes; peak process RSS reached 25.6 MB including the harness/runtime. Synthetic extended percussion PCM sustained this load; real prepared hits are shorter. Setup/reset/checks were excluded, and host load/scheduling were uncontrolled. These measurements establish no device deadline, whole-app memory, or energy guarantee.
