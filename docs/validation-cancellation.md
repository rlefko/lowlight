# Cooperative preparation cancellation

`PreparationCancellation` is a one-way, thread-safe token for one preparation attempt. A control thread can call `cancel()` while a worker constructs a song or prepares a session successor. Observed cancellation throws `CancellationError`; cleanup runs on that worker. Pass a new token to retry. Omitting the token preserves the existing behavior.

Checks occur before pool admission and planning, before and after sample preparation, around source construction, between 256-frame loudness-analysis blocks, and before session publication. The token carries only a cancellation flag; it never transfers mutable song state. Native rendering, ownership transfer, and musical timing are unchanged. No cancellation check runs in the audio callback.

Cancellation is cooperative, not a wall-clock deadline. It does not interrupt an individual recording decode/filter operation or the native quiet-air setup pass. A request racing the final check can arrive after successful construction or publication. Canceling then does not revoke a live song, stop rendering, or join either role. Playback coordination must still stop and join both roles before final release off the callback.

An initial session canceled during either song's preparation releases all of its admitted racks. For a successor, cancellation before retirement leaves the current pair intact; cancellation afterward releases the unfinished candidate and leaves the survivor plus the same pending schedule. Retrying does not advance planning twice or shift the successor's onset. The concurrent renderer can continue through the available preparation window; its existing late-onset pause remains in force.

Four focused tests pass in Debug and Release. They cover cancellation before decoding, monotonic cross-thread requests, cancellation after the first real 256-frame analysis block with caller floating-point state restored, initial-pair cleanup, and successor rejection/retry in both serialized and concurrent modes. All eight cancellation and concurrent-handoff tests pass under ThreadSanitizer without race reports. The tests pin progress with an internal observer; public tokens have no observer and no progress callback runs in production.

All 83 audio tests pass in Release across 27 suites. All 193 existing deterministic exports match PR #37, and all 14 original reference gates pass with unchanged fixtures and limits. The unsigned iOS Release build, seven integration tests, one UI test, quality checks, and 13 extraction-guard tests pass. Hosted full Debug/Release, native sanitizer, size, and CodeQL results remain attached to the PR checks.

The accepted 200-second warm Commute audition (seed 91031, warmth 0.86) remains exact across all 6,400,000 stereo frames, SHA-256 `a34f8e073cc84affd270c3427d3b87572e75dc2e406f807d95ef9d31efd7a601`. Separate worker/render passes cover ordinary preparation and a deliberately late successor canceled after real analysis progress, followed by a fresh retry. The late pass preserves the original onset and continuous peak history. The same two-rack reservation limit holds; these offline results do not establish device deadlines or resident memory.

Device scheduling, pause-response measurements, and physical-device playback remain later work.
