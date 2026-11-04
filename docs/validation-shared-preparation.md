# Shared song preparation limits

`SongPreparationPool` admits actual `PreparedSong` instances through either native schedules or explicit reference inputs. One pool admits at most two racks and a combined conservative demand of 64 voice slots. A single preparation owner must serialize construction and destruction off the audio callback. Rendering and reset use the existing song path without accessing the pool.

## Admission and ownership

The pool reserves a rack before decoding samples or allocating its PCM arena. After the source loads its score, it claims that score's voice demand before starting the full-song loudness analysis. A third rack or a score exceeding the remaining voice budget throws a distinct error. Source, analysis, or later preparation failures return every reservation. A successful song privately retains its reservation until destruction; the pool does not retain songs. Destroying or resetting another song cannot invalidate its source.

Each rack reserves the existing fixed 32 MiB PCM arena, so two admitted racks reserve at most 64 MiB of arena storage. `preparedPCMBytes` separately reports registered sample bytes. Neither number represents total process memory: decoding, preparation scratch, filters, room state, and other objects remain additional costs. The per-rack sample and event caps are unchanged. Standalone `PreparedSong` initializers retain their existing overload behavior and do not join a pool implicitly.

## Conservative voice demand

The native mixer computes immutable raw demand while loading a validated score. It counts nonzero prepared-gain, non-bass readers over half-open intervals `[start, start + lifetime)`. Tonal lifetimes use the prepared sample length capped by the event's hold and release; percussion uses the complete prepared sample. Silent PCM and rack fades still occupy readers. Zero prepared gain skips a reader, while a zero-gain kick still drives its existing duck envelope.

Any bass event reserves one additional slot, including silent bass. The existing monophonic replacement path stays within that slot. Demand is never clamped to 64: overload must remain visible to admission. Summing each rack's individual peak is deliberately conservative and remains safe when their source and peak-protector lookahead clocks differ. It bounds simultaneous readers without changing scheduling, stealing, fades, or sound processing.

The setup scan is allocation-free and bounded by the existing 2,048-event limit; its worst case is quadratic. Invalid reloads leave the prior score and demand intact, and reset preserves the loaded demand. No scan, allocation, reservation update, or destruction is added to rendering.

## Validation

Focused checks cover half-open endpoints, one-frame peaks, sample/gate lifetimes, silent and overlapping bass, zero-gain kick ducking, raw overload demand, failed reloads, and reset. Swift tests exercise the inclusive 32 + 32 voice boundary, rejection at 65, rejection before third-rack decoding, rollback after both decoding and body-analysis failures, and release/reuse. The existing complete native-schedule comparison uses a pooled song against its independent explicit-input path.

Debug and Release each pass all 67 audio tests across 22 suites. All 11 native suites pass optimized and under ASan/UBSan, with the focused mixer suite also passing under x86_64 emulation. The mixer remains 186,976 bytes on the local arm64 build; its rendering and reset code are unchanged. All 193 existing deterministic exports remain byte-identical to PR #31, and all 14 original audio comparison gates pass with unchanged fixtures and tolerances. The 25 planner tests pass in both configurations, as do the Release iOS build, seven simulator integration tests, one UI test, quality/repository checks, and 13 extraction-guard tests.

An offline diagnostic holds the first two songs of the accepted 200-second native audition together, releases the first, and then admits the third. It preserves all 6,400,000 stereo frames exactly: raw Float32 SHA-256 `a34f8e073cc84affd270c3427d3b87572e75dc2e406f807d95ef9d31efd7a601`. Maximum reservations are two racks, 28 voices, and 64 MiB of PCM arenas, with 44,911,672 registered PCM bytes. All reservations return to zero, and all three songs retain zero steals/drops. The offline summation and session protection are unchanged; this is pool-path parity evidence, not a production transport test.

This is a preparation boundary for the future two-rack session owner. It does not implement audio-thread ownership transfer, retirement, overlap transport, continuous planning, or global session protection. It also does not guarantee every native plan fits the existing per-rack PCM limit. Physical-device playback and energy evidence remain pending.
