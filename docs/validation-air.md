# Quiet synthetic air validation

`QuietAir` adds the accepted revision 9 texture directly to an existing interleaved stereo Float32 mix at 32 kHz. Preparation receives a take seed, complete input length, absolute frame origin, texture, and the same song fade descriptor used by the voice mixer. The generator and sinusoidal modulation use local song time; only fade evaluation uses the absolute frame origin. Air follows the tonal fade, without the rhythm ownership gate. Final mix assembly, HP32, whole-song loudness analysis, transport, and playback remain separate work.

## Bounded preparation and replay

Preparation accepts seeds below `2^31`, texture in `[0,1]`, and 1–5,792,000 frames: the maximum 44-bar form at 60 BPM plus the reference's five-second allocation tail. The origin plus input length must fit within `2^52` canonical frames. Invalid or nonfinite configuration fails before rendering.

An off-thread pass consumes the complete two-channel sequence to measure normalization. The right channel begins after N left-channel normal outputs, not N raw random words. Each normal permits at most 64 raw 64-bit draws, including rejection/tail retries. Exhausting that limit fails preparation; no replacement seed or fallback noise is used. Replay uses the saved channel starts and prepared gains. One 368-byte allocation holds state; no whole-song PCM or dynamically growing cache is retained. The normalization reduction uses a bounded recursion tree only during preparation.

SeedSequence, PCG64, and the Double normal sampler match the pinned NumPy 2.3.5 sequence. Each normal is cast to Float32, then HP160 and LP800 each have a Float32 output boundary and continuous Double filter state. The complete channel's Float32 squares use NumPy's pairwise sum order. The sum is divided by N in Double, rounded to Float32, and square-rooted as Float32. The normalization gain is rounded to Float32 before multiplication. Sinusoidal modulation and fade multiplication use Double; addition to the existing Float32 mix occurs in Double before one final Float32 store. A separately rounded air buffer would change that contract. Adapted code and constants retain their [upstream notices](third-party-code.md).

Setup and replay enforce the same round-to-nearest and denormal mode, then restore the caller's floating-point controls and accrued status. Processing uses at most 256-frame subblocks, with no allocations, frees, locks, or I/O. Calls preflight every input sample and the remaining frame count. A failed call clears its provided output and leaves stream state unchanged, including the guarded replay failure path. Reset reproduces the prepared sequence. Air adds no delay or drain phase; texture changes require preparation of a new instance. Live parameter smoothing is not implemented here.

## Independent comparison

The [frozen oracle](../tests/fixtures/air-v9/README.md) invokes unchanged `session_render.render_song`, substitutes an empty event list and an exact input carrier, and captures the original addition before HP32. Air is independent of note events. Two authentic song plans retain their complete original lengths, seeds, parameters, and clocks. Ten synthetic lengths cover 1, 7, 8, 127, 128, 129, 8,191, 8,192, 8,193, and 16,385 frames, including fractional overlapping fades, large absolute origins, zero texture, and nonzero carriers.

The native tests consume all 8,401,152 input frames across 12 cases and retain 201,489 stereo frames for independent waveform comparison. Authentic windows cover startup, local 16 seconds, the outgoing tonal endpoint, and the final 64 frames. Reference full-stream hashes identify the original complete render; they do not establish comparison of unretained native samples. Fixed versus varied callback partitions and reset must match exactly.

Limits were declared before native comparison: air-only maximum error `2e-9` and RMS `2e-10`; carrier cases maximum `1e-8` and RMS `1e-9`. In the frozen cases, zero texture and completed fades must leave the carrier exactly unchanged; runtime output intentionally flushes subnormal values. Independent exact random vectors, forced rejection/tail branches, and selected rounding-boundary output probes prevent a different generator or Float32 staging from hiding inside waveform tolerances. Four million separately generated normal samples also match NumPy's Float32 outputs bit for bit across four seeds.

Repeat freezing is byte-identical. All 32 negative controls reject malformed candidates, timing/configuration drift, altered random vectors, missing/swapped/perturbed air, and nonzero post-fade output. Native tests additionally exercise maximum-length preparation, floating-point mode restoration, invalid-last-sample rollback, allocation bounds, reset/chunk invariance, and exact exhaustion of the random-draw limit. The iOS integration test checks local phase with shifted absolute fades; the UI test opens the bundled software notices offline.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-air.py --integrity
.tools/reference/bin/python tools/reference/verify-air.py \
  --compare .build/tonal-native/air --evidence .build/tonal-evidence/air
```

CI retains aligned reference/native WAVs and measurements under `air` in the `tonal-preparation-comparison` artifact. Each authentic clip concatenates its declared windows, with both original-level audio and a clearly labeled common +40 dB diagnostic. Listen at unchanged volume for the noise color, stereo character, modulation, and outgoing fade. These are isolated unmastered air clips. Original-level air can be below the loudness meter's absolute gate; its LUFS is then explicitly recorded as `null`, while peaks and RMS remain measured. The boosted pair supplies measurable gated loudness without implying a finished song level.

## Local results

All 402,978 retained Float32 values match the regenerated reference bit for bit: maximum and RMS error are zero in all 12 cases. All 129 earlier native candidates are byte-identical to the preceding implementation, including the mixer after its fade calculation was shared with air. All 27 audio tests pass in Debug and Release, all five native suites pass optimized and with AddressSanitizer/UndefinedBehaviorSanitizer, and QuietAir passes under x86_64/Rosetta. The pinned iOS 26.5 simulator passes six integration tests and the launch/About/software-notices/relaunch UI test. Formatting/lint, resource/license checks, and all 13 CodeQL coverage-guard tests pass.

The two original-level native air clips have four-times oversampled peaks of -73.53735 and -75.37454 dBTP; both are below the LUFS absolute gate. With the common +40 dB diagnostic gain, they measure -44.35291/-45.56779 LUFS and -33.53735/-35.37455 dBTP. Reference and native PCM are identical, and all eight WAVs have recorded hashes. These 2.502-second concatenated windows establish no full-song loudness claim.

The local unsigned Release arm64 app contains 946,896 binary bytes and 9,002,179 resource bytes, totaling 9,949,075 bytes. Hosted CI separately compares the merge base with the same configuration. This is an unsigned bundle proxy, not an App Store download estimate.

## Host timing probe

A quiet Apple M4 Max host with 16 CPU cores used Apple clang 21.0.0, C++17, `-O2`, and `-ffp-contract=off`. Five setup trials at the accepted 3,711,911-frame length had a median of 45.732 ms (45.446–64.629 ms); the maximum 5,792,000-frame length had a median of 71.314 ms (71.289–71.827 ms). One 368-byte allocation holds air state, with 6,160 bytes of read-only normal tables. Peak process RSS was 8,585,216 bytes including the harness and runtime, not the entire audio engine.

Each callback run retained all 30,000 timings after 3,000 warmups, using 256 frames at 32 kHz. One reset per stream occurred outside timing; callbacks and resets performed no allocations or frees.

| Seed / texture | Mean | p99 | p99.9 | Worst |
| --- | ---: | ---: | ---: | ---: |
| 1,278,560,406 / .09 | 6.051 µs | 7.708 µs | 15.291 µs | 43.750 µs |
| 2,147,483,647 / 1 | 6.032 µs | 7.583 µs | 14.250 µs | 31.750 µs |

These are measurements of the new stage alone in one unpinned host run after builds and reference generation finished. They establish no whole-engine cost or physical-device callback deadline. Physical-iPhone startup, memory, and energy evidence remains pending.
