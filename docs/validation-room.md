# Stereo room

`StereoRoom` continues milestone 4 after harmonic focus and compression. It reproduces the accepted stereo room and dry/wet balance from unchanged `render_room.py` and `session_render.py`. Bass, drums, and duck control pass through without added delay. Rack fades, air, mastering, transport, and playback remain later work.

## Signal path and streaming contract

At 32 kHz, each channel receives mid plus or minus `.55` times side. Eight parallel comb filters use the accepted 29.7–59.3 ms delays, a 1.39 ms right-channel offset, `.50` damping, and `.105` output gain. Three serial allpasses use 5, 1.7, and .73 ms delays, a .19 ms right offset, and `.58` feedback. The diffuse return has 12 ms of predelay; three separate early reflections use 19.3, 37.1, and 61.9 ms, a 3.13 ms right offset, and gains `.10`, `.065`, and `.045`. Rounded sample counts match the frozen renderer.

Second-order Butterworth filters apply 145 Hz highpass followed by `1700 - 700 * warmth` Hz lowpass. Decay is `1.65 + .85 * space` seconds; final harmony is `.92 * dry + (.60 + .8 * space) * wet`. Float32 buffers and stage boundaries retain the reference's rounding, while comb damping state, allpass arithmetic, and filter coefficients/state use Double. Contraction and fast-math optimizations remain disabled.

Creation validates finite space/warmth in `0...1` and prepares fixed coefficients off the callback. The controls remain fixed for this processor; future live controls need smoothing. Process accepts equal-length, disjoint seven-field buffers and emits the same number of frames. The room adds no alignment latency or lookahead; its natural delays are part of the effect. Existing glue latency remains 399 frames for the complete chain. Continue supplying zero tonal input while a tail should ring; there is no invented finite drain interval or silence cutoff. Reset discards all room/filter history while retaining configuration. Future rack fades must precede glue and room.

Whole-call preflight rejects nonfinite fields, duck outside `0...1`, tonal magnitudes above 1024, null storage for nonempty calls, and any input/output overlap. It clears failed output without advancing room state. The tonal bound is far above the accepted voice mix. Maximum comb feedback is below `.922`; conservative comb/allpass bounds keep the prefilter signal below `2.4e6`. Each biquad has pole radius below `.99` and numerator absolute sum below four, giving a loose impulse-response absolute-sum bound of 40,000. Even applying both bounds keeps internal/output magnitudes below `1e17`, far below Float overflow, with ample rounding margin. Bass/drums are finite pass-through values. Rendering uses fixed storage, bounded subblocks, no allocation/free calls, locks, I/O, decoding, or planning, and restores floating-point control/status registers. Callers must serialize access and supply valid storage.

## Independent evidence

The [room fixtures](../tests/fixtures/room-v9/README.md) freeze short delay boundaries, all four space/warmth corners with stereo impulses and long tails, and the accepted score under both focus settings. Sparse input records and short lossless goldens stay in developer resources. The oracle invokes the original room function; musical capture runs the original full 3,711,911-frame song allocation, then observes its 416,000-frame prefix after the accepted dry/wet sum. Native tests preserve the same finite glue length and process its physical prefix through the room before removing the 399-frame alignment offset.

Predeclared maximum/RMS limits are `2e-6` / `2e-7` for synthetic cases and `1e-5` / `1e-6` for musical cases, including separate checks of tonal channels. The four synthetic tails from frame 64,000 use tighter `1e-8` / `1e-9` limits to detect quiet tail truncation. Bass/drums/duck preserve exact native input values; synthetic reference pass-through and musical duck must also match exactly. No expected output is generated from native DSP.

Local comparison passes all **1,857,338 seven-field frames** (13,001,366 values). Six of seven synthetic cases are bit-identical; the remaining case has maximum error `3.15544e-30`. The strict tail maximum/RMS errors are `3.15544e-30` / `5.09208e-33`. Guitar-focus maximum/full RMS/tonal RMS errors are `5.93159e-6` / `1.29954e-7` / `2.43121e-7`; piano-focus errors are `5.04125e-6` / `1.10669e-7` / `2.07041e-7`. Re-freezing reproduces every fixture byte. Twenty-one negative controls reject changed controls, wrong wet signal, latency, tail truncation, pass-through corruption, malformed candidates, and damaged fixtures.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-room.py --integrity
.tools/reference/bin/python tools/reference/verify-room.py \
  --compare .build/tonal-native/room --evidence .build/tonal-evidence/room
```

Native tests cover arbitrary chunk boundaries, reset, early reflections, stereo spread, decay after source silence, invalid-call rollback, buffer aliasing, finite bounded input, floating-point state restoration, and C++ allocation/free calls under optimized and sanitizer builds. Swift tests exercise the production bridge and export full candidates for Linux comparison. iOS integration uses the bundled instruments through voices, rhythm buses, glue, and room, including a residual room tail after voices retire.

All 19 audio tests pass in Debug and Release. All three kernel suites pass optimized and with AddressSanitizer/UndefinedBehaviorSanitizer; the room suite also passes under x86_64/Rosetta. The pinned iOS 26.5 simulator passes five integration tests and the launch/About/relaunch UI test.

The seven-day CI `tonal-preparation-comparison` artifact retains aligned reference/native WAVs and hashes under `room`. Musical clips are the unmastered harmonic bus after room at unchanged playback level, before ducking, rhythm mix, air, and mastering. Compare stereo width, early reflections, chord attacks, and fading room tails. These diagnostic clips do not establish full-mix loudness, physical-device performance, or release readiness.

The musical reference/native pairs measure approximately -32.82844 LUFS for guitar focus and -33.69702 LUFS for piano focus, differing by less than 0.000005 LU. Native true peaks are -20.65425 and -21.45883 dBTP. These levels describe the isolated harmonic excerpts, not a mastered-song target. All four WAV hashes, dimensions, finite values, and native PCM correspondence to the exported tonal fields were verified.

## Host callback probe

An exploratory Apple M4 Max probe used Apple clang 21, C++17 `-O2 -ffp-contract=off`, preallocated buffers, and all four space/warmth corners. Each corner measured 30,000 sustained and 30,000 active-tail callbacks of 256 frames after 3,000 warmups. Tail trials repeated two seconds of excitation followed by eight seconds of zero input; every final tail block remained nonzero. Setup, input generation, reset, and excitation between tail trials were outside callback timing. Other local builds/comparisons had finished before measurement.

The table reports the largest per-corner percentile and worst observation in each scenario, rather than pooled percentiles.

| Standalone room callback | p99 | p99.9 | Worst |
| --- | ---: | ---: | ---: |
| Sustained input, 256 frames | 8.542 µs | 9.292 µs | 56.833 µs |
| Active tail, 256 frames | 8.416 µs | 10.750 µs | 33.000 µs |

Creation makes one **112,272-byte** fixed allocation (109.64 KiB); measured callbacks made no C++ allocation/free calls. Warm setup p99 ranged from .583 to 1.959 µs across corners, with 1,000 samples after 50 warmups each. First observed setup ranged from 1.291 to 15.541 µs; this is not a controlled cold-start measurement. Peak harness RSS was 8,568,832 bytes, including runtime and buffers. These ordinary wall-clock measurements isolate the room on an uncontrolled host. They establish no iPhone deadline, full-chain performance, whole-app memory, or energy result.
