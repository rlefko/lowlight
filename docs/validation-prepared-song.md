# Complete song preparation

`PreparedSong` prepares one finite song for replay. Construction privately creates a `SongRenderSource`, streams every logical frame through `SongBodyLoudness`, retains the body's measurement and one constant gain, and resets the source before returning. An unmeasurable body fails explicitly. Analysis and sample preparation happen off the audio callback; neither pass stores a complete song.

The selected body alone enters fresh K-weighting, while every input frame—including intro, outro, and allocation tail—is checked against the existing measurement/gain domain. Replay applies that fixed gain followed by the accepted song-mode peak protector. It removes the protector's 160 startup frames and drains its finite endpoint, returning exactly `layout.inputFrames` aligned stereo frames. The source already removes harmonic glue's 399-frame delay.

## Ownership and lifecycle

Swift privately retains the source. The native replay borrows it exclusively and owns its gain and peak stages; destruction releases the native borrower before the source. Construction uses the existing gradual-underflow preparation scope, and native processing preserves the caller's floating-point state. There is no second public owner that can advance or reset the source independently.

Rendering uses fixed 256-frame scratch buffers and performs no allocation, freeing, locks, or I/O. Calls must be serialized. Empty capacity and EOF return zero; unused output capacity is cleared. Invalid dimensions preserve progress. An unexpected downstream failure silences the entire call and latches a terminal fault until reset, without claiming rollback of already advanced internal state. Reset rewinds source and peak history while retaining the measurement, gain, and prepared samples.

## Validation

Eleven native suites pass optimized and under AddressSanitizer/UndefinedBehaviorSanitizer; replay also passes on x86_64. Tests compare an independent source→gain→peak chain around the 160-frame boundary, translated origins, irregular pulls, EOF, and partial/full resets. A hot-intro/outro control is checked against frozen original peak probes, and a real-source Swift test compares every protected sample with independently composed stages. These cases exercise active reduction, unlike the accepted first song where song protection is inactive.

Tests audit allocation/free counts, setup cleanup, buffer bounds, and floating-point restoration across rounding/flush modes and clear/seeded status flags. Test-only redirected calls inject source, gain, peak-processing, and drain failures, including an oversized drain report. No injection hook enters production builds. Optimized Swift IR confirms that the public constructor enters the preparation scope before analysis, native destruction precedes source release, and the render wrapper uses no allocation or floating-point arithmetic.

The replay allocation is 6,192 bytes on ARM64, including 6,144 bytes of fixed scratch. Existing source, gain, and peak allocations are additional. Analysis temporarily uses one 2,048-byte stereo buffer and the existing 131,424-byte meter state; it does not retain full-song PCM.

The complete accepted first song passes through the public preparation and replay API: 621 events, 3,711,911 stereo frames, and 23,363,076 prepared PCM bytes, with no steals or dropped events. Output and irregular reset replay are byte-identical to the prior mastered baseline, SHA-256 `b502ea12dbda0d5e08a976ed72bd1b935902941e8a781269e8917bc40c890c46`. Analysis retains −30.318920002223475 LUFS and 859/859/849 total/absolute/gated blocks, choosing +9.818920002223475 dB once. The resulting body measures −20.50000001274574 LUFS. Comparison with unchanged original mastering of the retained original pre-gain song gives maximum/RMS error `1.0430813e-7` / `7.9559536e-9`, within the existing peak-stage `2e-6` / `2e-7` limits. This complete-song diagnostic is local evidence; it adds no long recording to the repository.

All 193 deterministic exports remain byte-identical to PR #27, and all 14 unchanged reference comparison gates pass. All 59 Swift audio tests in 19 suites pass in Debug and Release, with a final focused Debug rerun covering the drain-bound defense. The Release app build, seven simulator integration tests, UI smoke test, strict formatting/lint, resource checks, and 13 extraction-guard tests pass.

## Local preparation cost

Three sequential Release trials on an Apple M4 Max with Swift 6.3.3 and macOS 26.6 used the complete 116-second song and warmed files. Separate equivalent-source probes measured source construction (including air normalization) and analysis; the public factory was also timed directly.

| Phase | Median wall time |
| --- | ---: |
| Source construction | 0.336 s |
| Body analysis over all input frames | 0.533 s |
| Complete `PreparedSong` construction | 0.869 s |
| First 256-frame replay call | 82.75 µs |
| Sum of all replay calls | 0.554 s |

Complete preparation ranged from 0.863–0.870 seconds; median process CPU time was 0.869 seconds. Replay averaged 38.18 µs per 256-frame call, with a 49.71 µs median trial p99 and a 132.83 µs worst observed call. Timing excludes the diagnostic fingerprint work; all three fingerprints match the mastered baseline. Process peak RSS ranged from 40.4–45.6 MiB and is cumulative, including allocator/cache effects rather than a per-rack bound. These are warm host observations, not cold-launch, soak, battery, or iPhone deadline evidence.

This prepares one song, not a continuous session. Song protection retains the existing smoothed response rather than promising a hard peak ceiling or a final body at exactly −20.5 LUFS. Global protection after overlap, shared two-rack limits, planner/time-conversion boundaries, nonzero-origin reference import, transport, playback, and physical-device performance remain separate work.
