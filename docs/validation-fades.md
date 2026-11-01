# Song rack fades

Optional `SongRackFades` completes the dry-stem envelopes needed by milestone 4's full-song signal path. Guitar and piano receive the product of linear arrival and departure gains. Bass and all four percussion stems receive the outgoing 75 ms cutoff, with an optional incoming ownership gate. These gains multiply already-summed instrument stems before the rhythm filters, harmonic compression, and room. Filter and room returns continue after the source reaches zero; neither effect's state is cleared at the handoff.

## Clock and rendering contract

`ll_mixer_configure_fades` copies six Double frame endpoints before the first score load and requires configured buses. `SongRackFades(schedule:)` prepares those endpoints from the planner's shared absolute clock. Native plans retain the [existing rounded-endpoint contract](adrs/003-events-and-shared-time.md): adjacent tonal envelopes are complementary, and the incoming rhythm gate opens at the outgoing rack's exact cutoff frame. The transition is linear in elapsed time, not beat number during a tempo ramp. Events and fade endpoints must share one clock.

Independent reference imports can instead supply fractional frame endpoints calculated from the original unrounded local seconds times 32,000. Converting to frame units reassociates Double arithmetic slightly; this path is measured against the original seconds-based renderer, not described as bit-identical arithmetic. The reference's note generator already suppresses incoming rhythm events; the optional explicit gate protects native rack ownership as specified by the planner.

For each frame, the kernel evaluates bounded Double gains and multiplies each Float32 stem in Double before converting once back to Float32. The descriptor adds 64 bytes to each mixer, with no new allocation, gain table, or duration-dependent storage. Finite endpoints must be in `0...2^52`; enabled tonal ramps must span at least one frame, and rhythm arrival cannot follow its departure. Two zero arrival endpoints disable that tonal ramp. Overlapping arrival/departure ramps are valid and multiply. Invalid setup preserves the prior configuration; setup is locked after score load. Reset and score reload retain the fade descriptor while clearing voice/filter history and resetting the shared playhead.

The diagnostic dry stereo view remains unfaded. Both render views still advance the same faded bus/filter state, so switching views preserves history. Kick ducking remains keyed to the score, even when a kick's audio is suppressed by a fade. Voice lifetimes and retirement do not change. There is no new latency, allocation/free call, lock, I/O, or scheduling work in the callback.

## Independent evidence

The [frozen fade fixtures](../tests/fixtures/fades-v9/README.md) execute the unchanged accepted renderer with the same 63-event instrumental prefix and deliberately shortened fractional-second envelope endpoints. One case has only an outgoing fade; the other multiplies overlapping incoming and outgoing ramps. These are diagnostic excerpts, not complete song transitions. The oracle captures all nine bus fields after the reference's actual fade/filter code and compares every native frame. Separate compact probes preserve real full-song endpoint behavior.

Predeclared maximum/RMS limits are `1e-5` / `1e-6`, with `1e-8` / `1e-9` for the quiet drum-filter tail just after cutoff. Duck factors and post-envelope harmonic/bass silence must match exactly. Native tests cover setup rejection and rollback, fractional boundaries, incoming gating, reset/reload, arbitrary buffers, view switching, retained filter tails, allocation/free auditing, and floating-point control restoration. Swift tests exercise the production bridge, schedule mapping, and full candidate exports. The iOS integration chain checks that faded source silence still leaves drum-filter and room output.

At introduction, local full comparison passed **832,000 nine-field frames** (7,488,000 values). Outgoing-only maximum/RMS errors are `5.17862e-6` / `8.37915e-8`; overlapping incoming/outgoing errors are `4.80423e-6` / `7.77537e-8`. The largest differences came from guitar endpoint rounding later corrected for [reference imports](validation-reference-timing.md). Bass maximum error is `7.45058e-9`, drums `2.84217e-14`, and the strict post-handoff drum-tail maximum is `1.16488e-38`. Duck and required silence match exactly. All 127 earlier native candidates are byte-identical to the preceding implementation.

Re-freezing produces byte-identical fixtures, and 27 negative controls reject malformed files, changed timing or tolerances, wrong fade configuration, corrupted ducking, tiny post-end residuals, and truncated/perturbed filter tails. All 25 audio tests pass in Debug and Release. All four native DSP suites pass optimized and with AddressSanitizer/UndefinedBehaviorSanitizer; the expanded voice suite also passes under x86_64/Rosetta. The pinned iOS 26.5 simulator passes five integration tests and the launch/About/relaunch UI test. Formatting/lint, repository/license/resource checks, and all 13 CodeQL coverage-guard tests pass.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-fades.py --integrity
.tools/reference/bin/python tools/reference/verify-fades.py \
  --compare .build/tonal-native/fades --evidence .build/tonal-evidence/fades
```

The CI `tonal-preparation-comparison` artifact retains aligned reference/native diagnostic WAVs, hashes, and measurements under `fades`. Listen at unchanged volume for the harmonic fade shape, the rhythm handoff, and residual drum-filter decay. These isolated buses have no final mix, air, fixed loudness gain, or mastering. Full-song loudness analysis, complete mix assembly, two-rack transport, and playback remain later work; physical-device performance and energy evidence are pending.

All eight 13-second stereo Float32 WAV hashes, dimensions, finite values, native PCM correspondence, and reference probes were checked independently. Native outgoing/incoming harmonic clips measure -33.95272/-36.88405 LUFS and -19.71964/-20.86809 dBTP; the rhythm clips measure -35.58681 LUFS and -22.50339 dBTP. Reference/native loudness differs by less than .000005 LU. These measurements describe isolated unmastered buses, not full-song level targets.

## Host rendering probe

An Apple M4 Max probe used C++17 `-O2 -ffp-contract=off`, 64 continuously active voices, and 256-frame callbacks. Ten retained 131,072-frame trials per mode followed warmup, with before/disabled/enabled order reversed in the second batch. Median wall time for 4.096 seconds of audio was 18.153 ms for the previous mixer, 19.057 ms for the new mixer with fades disabled, and 20.140 ms with fades enabled. Trial ranges were 17.950–18.359, 18.592–19.387, and 19.490–20.532 ms respectively. Prior/disabled checksums matched. The mixer object is 185,744 bytes, up from 185,680, with its existing PCM allocation unchanged. Builds and reference comparisons had finished before this probe; ordinary host activity was not isolated. These observations establish no iPhone callback deadline, whole-chain performance, or energy result.

A separate callback probe retained all 30,720 timings per mode after 1,024 warmups. Sixty 4.096-second bursts alternated enabled/disabled order; reset ran outside timing so each burst retained 64 voices and active fade ramps. Mixers, buffers, and timing storage were prepared once. Nearest-rank percentiles include every observation; differing worst times reflect host/scheduler variation.

| 256-frame callback | p99 | p99.9 | Worst |
| --- | ---: | ---: | ---: |
| Fades disabled | 46.083 µs | 53.542 µs | 120.375 µs |
| Fades enabled | 48.708 µs | 55.625 µs | 106.000 µs |
