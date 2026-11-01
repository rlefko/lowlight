# Mixer song origin validation

`TonalVoiceMixer` accepts a `frameOrigin`, defaulting to zero. Construction, score loading, and reset place its absolute playhead at that origin with empty voice/filter history, neutral ducking, and cleared counters. Rendering advances directly from there without producing the earlier session's silence. The dry and bus views share that same playhead.

## Clock and lifecycle

Events and rack fades keep their existing absolute 32 kHz coordinates. A score may start at or after the origin; any earlier event rejects the complete load before state changes. The mixer does not seek into a running note, reconstruct earlier filter history, or carry voices from a previous rack. Those tails belong to the rack that produced them.

The native `ll_mixer_configure_origin` call is permitted only before the first successful score load, like the existing bus/fade configuration. Invalid and late calls preserve all state. A failed first load leaves setup open; an empty successful load locks it. Reset and subsequent successful loads preserve the configured origin. The maximum is the existing `2^52` timeline boundary; an empty score there permits only zero-frame rendering. Existing event lifetime and render-overflow checks remain in force.

Swift validates the origin and every onset before preparing samples. Native schedules can pass their `SongRenderLayout.frameOrigin` while retaining the shared event and transition endpoints. This avoids independently rounding or rewriting events when starting a later song.

## Validation and scope

Tests compare dry output and every bus field against integer-translated zero-origin runs, including absolute fades, kick ducking, chunk changes, and reset. Boundary tests cover setup locking, transactional rejection of pre-origin events, and the end of the timeline. Existing frozen reference comparisons continue to guard the default zero-origin behavior; no audio golden or tolerance changes.

All eight native suites pass optimized and under AddressSanitizer/UndefinedBehaviorSanitizer. The mixer also passes optimized x86_64 through Rosetta. Its origin cases preserve exact dry Float bits and all nine bus fields at offsets 37, 2,764,800,123, and `2^40`, with no render/reset allocations or frees. The Swift tests exercise a native transition at a nonzero origin and prove that invalid scores are rejected before decoding PCM.

All 47 audio tests in 16 suites pass in Debug and Release. All 161 existing PCM files and 32 loudness/gain/body-layout JSON files remain byte-identical to PR #23. Seven iOS integration tests, the UI smoke test, the unsigned Release build, strict formatting/lint, resource checks, and all 13 coverage-guard tests pass. These are host/simulator checks, not physical-device performance evidence.

This is a starting-coordinate contract, not a reference-time importer. Original later-song placement rounds local seconds; subtracting rounded absolute endpoints is not generally equivalent. That mapping, complete rack preparation/replay, a consistent floating-point boundary around the rack, and two-rack transport remain separate work. Sample, event, voice, and PCM capacities are unchanged.
