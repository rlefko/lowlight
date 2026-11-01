# Fixed song gain validation

`SongFixedGain` prepares one immutable gain from a measurable `SongLoudnessMeasurement`, targeting −20.5 LUFS. It applies that gain to every supplied stereo frame after HP32 and before the existing song peak protector, including the intro, outro, and tails. Body selection, full-rack preparation/replay, transport, and playback remain separate work. Gain is not recalculated per buffer or per bar.

## Original arithmetic and bounds

The original renderer's measurement is a strong NumPy Float64 scalar. Its dB subtraction, division by 20, and power calculation therefore retain Double precision. Multiplication promotes each Float32 sample to Double, applies the Double factor, and rounds once on the final Float32 store. Rounding the factor to Float first changes accepted samples: with the original whole-body factor, input `0.1f` must produce Float bits `0x3e9e9172`.

Creation rejects missing/unmeasurable loudness, nonfinite measurements, values below −70 LUFS, and factors that are nonfinite or underflow to zero. It does not invent a silence gain or clamp an invalid measurement. Measured loudness at least −70 bounds the largest factor by `10^(49.5/20) < 299`. Finite input magnitudes at most 1,000,000 therefore produce finite output below 300,000,000, well inside the next peak protector's declared domain. This stage does not clip samples to ±1; peak protection follows it.

A prepared gain owns one 16-byte native allocation. Its factor never changes; processing allocates or frees nothing and needs no stream position, reset, latency, or drain. The caller supplies disjoint, preallocated stereo input/output buffers. Complete-call validation precedes writes; invalid input clears the entire output. Rejected overlap may clear aliased input, so it must not be used for in-place processing. Zero-frame calls accept null buffers on a valid gain. Setup and processing force round-to-nearest with denormal flushing and restore the caller's floating-point controls and accrued status. Creation/destruction belong off the callback, with ownership retained throughout rendering.

## Independent evidence

The [gain oracle](../tests/fixtures/gain-v9/README.md) executes the unchanged original normalization statement and freezes expected results before native comparison. Ten cases cover the gate floor, unity/attenuation/boost, quiet and relative-gated body results, signed zero, low amplitudes, over-unity samples, precision-sensitive inputs, the original musical body excerpt, and sampled intro/body/outro/tail frames. Exact-vector output bits must match. The musical excerpt uses maximum/RMS limits of 6e−8/1e−8; dB error is limited to 1e−12 and relative multiplier error to 2e−15. Existing audio goldens and tolerances remain unchanged.

The one-second musical excerpt receives the gain measured over the complete 2,756,923-frame original body; it is not independently normalized. The complete original body remeasures to −20.50000000852147 LUFS after fixed gain. A separate native integration test measures and normalizes the same complete test body, then verifies the target before peak protection. It also passes outside-body transients through the prepared gain and linked song protector, accounting for the protector's existing 160-frame delay and drain.

All ten local native cases match all 64,164 original Float values bit-for-bit, with zero dB or multiplier error. Both one-second gain listening WAVs also match exactly. Their measured −16.9493271315 LUFS reflects that excerpt's position within the complete song, not a separate normalization target. Repeat freezing reproduces all 13 fixture files exactly, and 26 negative controls reject wrong factor precision, clipping, signed-zero loss, damaged PCM, changed recipes/provenance, and malformed scalar metadata.

An additional complete-song diagnostic runs the production meter and fixed gain on identical current native pre-gain PCM. All 3,711,911 stereo frames match the original gain statements bit-for-bit; the measured body is −30.3189178815849 LUFS, the fixed gain is +9.818917881584898 dB, and the normalized body remeasures to −20.499999999567162 LUFS. This isolates the new gain stage from the separately recorded original-versus-native event-endpoint discrepancy.

All eight native suites pass optimized and under AddressSanitizer/UndefinedBehaviorSanitizer. Song gain also passes x86_64/Rosetta, including exact Float-bit staging, immutable partition behavior, bounds, invalid final samples, aliases/adjacent buffers, all rounding/flush/status combinations, and no processing allocations or frees. All 39 audio tests in 14 suites pass in Debug and Release. All 151 prior PCM candidates and 17 prior loudness result files remain byte-identical. The iOS simulator passes seven integration tests and its UI smoke test; the unsigned Release device build, formatting/lint, resource checks, and all 13 coverage-guard tests pass. This gain primitive does not resolve the existing [full-song endpoint discrepancy](validation-sample-storage.md), establish physical-device performance, or supply a production replay coordinator.


## Processing cost

On Apple M4 Max / macOS 26.6 with clang 21, C++17 `-O2`, and contraction disabled, three independent profile executions each made three passes over the complete accepted native body. Across 96,930 calls using 256-frame blocks (plus each body's final 59 frames), maximum observed p99/p99.9/worst were 0.333/0.375/7.333 µs. Each execution warmed 2,048 calls first. One 16-byte setup allocation was recorded; every measured process call allocated/freed nothing and restored floating-point control/status.

The timed interval includes the native process call and two steady-clock reads. It excludes input loading, body metering, gain setup, offset calculations, audits, sorting, and reporting. These are finite host observations with clock overhead and scheduling noise, not a whole-engine or physical-iPhone deadline guarantee.
