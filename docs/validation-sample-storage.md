# Prepared sample storage

The complete accepted 621-event score previously needed 39,363,152 bytes of prepared PCM and failed the 32 MiB mixer limit. Preparation now retains only the guitar, piano, and bass sample frames that some event using that sample can reach. The same score retains 23,363,108 bytes across 63 sample keys. The 32 MiB arena, 64 sample descriptors, 2,048 events, and voice limits remain unchanged. This makes that score preparable; it does not establish that every future score will fit.

## Preparation and sound preservation

The existing validated-score pass finds the longest `releaseEndFrame - startFrame` for each instrument/note/normalized-take key. Registration still follows first occurrence in score order. Each note is fully decoded, transposed, filtered, and normalized before its retained prefix is copied into the C kernel. Full sample dimensions, finiteness, and the ±8 amplitude domain are checked before discarding any suffix. Percussion retains its complete shaped body because drum gates do not limit playback.

For a tonal sample of length S, let M be the longest event lifetime using it. Retaining R = min(S, M) preserves every event's audible length because min(R, L) = min(S, L) for every L ≤ M. That also preserves the attack and release calculations, which depend on the audible length. Bass has an independent oscillator lifetime; any removed recorded-body frame lies after every event using it has ended. Readers use integer sample ages without interpolation or lookahead. Stealing can shorten an event, but cannot extend its sample reads. Zero-velocity events still participate in the calculation.

This is setup work, outside the audio callback. There is no eviction, asynchronous refill, early cutoff at a song fade, changed event timing, or second rendering implementation. The fixed 32 MiB arena allocation remains; `preparedBytes` counts its used PCM storage. The preparer still uses temporary storage for one complete note at a time, so retained PCM savings do not equal a measured resident-memory reduction.

## Validation

The new preparation tests compare the production wrapper against full-sample C registration on identical scores. Existing acoustic fixtures, tolerances, and expected PCM stay frozen. Their historical `prepared_bytes` values describe untrimmed storage and now serve as upper bounds; dedicated preparation checks cover the new storage behavior. Percussion retains its exact original byte counts.

The complete accepted score exercises admission within the unchanged limits, bounded rendering through the last release, and zero stolen or dropped events. iOS integration also checks that a short mixed score uses less than 1 MiB while preserving its sustained bass, room tails, and reset behavior.

All 34 audio tests in 12 suites passed locally in Debug (206.718 seconds) and Release (0.785 seconds). All 151 exported native candidates are byte-identical to the accepted prior outputs. The complete production voice → glue → room → mix stream also matches the earlier native audition across all 3,711,911 stereo frames, with SHA-256 `db4a41023b676e75d14337d752726be8cb65f43c09104b9a263842f5ea9c38b7`. This is native-to-native identity, separate from the original-reference limit discussed below.

The six iOS integration tests and one UI smoke test passed, as did strict formatting/lint, resource/document checks, and 13 CodeQL coverage-guard tests. The local unsigned Release iPhone bundle measures 9,974,491 bytes; the hosted size job compares the same configuration against the merge base. This is not an App Store download estimate.

## Preparation and render profile

A quiet Apple M4 Max / Swift 6.3.3 Release probe retained five trials per case. Manifest/event import was outside the timed preparation call; complete decoding, filtering, normalization, validation, registration, and event loading were included. No explicit warmup was performed.

| Score | Prior used PCM | Current used PCM | Prior setup median | Current setup median |
| --- | ---: | ---: | ---: | ---: |
| Matched 63-event prefix | 17,546,740 B | 9,911,320 B | 119.904 ms | 116.635 ms |
| Complete 621-event score | Capacity failure | 23,363,108 B | Not comparable | 265.770 ms |

All five complete-score preparations succeeded, ranging from 264.426 to 270.844 ms. The prior implementation failed the same score in all five trials. This short host measurement establishes no startup or speed guarantee for an iPhone.

Rendering the complete score through the mixer buses used 14,500 callbacks of at most 256 frames, without retaining a complete stem graph. Mean/p99/p99.9/worst call times were 15.596/20.625/24.417/33.958 µs. Output was finite with zero steals or drops. These timings exclude output checks and timing bookkeeping, plus glue, room, air, mix, mastering, and device output; they do not establish a whole-engine deadline.

The complete-score process peaked at 46,432,256 resident bytes. Separate matched-prefix processes peaked at 36,323,328 bytes before and 28,803,072 bytes after the change. These include Swift, the decoder, and the harness, and reflect touched pages within the unchanged arena allocation. They are not whole-app working-set or physical-device memory results.

## Remaining full-song gates

A pre-gain full-song diagnostic before this change measured maximum/RMS error `2.46712e-5` / `5.70043e-7` against the unchanged original. Its maximum exceeds the existing `1e-5` score-prefix budget. The established [absolute-endpoint versus relative-duration distinction](validation-voices.md#independent-sound-comparison) affects 85 events by one frame in this score. A diagnostic changing only the original durations to those native endpoints reduces maximum/RMS error to `3.72529e-8` / `2.45829e-9`; that counterfactual is not a replacement golden or a full-song conformance pass.

This storage change preserves the existing native output and timing. Complete-song parity, whole-song fixed-gain analysis, rack orchestration, playback, and physical-device memory/energy evidence remain separate work.
