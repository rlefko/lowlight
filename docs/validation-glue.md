# Linked harmonic compression

The separate `HarmonicGlue` stage continues milestone 4 after the rhythm buses. It applies the accepted guitar/piano focus gains and linked compression from the unchanged v9 renderer. Its output is compressed harmony before room and `.92` dry scaling, plus delayed bass, drums, and duck control. The [stereo room](validation-room.md) consumes this output. Rack fades, air, mastering, transport, and playback remain later work.

## Signal path and streaming contract

Guitar focus uses guitar gain `1` and piano gain `.94`; piano focus uses `.85` and `1.08`. Each Float32 multiplication precedes the Float32 sum. The shared stereo power detector averages channel squares, then uses the reference's centered 800-frame RMS window at 32 kHz. Threshold is `.024`, knee is 6 dB, ratio is 2.3:1, and reduction is capped at 5 dB. Gain smoothing in dB uses a 12 ms attack and 220 ms release.

The even window covers source indices `i-400...i+399`, requiring **399 frames (12.46875 ms)** of lookahead. Reflection repeats endpoints and also handles streams shorter than the window. An 800-value power ring uses a Double rolling sum, with the same subtraction-before-addition order as the frozen detector. Detector/gain conversion stages retain Float32 rounding; smoother state and coefficients use Double. No callback boundary resets these states.

`ll_glue_create` declares the complete finite input length and focus off the callback. `process` consumes and writes equal frame counts; its first 399 physical outputs are neutral silence with duck equal to one. After all declared input arrives, `drain` emits exactly 399 additional frames for a nonempty stream, including reflected endpoint processing; an empty stream emits none. Thus nonempty output has exactly `N+399` physical frames and `N` aligned source frames. All five pass-through fields share the harmonic latency. Unused drain capacity is cleared. Reset keeps configuration but clears history.

The processor owns 14,464 bytes of fixed storage, independent of song length. Process/drain perform no allocation, freeing, locks, I/O, decoding, or planning. Whole-call preflight rejects nonfinite fields, invalid duck values, overflowing focus/power arithmetic, invalid counts, and overlapping buffers without advancing DSP state. Error outputs are cleared. Floating-point control/status registers are restored on return. Callers must serialize access, supply valid buffer storage, and account for the latency; future rack fades must precede the focus/compression stage.

## Independent evidence

The [glue fixtures](../tests/fixtures/glue-v9/README.md) freeze eleven tiny/window-boundary cases, two dynamics cases, and the same accepted score prefix under both focus settings. Synthetic input and small expected waveforms are developer fixtures only. The oracle invokes unchanged `render_room.glue`; the realistic capture observes `session_render.render_song` before room, preserving its full original 3,711,911-frame allocation and fades. Native prefix tests declare that same length, consume only the observed prefix plus lookahead, and do not pretend it is an end of stream.

Predeclared maximum/RMS limits are `2e-6` / `2e-7` for synthetic cases and `1e-5` / `1e-6` for musical cases. Local full comparison passes all **935,720 seven-field frames**. All thirteen synthetic cases are bit-identical. Guitar-focus maximum/RMS error is `6.18491e-6` / `1.18511e-7`; piano-focus error is `5.25638e-6` / `1.00915e-7`. These differences include the earlier voice endpoint rounding. Duck values and synthetic rhythm pass-through are exact; late musical silence also matches. Re-freezing is byte-identical, and eighteen negative controls reject corruption, wrong focus/latency, zero-padded endpoints, and pass-through errors without relaxing limits.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-glue.py --integrity
.tools/reference/bin/python tools/reference/verify-glue.py \
  --compare .build/tonal-native/glue --evidence .build/tonal-evidence/glue
```

The native audits cover empty/tiny streams, both reflected boundaries, independent frozen probes, a closed-form capped-gain case, all-path delay, arbitrary process/drain partitions, reset, rejected-call rollback, buffer aliases, C++ allocation/free calls, and floating-point state restoration. They run optimized and with AddressSanitizer/UndefinedBehaviorSanitizer. Swift tests exercise the production bridge and export full candidates for Linux CI comparison. The iOS integration uses real bundled notes through mixer, buses, compression, and drain.

All 17 audio tests pass in Debug and Release. The pinned iOS 26.5 simulator passes five integration tests and the launch/About/relaunch UI test. The optimized and sanitizer kernel suites pass for both the existing mixer and the new glue stage.

The seven-day CI `tonal-preparation-comparison` artifact retains paired, aligned WAVs and hashes under `glue`. Musical clips contain only the unmastered harmonic bus before room, at unchanged playback level. Guitar-focus reference/native loudness is approximately -33.09145 LUFS and piano focus -33.95938 LUFS; each pair differs by less than 0.000004 LU. Compare chord attacks and release tails for any extra pumping or stereo change. These are diagnostic excerpts, not the completed mix or the song loudness target. Physical-device performance, full-mix listening, and release validation remain pending.

## Host callback probe

An exploratory Apple M4 Max probe used Apple clang 21, C++17 `-O2 -ffp-contract=off`, preallocated buffers, and alternating loud/quiet harmonic input with distinct rhythm/control fields. Each focus measured 30,000 callbacks of 256 frames after 3,000 warmups. Drain measurements used 15,000 full and 15,000 partial callbacks after 1,000 stream warmups. Setup, source filling, and reset were outside timing; root builds and comparisons had completed before measurement.

| Standalone glue callback | p99 | p99.9 | Worst |
| --- | ---: | ---: | ---: |
| Guitar focus, 256 input frames | 6.958 µs | 11.042 µs | 19.084 µs |
| Piano focus, 256 input frames | 5.041 µs | 11.792 µs | 21.208 µs |
| Drain, 256 output frames | 2.708 µs | 6.000 µs | 17.041 µs |
| Final drain, 143 frames into capacity 256 | 1.667 µs | 2.084 µs | 10.459 µs |

Setup made one 14,464-byte allocation, and measured callbacks made no C++ allocation/free calls. Peak harness RSS was 8,568,832 bytes including its runtime and buffers. This measures only the new stage, without voices or room, on an uncontrolled host using ordinary wall-clock timing. It establishes no iPhone deadline, whole-app memory, or energy result.
