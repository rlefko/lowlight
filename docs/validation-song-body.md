# Song body selection validation

`SongRenderLayout` declares a finite song's logical frame origin, total length, and local half-open body range. `SongBodyLoudness` consumes consecutive post-HP32 stereo frames during preparation and forwards only their intersection with that body to the existing meter. K-weighting starts fresh at the first body frame. The resulting measurement prepares the existing constant gain for the entire song before song peak protection.

## Two explicit timing contracts

Native schedules use the shared rounded absolute clock. The layout subtracts the same rounded song origin from the body start at beat 16, body end at the outgoing bridge start, and form end at the outgoing bridge end. It then adds exactly 160,000 logical tail frames. This preserves shared transition endpoints without accumulating rounded beat durations.

Original reference renders instead use `round((duration_seconds + 5) * 32000)` for total length and round each `local_seconds` body endpoint directly. Differences of rounded absolute times are not interchangeable with these expressions: later original songs differ by one frame. The integer initializer accepts independently imported reference boundaries without reinterpreting them. It does not convert reference event onsets or solve nonzero-origin voice placement.

The complete accepted first reference song has 3,711,911 frames and body `[393846, 3150769)`. Layout validation bounds the total by the existing 5,792,000-frame song limit and the absolute end by the shared clock's maximum. The body must fit inside that total and contain at least the meter's 12,800-frame minimum.

## Streaming lifecycle

The adapter owns one existing fixed-storage meter and scalar position/completion state. It stores no song PCM and performs no buffer growth while processing. Callers remove the glue stage's physical startup delay and retain its drained logical frames before supplying the finite song stream; peak protection follows analysis and gain. Neither stage's latency belongs in the body coordinates.

Each call validates its entire input, including intro and tail samples, before advancing anything. Odd sample counts, excess frames, nonfinite values, and magnitudes above 1,000,000 are rejected without changing progress. A successful finish requires all declared song frames, so a valid body cannot conceal an invalid or missing tail. An incomplete finish permits continued input. Repeated successful finishes return the same measurement; processing then requires reset, even for an empty buffer. Reset clears the meter and rewinds the song position. An unmeasurable body remains unmeasurable rather than receiving an invented gain.

## Validation

The independent [body timing and measurement fixture](../tests/fixtures/song-body-v9/README.md) freezes original local frame boundaries and cropped-body loudness before native comparison. Integer boundaries have zero tolerance; loudness retains the existing meter's 1e-5 LU tolerance. Tests exercise body crossings, varied chunks, zero filter history, invalid input outside the body, complete-call rollback, completion, reset, and caller floating-point state. The 73 reference/expression records validate explicitly supplied integer layouts; five independently calculated native cases exercise schedule conversion. They do not represent 72 native renders.

All four selected-body measurements match the original exactly, with zero LUFS error and exact status/block/gate counts. All 161 prior PCM files and 27 prior loudness/gain result files remain byte-identical to PR #22. All 45 audio tests in 15 suites pass in Debug and Release; the final focused Debug rerun includes both additional boundary assertions. Seven iOS integration tests, the UI smoke test, the unsigned Release build, strict formatting/lint, resource checks, and all 13 coverage-guard tests also pass.

Repeat freezing reproduces the manifest byte-for-byte. All 21 negative controls reject altered boundaries, types, crop recipes, provenance, hashes, gate membership, scalar results, and file inventories.

A separate diagnostic streams the retained, validated PR #22 first-song post-HP32 PCM through the new public selector using three chunk patterns. All 3,711,911 frames produce exactly the prior manually cropped result: −30.318920002223475 LUFS, 859 total/absolute blocks, 849 gated blocks, and +9.818920002223475 dB gain (multiplier 3.0970341920906814). The input SHA-256 remains `9c1c75e52fbf14025fef1bd12dceca483d6e923ef21cb5c04a0685f9a1ebf20b`. This checks the new selection path on retained PCM; it is not a fresh rack render or a performance measurement.

This supplies body selection for a bounded analysis pass. Production rack construction, deterministic replay, nonzero-origin reference placement, two-rack transport, playback, and physical-device performance remain separate work.
