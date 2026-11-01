# Reference note duration validation

The v9 import now preserves the original guitar, piano, and bass envelope lengths. Native-generated events continue to round absolute onset, gate, and release endpoints on the shared clock. Both paths still produce the same version-1 `NoteEvent` representation; decoding previously serialized events does not reinterpret their endpoints.

For reference guitar/piano, hold is `round(duration * 32000)` and release is independently `round(release * 32000)`. Bass instead uses that rounded hold and a total span of `round((duration + release) * 32000)`. The importer adds those lengths to the existing absolute onset. These formulas reproduce the unchanged original voice functions, including bass's combined rounding. Sample truncation remains the renderer's responsibility. Percussion keeps its existing fields because its one-shot envelopes do not use these gates.

The original 621-event score contains 85 affected notes: 58 guitar, 22 piano, and five bass. Each affected envelope length differs by one frame from the earlier import. The original event file, sound assets, DSP kernels, waveform goldens, and comparison tolerances stay unchanged. The prepared sample calculation retains 23,363,076 bytes across the same 63 keys, 32 bytes less than before, within the unchanged 32 MiB arena.

## Independent timing oracle

The [timing fixture](../tests/fixtures/reference-timing-v9/README.md) extracts the relevant expressions from the unchanged original source, then checks actual original voice outputs separately. It freezes all 621 endpoint triples with zero frame tolerance and 15 probes covering nearest-even boundaries, separate versus combined rounding, sample truncation, bass sustain, one-shot gate independence, preserved absolute onsets, and a rejected zero-frame hold. Expected data is frozen before changing the native importer.

Run `python tools/reference/verify-reference-timing.py --integrity` for inventory/provenance checks. With the pinned reference environment installed, run `.tools/reference/bin/python3 tools/reference/verify-reference-timing.py` to rederive the complete oracle. Ordinary planner tests compare imported events against the frozen endpoints; the existing native event and audio comparisons remain in CI.

## Complete-song evidence

The production voice → glue → room → mix path renders all 621 accepted events and 3,711,911 stereo frames with zero steals or drops. Against the unchanged original before fixed gain, maximum/RMS error fell from `2.4671200663e-5` / `5.7004343779e-7` to `3.3527612686e-8` / `2.4571809017e-9`. The existing `1e-5` / `1e-6` limits now pass without changing the original input, goldens, or budgets. The corrected pre-gain stream has SHA-256 `9c1c75e52fbf14025fef1bd12dceca483d6e923ef21cb5c04a0685f9a1ebf20b`.

The bounded production preparation uses exactly the independently predicted 23,363,076 sample bytes. The native meter measures the corrected body at −30.318920002223475 LUFS; the separate gain/protector diagnostic preserves the complete finite frame count. This is one accepted first-song comparison, not general session or physical-device certification.

All 2,322 native-generated fixture events retain byte-identical sorted-key JSON before/after the fix: 505,121 bytes, SHA-256 `c8d3e4bdd4513cfdc6438a54f63a4b0c6584588b0d23bf290b81f328d20320b2`. All 23 planner tests pass in Debug and Release.

All 39 audio tests pass in Debug and Release, as do seven iOS integration tests, the UI smoke test, the unsigned Release build, strict formatting/lint, resource checks, and all 13 coverage-guard tests. All 13 existing audio comparison families pass. Ten import-dependent PCM files improve to maximum/RMS errors no greater than `2.2352e-8` / `1.8341e-9`; the other 151 PCM files and all 27 loudness/gain scalar files remain byte-identical. Unrelated bus fields in changed musical cases also remain exact. Repeat freezing preserves the timing manifest byte-for-byte, and 21 negative controls reject altered timing, schema, probes, or provenance.

A local four-second reference/native review excerpt spans source frames `[1363834, 1491834)`, centered on the former worst-error point. Both receive the same original whole-body gain before song peak protection; neither clip is independently normalized. Their loudness is −20.329959914 / −20.329959846 LUFS. This audition is separate from the numerical full-song gate and does not claim a completed listening review.

## Scope

This corrects reference envelope lengths. It does not change the native planner's version, clock, random draws, or serialized endpoint contract. Absolute onsets remain `round(time * 32000)`; independently mapping a reference song's nonzero origin to `round(local_time * 32000)` remains separate work. Complete-song evidence here concerns the accepted first song at origin zero. [Body selection](validation-song-body.md) is now explicit; production rack preparation/replay, transport, and playback remain later work.
