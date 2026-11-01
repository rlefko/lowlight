# Song mix validation

`SongMix` assembles the accepted per-song stereo stream after room processing and before fixed loudness gain or peak protection. At 32 kHz, it adds tonal and bass buses, applies their shared kick ducking, adds drums, adds the prepared quiet air, and applies the original second-order 32 Hz high-pass filter. The output is ready for a later whole-song loudness analysis pass. This stage does not implement that pass, playback, or two-song transport.

## Ordering and alignment

The original NumPy expression `(tonal + bass) * duck + drums` rounds to Float32 after each operation. Drums and air bypass ducking. `QuietAir` then performs its Double modulation and addition before a Float32 store. HP32 uses continuous Double coefficients and direct-form-II state, with a Float32 output boundary. Combining the expression in Double, reassociating additions, or moving ducking after the drum/air additions changes the accepted signal.

Creation receives the full finite song length, take seed, absolute frame origin, texture, and rack fades. It prepares the existing air stage's full-channel normalization off-thread, even when rendering only a prefix. Input must consist of logical song frames: discard harmonic glue's 399 neutral startup frames, then retain its delayed output and drain to obtain exactly N frames. Feeding those startup frames to the mix would shift the local air clock. The room and mix add no alignment latency.

HP32 continues through zero input while frames remain in N, including room and filter tails. An air fade endpoint is not a command to clear the high-pass state. At N, processing stops without an extra drain, matching the finite original array including its allocated tail. Reset rewinds air and clears HP32 history without a new normalization scan. Controls remain fixed until recreation.

## Bounded processing and failure behavior

The processor owns an 80-byte mix/filter object and the existing 368-byte air object, allocated only during preparation. It retains no complete-song PCM, temporary growing container, or additional per-call scratch. Processing and reset perform no allocations, frees, locks, or I/O.

Each call first validates the complete input, remaining count, and disjoint buffer ranges. Every audio field must be finite with magnitude at most `1e20f`; duck must be in `[0,1]`, including validation of raw negative subnormals. This bound accommodates the room's documented conservative output bound and prevents overflow in Float32 summation. HP32's poles have radius below .996 and its numerator absolute sum is below 4, yielding a conservative impulse-response absolute sum below 250,000. The resulting output remains far below Float32 overflow.

After validation, stateless summation writes into the caller's stereo buffer. One transactional air call processes the entire buffer before HP32 state advances. If air fails, its own rollback preserves the stream and clears output; there is no partially advanced high-pass state. The subsequent fixed filter is finite within the declared domain. Invalid calls clear the provided output and preserve signal state. Setup and processing establish round-to-nearest with denormal flushing, restoring the caller's controls and accrued floating-point status afterward.

## Reference and tests

The [mix oracle](../tests/fixtures/mix-v9/README.md) observes the unchanged accepted `render_song` immediately before loudness normalization. Synthetic input records isolate Float32 rounding, duck placement, channel independence, DC removal, impulse response, and residual tails. Guitar- and piano-focused score prefixes exercise the native voice → glue → room → mix chain against the original renderer with its complete song length retained for air normalization.

Tolerances are declared before native comparison: ordinary synthetic maximum/RMS error `2e-7`/`2e-8`, air-only `2e-9`/`2e-10`, and score prefixes `1e-5`/`1e-6`. Synthetic residual-tail windows use `1e-9`/`1e-10`. Exact cancellation cases must be zero, independently of those budgets. These comparisons cover the declared exported frames; complete-song mix parity and loudness remain later gates.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-mix.py --integrity
.tools/reference/bin/python tools/reference/verify-mix.py \
  --compare .build/tonal-native/mix --evidence .build/tonal-evidence/mix
```

CI retains reference/native mix clips, hashes, loudness, and peak measurements under `mix` in `tonal-preparation-comparison`. Review the instrument balance, kick ducking, low-frequency cleanup, and room decay at unchanged volume. These clips precede fixed loudness gain and peak protection. Physical-device callback, startup, memory, and energy validation remains pending.

## Local results

All ten native candidates pass across 924,935 stereo frames (1,849,870 Float32 values). Both tiny cases and the cancellation case match the original output bit for bit. The largest synthetic error is `1.45519e-11`, the air-only error is `2.27374e-13`, and the largest strict tail-window error is `4.54747e-13`.

| Score prefix | Maximum error | RMS error | Native LUFS | Native 4× peak |
| --- | ---: | ---: | ---: | ---: |
| Guitar focus | `6.09271e-6` | `2.42058e-7` | -32.01760 | -18.68820 dBTP |
| Piano focus | `5.17815e-6` | `2.06131e-7` | -32.57084 | -19.10451 dBTP |

These 13-second unmastered excerpts preserve the original score/settings and complete-length air preparation. Four Float32 WAVs have verified hashes, dimensions, finite values, and PCM correspondence. The measurements describe this boundary before whole-song gain, not the final -20.5 LUFS target.

All 141 earlier native candidates remain byte-identical. Repeat freezing reproduces all six fixture files exactly; 30 negative controls reject wrong staging, duck routing, HP cutoff/bypass, missing air, lost or perturbed tails, endpoint shifts, malformed data, and changed configuration. All 29 audio tests pass in Debug and Release. All six native suites pass optimized and with AddressSanitizer/UndefinedBehaviorSanitizer; SongMix also passes x86_64/Rosetta, including the exact original probes. The iOS 26.5 simulator passes six integration tests and its UI smoke test. Formatting/lint, repository/resource checks, and all 13 CodeQL coverage-guard tests pass.

The local unsigned Release arm64 bundle contains 970,576 binary bytes and 9,002,179 resource bytes, totaling 9,972,755 bytes. Hosted CI separately compares its merge base with the same configuration. This bundle measurement is not an App Store download estimate.

## Host timing probe

A quiet Apple M4 Max host used Apple clang 21.0.0, C++17, `-O2`, and `-ffp-contract=off`. Five preparation trials at N=3,711,911 had a median of 46.454 ms (45.689–64.476 ms); maximum N=5,792,000 had a median of 72.303 ms (71.656–74.110 ms). Two allocations totaled 448 bytes. Peak process RSS was 8,585,216 bytes including the harness/runtime.

Each 256-frame/32 kHz run retained all 30,000 callback timings after 3,000 warmups. Buffers and timing storage were preallocated; reset was excluded from timing. Callbacks and resets performed no allocations or frees.

| Input / texture | Mean | p99 | p99.9 | Worst |
| --- | ---: | ---: | ---: | ---: |
| Mixed buses / .09 | 7.070 µs | 9.125 µs | 17.666 µs | 28.125 µs |
| Mixed buses / 1 | 7.100 µs | 9.083 µs | 15.500 µs | 27.417 µs |
| Long quiet HP tail / 0 | 7.082 µs | 9.084 µs | 15.542 µs | 27.292 µs |

This is one unpinned host run after builds and reference regeneration finished. It includes mix/air/HP32, excluding upstream voices/glue/room and later gain/protection. It establishes no whole-engine cost, physical-device deadline, or energy result.
