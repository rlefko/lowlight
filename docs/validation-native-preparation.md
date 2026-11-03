# Preparing native song schedules

`PreparedSong(schedule:preparer:)` prepares an existing native `SongSchedule` directly. It validates that schedule and derives its events, finite layout, rack fades, take seed, harmonic focus, and sound controls together before calling the existing complete-song preparation path. The bus uses the song's realized energy, which can differ from its requested control value.

Schedule validation, event expansion, and frame/fade derivation execute inside the existing round-to-nearest, gradual-underflow preparation scope. The caller's floating-point state is restored on success and failure. Creating plans or schedules, restoring planning checkpoints, and calling planning/time-conversion APIs separately remain outside this boundary.

## Shared clock and limits

Events, fades, and the source origin retain the schedule's shared absolute frame clock. Body boundaries and the exposed replay cursor remain local to the song. The layout includes the existing five-second allocation tail; the source and peak stages retain their existing startup/drain alignment. Construction returns ready at logical frame zero.

This entry point does not change planning algorithms, sample mappings, DSP formulas, capacities, or the explicit-input initializer used for reference playback. Invalid schedules and invalid finite layouts reject before sample decoding. Existing sample-slot, PCM, and event capacity failures still propagate. It does not establish that every native plan fits a rack or that two racks share one voice budget.

## Validation

Complete finite renders match the explicit-input API bit for bit for the first native Focus piano song (603 events, 3,769,861 frames) and an incoming guitar song (369 events, 2,395,514 frames) on a nonzero-origin 60→100 BPM ramp. Both exercise realized energy, body measurement, fixed gain, EOF, and reset. The incoming case also verifies preparation under a hostile caller floating-point state. Invalid focus/seed and a valid schedule whose five-second tail exceeds the frame domain reject before decoding; a 73-key score retains the existing 64-sample capacity failure.

Local Debug and Release each passed 63 audio tests across 20 suites. The 193 existing deterministic exports remain byte-identical to PR #28. The 23 planner tests passed in both configurations, all 11 native suites passed optimized and with ASan/UBSan, and the Release app, seven simulator integration tests, one UI test, quality/repository checks, and 13 extraction-guard tests passed. Optimized Swift inspection confirms the derivation worker remains inside the numeric scope and the render/reset code is unchanged.

The complete first native song also matches an explicit-input render captured from PR #28's compiled objects before rebuilding: protected PCM SHA-256 `07b624c5db578f2a0a9fa04037541cabbe4342f769efac090bc120388666e75c`. The original 621-event reference score retains its prior mastered PCM and reset replay exactly, with zero steals/drops. All 14 existing audio comparison gates pass with unchanged tolerances and fixtures. These are separate native-schedule and reference-playback checks; they do not assert equivalence between the native and Python planners.

The next session layer still needs shared admission limits, bounded ownership transfer and retirement, global protection after overlap, and transport. Nonzero-origin reference placement and physical-device playback/performance remain separate work.
