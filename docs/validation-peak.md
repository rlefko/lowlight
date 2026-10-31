# Linked peak protection

`PeakProtector` continues milestone 4 with the accepted stereo-linked peak reduction used by the song and final session stages. Song mode targets -5 dBFS; session mode targets -2.2 dBFS after the sum of song racks and effect tails. This processor is independently usable with stereo input. Production mix assembly, synthetic air, whole-song gain analysis, transitions, and playback remain later work.

## Signal path and streaming contract

At 32 kHz, the detector takes the larger absolute channel value and the maximum over source frames `i...i+160`. That 161-frame forward window requires **160 frames (5 ms)** of lookahead. The target is the nonpositive dB difference between the configured ceiling and the future peak, with a `1e-12` detector floor. Gain smoothing uses a .7 ms attack and 100 ms release in Double; target, emitted gain state, power conversion, and stereo multiplication retain the original Float32 boundaries. Both channels receive the same gain. The gain history remains continuous across every process/drain call.

This preserves the accepted smoother, not a brickwall or true-peak limiter. The state begins at zero dB and advances only for real output frames. A hot first sample can exceed the target even though the output is delayed. The accepted session's startup fades provide headroom; separate output/encoded true-peak measurements remain required. No new clamp or startup pre-smoothing is introduced.

Creation chooses the mode off the callback. Process consumes and writes equal stereo frame counts; its first 160 physical outputs are silence. It does not require the stream length in advance. The first valid drain call ends input, including a zero-capacity call. A nonempty stream drains exactly 160 additional physical frames; empty streams drain none. Output therefore has `N+160` physical frames and `N` aligned source frames for a nonempty stream, even when `N<160`. Unused drain capacity is cleared. Later process calls fail until reset, which reopens input and clears all pending samples and gain history.

At end of stream, the future peak replicates the final peak as in the reference's nearest endpoint rule. Because peaks are nonnegative and the final sample already belongs to every remaining detector window, zero peak padding would give the same maxima; tests do not claim to distinguish these equivalent forms. Audio samples themselves are drained exactly once.

A fixed audio ring and monotonic maximum deque each hold at most 161 frames. Ring-slot indices avoid a duration-dependent counter. Whole-call preflight rejects nonfinite samples, magnitudes above `1e20`, overlapping input/output, invalid storage, and processing after end of input without advancing signal state. Failure clears provided output. The generous input bound prevents the exact Float32 ceiling/peak ratio from flushing to zero before the logarithm. Rendering/draining allocate or free nothing, acquire no locks, and perform no I/O, decoding, or planning. Floating-point control/status registers are restored. Callers provide valid buffer storage and serialize access.

## Independent evidence

The [peak fixtures](../tests/fixtures/peak-v9/README.md) cover tiny streams around the lookahead boundary, stereo linking, threshold/attack/release behavior, rising/falling peaks, and the original two-second file-processing boundary. The oracle invokes unchanged `master_stream.protect` with either accepted ceiling and observes its output before PCM24 file quantization and the final file-level assertion. That capture allows adversarial startup behavior to be tested without changing the frozen algorithm.

An authentic four-second prefix preserves all 621 accepted song events, the original full 3,711,911-frame allocation, synthetic air, fades, and whole-body gain analysis before capturing input to song protection. A second, explicitly driven session diagnostic applies an exact Float32 gain of four to the same frozen input. Each native comparison consumes the prefix plus 160 future frames and does not invent an endpoint at the crop. These fixtures isolate the protector; they do not claim the earlier native stages already implement air, rack fades, or loudness normalization.

Predeclared maximum/RMS limits are `2e-6` / `2e-7` for every case. Expected outputs come only from the original functions. The original reference sources and earlier fixture sets remain frozen.

Local comparison is bit-identical across all **579,019 stereo frames** (1,158,038 values). The original song-renderer cross-check is also exact. Re-freezing reproduces every fixture byte, and 23 negative controls reject wrong mode, independent channel gains, missing lookahead, a reset at the two-second boundary, hard clipping, alignment errors, and damaged inputs/fixtures.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-peak.py --integrity
.tools/reference/bin/python tools/reference/verify-peak.py \
  --compare .build/tonal-native/peak --evidence .build/tonal-evidence/peak
```

Native audits cover delay, tiny/empty streams, maximum-window ordering/expiration, reset, arbitrary process/drain partitions, invalid-last-sample rollback, aliases, magnitude bounds, floating-point state, and C++ allocation/free calls. Swift tests exercise the bridge and export full candidates for Linux comparison. iOS integration drives real bundled voices through buses, glue, room, a diagnostic stereo sum, and song protection, accounting for all 559 frames of combined lookahead.

The seven-day CI `tonal-preparation-comparison` artifact retains aligned reference/native WAVs, hashes, and loudness under `peak`. The original song prefix and driven session diagnostic have distinct labels. Compare transient edges, stereo stability, and gain recovery without changing playback level between each pair. These are unquantized protector outputs, not a completed native playback or mastering pipeline.

All 21 audio tests pass in Debug and Release. All four kernel suites pass optimized and with AddressSanitizer/UndefinedBehaviorSanitizer; the peak suite also passes under x86_64/Rosetta. The pinned iOS 26.5 simulator passes five integration tests and the launch/About/relaunch UI test.

The original four-second song prefix measures -20.58776 LUFS and -8.86930 dBTP. The driven session pair measures -10.26929 LUFS and -2.19201 dBTP, versus -8.54656 LUFS and +3.17190 dBTP before protection. The slight excess over the nominal -2.2 dB target illustrates the accepted smoother rather than a true-peak guarantee. Reference/native WAV pairs are byte-identical locally; all fourteen candidate hashes and five WAV hashes, dimensions, finite samples, and PCM correspondence were checked.

## Host callback probe

An exploratory Apple M4 Max probe used Apple clang 21, C++17 `-O2 -ffp-contract=off`, and preallocated buffers. Each mode/scenario measured 30,000 callbacks after 3,000 warmups. Mixed input alternates quiet and driven stereo signals; deque stress repeatedly fills the maximum window with decreasing peaks before introducing a new high peak. Drain trials consume 256 real frames, then emit 160 pending frames into capacity 256. Setup, input generation, reset, and feeding before drain timing were outside the measured intervals. Other local builds/comparisons had completed.

| Mode/scenario | p99 | p99.9 | Worst |
| --- | ---: | ---: | ---: |
| Song, 256 mixed frames | 4.084 µs | 8.375 µs | 18.500 µs |
| Session, 256 mixed frames | 3.000 µs | 6.750 µs | 15.208 µs |
| Song, 256 deque-stress frames | 2.875 µs | 9.042 µs | 17.042 µs |
| Session, 256 deque-stress frames | 2.750 µs | 3.084 µs | 14.833 µs |
| Song, 160-frame drain | 1.541 µs | 6.000 µs | 15.917 µs |
| Session, 160-frame drain | 1.542 µs | 1.709 µs | 18.666 µs |

Creation makes one **2,632-byte** fixed allocation (2.57 KiB), excluding caller buffers and allocator bookkeeping. Measured process/drain calls made no C++ allocation/free calls. Warm setup p99 was .167 µs for song mode and .084 µs for session mode, over 1,000 samples after 50 warmups. First observed setup was 2.625/.333 µs; later mode measurements inherit warmed allocator state. Peak harness RSS was 8,585,216 bytes including runtime and buffers. These short, uncontrolled host wall-clock measurements are affected by clock resolution and scheduling; they establish no device deadline, combined-engine performance, whole-app memory, or energy result.
