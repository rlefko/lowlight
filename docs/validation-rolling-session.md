# Bounded rolling session rendering

`PreparedSession` extends finite rendering beyond two songs while keeping at most two admitted racks, 64 combined voice slots, and 64 MiB of PCM arenas. It plans from a seed and fixed controls through `SessionPlanning`, prepares full songs through the existing pool, and uses the same native sum, session fades, and peak protector as `PreparedSongPair`. The finite endpoint must follow the second song's onset. Registered PCM, arena reservation, and process memory remain different measurements.

## Retirement and preparation

When another song is required, rendering stops at the oldest song's complete EOF, including its effect tail. The decision uses consumed session input, not audible output position: the session protector still owns its last 160 frames. The old borrower is detached before its Swift owner is destroyed. Only then can `prepareNext()` reserve and analyze the successor. The survivor and global peak history remain intact, and chronological slot order preserves Float summation order.

Render may return a short count at this boundary. Repeated calls return zero with `needsPreparation == true`, zero unused capacity, and preserve every cursor and DSP state. No silence is inserted into the session clock and the protector is neither drained nor reset. After successful preparation, rendering continues from that same point. At the actual finite endpoint, the existing session exit fade and final peak drain run normally. No successor is requested if its onset is at or beyond that endpoint.

Native admission requires fresh children, exact expected origins, overlap with the survivor, sufficient known coverage, no required three-rack overlap, and the existing shared voice limit. Rejection leaves the renderer unchanged. If preparation throws or admission fails, the failed candidate releases its reservations, the surviving rack remains paused, and the cached schedule is retried rather than skipped. The pending schedule advances only after admission succeeds.

## Thread and lifecycle contract

All operations are serialized. Construction, `prepareNext()`, and destruction run off the render callback. Rendering uses the existing fixed scratch buffers and changes no ownership. This is a single-pass owner: recreate it to rewind. The original fixed pair retains both racks and its existing reset behavior.

This step provides a production rolling renderer with explicit preparation pauses. Asynchronous ownership transfer, timely background preparation, device output, interruptions, and on-device performance validation remain later work. It does not yet provide uninterrupted wall-clock playback.

## Validation

A short four-song test compares every Float bit against an independent offline placement, fade, and protection calculation. Successor onsets coincide with retiring EOFs, so the test exercises the 160-frame pending output at both boundaries. It covers irregular/oversized buffers, repeated waiting calls, native rejection, a throw after acquiring a full candidate reservation, retry identity, caller floating-point state restoration, final drain, and destruction. Weak references and pool counters verify release before replacement and zero reservations after destruction.

Native tests add sub-160-frame startup pauses, repeated four-song replacement, invalid/advanced/over-budget candidates, finite-end equality, terminal faults, allocation audits, and caller numeric modes. Twenty-two frozen original-function probes exercise an already active global protector across a hot third-song onset. All 12 native suites pass optimized and ASan/UBSan; the focused pair/rolling suite also passes Intel execution. All 75 audio tests pass in Debug and Release across 25 suites. The planner, iOS integration/UI tests, Release build, quality checks, and extraction guards pass.

The public seeded session reproduces the accepted warm Commute audition at warmth 0.86 and seed 91031: all 6,400,000 stereo frames over 200 seconds, SHA-256 `a34f8e073cc84affd270c3427d3b87572e75dc2e406f807d95ef9d31efd7a601`. Both regular and irregular buffer passes match exactly, including hostile caller modes during construction and replacement. Its preparation boundary is input frame 3,433,002 and audible frame 3,432,842. Maximum reservations are two racks, 28 voice slots, 67,108,864 arena bytes, and 44,911,672 registered PCM bytes, with zero steals/drops. The unchanged fixed pair also retains its exact 150-second output and reset. These are offline comparisons, not device deadline measurements.

All 193 existing deterministic exports remain byte-identical to PR #35, and all 14 original audio gates pass with unchanged fixtures and limits. Hosted results remain attached to the PR checks.
