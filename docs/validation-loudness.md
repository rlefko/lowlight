# Body loudness meter validation

`SongLoudnessMeter` measures a known-length stereo Float32 body at 32 kHz with fixed working storage. It is a preparation step for one fixed song gain. The caller supplies only the post-HP32 body: the original renderer crops from beat 16 to the start of the outgoing transition, then initializes fresh K-weighting filter history. This PR does not select that crop, apply gain, orchestrate the rack, or enable playback.

## Accepted reference

The independent oracle uses the pinned pyloudnorm 0.1.1 default K-weighting: the 1,500 Hz +4 dB shelf followed by the 38 Hz high-pass, using its RBJ coefficients. Each Double filter result is stored as Float32 before the next stage. Squaring, pairwise reduction, and multiplication by the 400 ms window reciprocal are Float32 operations before block energies enter Double storage. Gated means preserve NumPy's Double pairwise reduction order.

Blocks have 12,800 frames and 3,200-frame hops. The block count preserves the original floating duration expression and nearest-even rounding; for example, 24,000 frames yield four blocks. A final partial block sums only available frames but still divides by 12,800. Exhaustive endpoint checks cover every possible block within the supported duration. The first gate accepts levels at or above −70 LUFS; the final gate requires levels strictly above both −70 and the relative threshold. Silence or an empty final gate succeeds with no measurable loudness, represented by Swift `nil`, rather than a usable infinite gain.

The oracle and tolerance are frozen before native comparison. Finite results must agree within 0.00001 LU; block counts, both gate counts, and measurable status must match exactly. Synthetic input uses exact Float32 periodic patterns and piecewise levels, plus a frozen original musical body excerpt. Existing acoustic goldens and tolerances remain unchanged. See the [fixture manifest](../tests/fixtures/loudness-v9/manifest.json), [freezer](../tools/reference/freeze-loudness.py), and [comparison tool](../tools/reference/verify-loudness.py).

## Bounds and lifecycle

Creation accepts 12,800 through 5,792,000 body frames. Input must be finite with magnitude at most 1,000,000. Conservative pole-radius bounds of .793 and .993 give a combined filter impulse-response absolute sum below 9,563,722; even allowing rounding margin, filtered magnitude stays below 1e13 and each Float32 power reduction below 1.28e30. This leaves substantial headroom below Float32 overflow. The meter's explicit domain is narrower than the song mix's theoretical bus bound; callers must handle rejection.

One 131,424-byte allocation (128.34 KiB) holds the stereo power ring, at most 1,807 stereo block energies, filters, and result state. This allocation is identical on ARM64 and x86_64. Processing and finalization allocate no memory. Complete-call validation precedes state changes, so an invalid last sample, excess length, or malformed Swift stereo buffer cannot consume a prefix. Premature finalization preserves progress. Successful finalization is repeatable and rejects all subsequent processing until reset, including empty buffers. Reset retains the declared body length and clears filter, power, and completion state. All calls are single-owner; analysis belongs off the audio callback. Floating-point control and status are restored after computation.

## Validation and limits

All 17 independent frozen cases match the original meter exactly in reported LUFS and all gate counts on the local ARM64 Release build. Native tests pass optimized and under AddressSanitizer/UndefinedBehaviorSanitizer; the meter also passes under x86_64/Rosetta. They cover failed allocation, invalid final samples on both channels, excess counts, premature/repeated finish, subnormals, input magnitude limits, maximum duration, chunk/reset identity, all rounding/flush modes, full floating-point status restoration, and no allocation/free during process, finish, or reset.

The complete accepted 2,756,923-frame body was also measured without retaining its PCM in the meter. On identical input, both meters return −30.3189178815849 LUFS for the current native waveform and −30.318919941908316 LUFS for the unchanged original waveform. Both have 859 total blocks, 859 initial-gate blocks, and 849 final-gate blocks. These are separate meter comparisons on each waveform, not a claim that the two waveforms match.

All 36 audio tests in 13 suites pass in Debug and Release. All 151 existing native PCM candidates remain byte-identical. The iOS 26.5 simulator passes seven integration tests and the UI smoke test, including both offline software notices. The unsigned Release device build, formatting/lint, repository/resource checks, and all 13 CodeQL coverage-guard tests pass. All seven native DSP suites pass optimized and under sanitizers. Repeat freezing reproduces the loudness fixtures exactly, and 26 negative controls reject corrupted results, inputs, recipes, and provenance.

This standalone meter does not establish whole-song waveform conformance or device performance. The existing [full-song endpoint discrepancy](validation-sample-storage.md) remains a separate gate. Fixed gain application, rack preparation/replay, two-song transport, physical-device energy comparisons, and long playback soaks remain pending.


## Preparation cost

On an Apple M4 Max host with clang 21, C++17, `-O2`, and contraction disabled, five complete analyses after one untimed body warmup measured:

| Body | Frames | Median analysis | Range | Median finish |
| --- | ---: | ---: | ---: | ---: |
| Accepted song | 2,756,923 | 23.878 ms | 23.815–25.760 ms | 5.333 µs |
| Maximum supported | 5,792,000 | 48.934 ms | 48.460–50.094 ms | 9.583 µs |

The accepted body used 53,850 total 256-frame calls across five trials, with process p99/p99.9/worst of 9.792/11.167/42.041 µs. Setup across 1,000 trials after 50 warmups had a median of 1.375 µs. Analysis timing includes chunk-loop/timer overhead and finalization, excluding source rendering, file loading, allocation, and reset. No C++ allocation or free occurred during processing or finalization. These are standalone off-thread host measurements, not iPhone audio-callback or whole-engine deadlines. Peak process RSS includes caller PCM and the harness and is not attributed to the meter; its own allocation remains 131,424 bytes.
