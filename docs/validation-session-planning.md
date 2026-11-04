# Stable session planning

`SessionPlanning` owns a bounded `SessionTimeline` and executes complete planning operations inside the existing preparation numeric scope: round to nearest with gradual underflow, restoring the caller's control and status registers on both success and failure. It covers initialization, advancement, control normalization, current-schedule frame queries, position updates, checkpoint encoding, and checkpoint restoration. All calls must be serialized off the audio callback.

## Why the boundary includes the whole operation

The earlier preparation entry points already protect sample processing and derivation from formed schedules. Planning happens before those entry points. In a diagnostic linked to the preserved pre-change objects, downward or toward-zero rounding changed the accepted Commute plan's first tempo from 84.56 to 84.55 BPM. Upward rounding changed its energy and successor tempo. Grammar JSON decoding also changed stored scalar values, and all three non-nearest modes rejected an otherwise valid canonical schedule/checkpoint. Explicit final integer rounding cannot correct earlier arithmetic or decoding differences.

The new owner enters the numeric scope before grammar loading, planning, validation, or serialization. Private non-inlined workers keep this work inside the synchronous scope. Mutating operations use a copied timeline and commit it only after successful scope return. A failed advance, invalid edit, or invalid frame leaves the previous intent intact. Checkpoint versions, planner algorithms, pending-song control semantics, and the existing pure planning package are unchanged.

## Entry points and limits

Use `next()` to obtain a schedule for the existing guarded `PreparedSong` or `PreparedSongPair` path. Use the owner's `frame(at:)` to query its current schedule; querying before the first advance fails. `current` and `positionFrame` are stored-value snapshots. `restore` accepts the existing timeline checkpoint format and restores planning intent, not effect state or audible playback.

`PreparedSongPair(seed:controls:frameCount:preparer:)` now plans its first two schedules through this owner and delegates the existing finite renderer. Its two-rack, voice, PCM, endpoint, and full-song analysis limits remain unchanged. There is no second audio renderer or new callback work.

The owner accepts the exact control values supplied by its caller. It cannot recover values already rounded while constructing those inputs outside the scope. Direct use of the original planning/time APIs, or calling methods on a returned schedule independently, retains the original caller-environment contract. Automatic continuous rack replacement, thread handoff, device playback, and physical-device performance evidence remain later work.

## Validation

Four focused tests compare schedules, frame queries, and exact checkpoint bytes against the original planner through a 60→100→60 sequence across caller rounding, flush, and status modes. They cover pristine and midstream restoration, invalid controls/positions/time queries, failed restoration, an actual clock-overflow failure during advancement, and seeded-pair rejection before sample decoding. Frozen pre-change frame probes independently anchor the clock comparison.

The focused tests pass in Debug and Release, and all 74 Release audio tests pass across 24 suites. All 193 existing deterministic exports remain byte-identical to PR #34, and all 14 original audio gates pass with unchanged fixtures and limits. Inspection of optimized ARM64 output confirms that the pinned Swift compiler retains the worker boundaries, commits timeline state after scoped success, and rethrows errors after restoring the caller. This is evidence for the pinned build, not a general compiler guarantee.

A 150-second render now plans both songs from seed 91031 and the accepted Commute controls with warmth 0.86 under hostile caller settings. It matches the preserved PR #34 composition byte for byte, including reset with irregular buffers: all 4,800,000 stereo frames, SHA-256 `060d6642dd8dcb4dce8e62ae4a09b374ce67947a03413f20de247098daf47ad1`. Reservations remain two racks, 28 voice slots, 64 MiB of PCM arenas, and 44,911,672 registered PCM bytes, with zero steals/drops. This checks the complete seeded planning-to-rendering path; it is not a device performance measurement.
