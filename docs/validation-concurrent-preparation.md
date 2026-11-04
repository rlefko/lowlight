# Concurrent successor preparation

`PreparedSession` now supports opt-in `.concurrent` preparation. One worker owns planning, the preparation pool, and all strong song references. A separately issued `RenderEndpoint` serves one render consumer. The default serialized mode and fixed-pair renderer keep their existing behavior. Both modes use the same native mix, fade, and session peak-protection loop.

## Preparing while the survivor plays

At the oldest song's full EOF, the render consumer detaches its borrowed pointer and publishes a retirement request. This happens on the native input clock, after all of that song's samples have entered the session protector. The worker acquires the request, releases the retired owner, and only then prepares a replacement through the existing two-rack/64-voice pool.

The consumer continues rendering the survivor while preparation runs. The worker retains the candidate before publishing it; the consumer adopts it at a bounded subblock boundary. The successor starts at its original scheduled onset. Neither retirement nor adoption resets the survivor or global peak history. There is still at most one preparation request and one successor result.

The useful preparation window ends at the successor's onset. If it is not ready, render returns short/zero output with unused capacity zeroed and freezes musical input there. The session protector's last 160 frames remain pending. No logical silence is inserted, no events are shifted, and no final drain occurs until the real finite endpoint. Failed preparation releases candidate reservations and retries the same pending schedule. An EOF/onset tie is valid but provides no preparation headroom; this API does not guarantee uninterrupted device output.

## Ownership and shutdown

The native handoff uses a single lock-free atomic phase with acquire/release publication. The callback publishes immutable request bounds after detaching the retired child. The worker validates only those bounds and its privately owned candidate, never live survivor DSP state. It publishes the retained candidate before the callback may adopt it. Rendering performs no allocation, reclamation, locking, waiting, planning, or decoding.

The Swift worker owner is not `Sendable`. Its narrowly scoped render endpoint is `@unchecked Sendable` and reaches only an immutable native handle, constant frame count, and atomic position/fault snapshots. Issue one endpoint before starting the consumer. Direct rendering through the worker owner is rejected in concurrent mode. Keep pool diagnostics on the worker; read active voice counters only after rendering stops. Status values are individual snapshots, not a coherent multi-field transaction.

Shutdown requires both roles to become quiescent: stop submitting render/preparation calls, wait for calls already in progress, and release the endpoint and pinned worker owner off the audio callback. The endpoint retains the owner but does not replace that shutdown contract. A candidate published concurrently with a terminal renderer fault may remain unconsumed and retained until shutdown; rejected publication never exposes the candidate. Pending retirement and ready-result states are both safe to destroy after quiescence.

No scheduler, concurrent cancellation, device output, or control-edit protocol is introduced here. A playback coordinator must arrange timely worker execution and perform the shutdown sequence before releasing these objects.

## Validation

Four Swift tests use a real render thread and a separate preparation caller. They cover early, late, and tied onsets; a throw after reserving a candidate; retry of the same pending song; and shutdown with either a retirement request or a ready result unconsumed. A free-running four-song test uses only the native protocol to synchronize two replacements. Independent offline placement/fade/protection calculations check every output Float. The focused tests pass in Release and under Swift ThreadSanitizer.

All 12 native suites pass optimized and under ASan/UBSan. The pair suite additionally runs under ThreadSanitizer in the normal test script. It checks repeated free-running handoffs, worker-only reclamation, terminal faults racing publication, numeric-state restoration, and the existing active-protector probes. The focused suite also passes Intel execution. Test-only waits occur outside production rendering, except the deliberately injected downstream fault used to pin publication ordering.

Optimized ARM64 IR and assembly confirm that the render endpoint accesses immutable owner/handle fields and atomic native status without Swift ARC/allocation/free calls. Candidate ownership is established before native publication, retirement releases the old owner before replacement preparation, and the numeric worker remains inside its guarded scope. This evidence applies to the pinned compiler and documented lifetime contract; it is not a device deadline or energy measurement.

The public concurrent session reproduces all 6,400,000 stereo frames of the accepted 200-second warm Commute audition (seed 91031, warmth 0.86), SHA-256 `a34f8e073cc84affd270c3427d3b87572e75dc2e406f807d95ef9d31efd7a601`. A free-running pass and a deliberately late pass with irregular buffers are exact. The late pass freezes at native input 5,123,381/audible frame 5,123,221 before resuming. Construction, preparation, and rendering restore hostile caller floating-point settings. Maximum reservations remain two racks, 28 voice slots, 67,108,864 arena bytes, and 44,911,672 registered PCM bytes, with zero steals/drops. Offline polling and these resource counters do not measure device deadlines or resident memory.

The serialized 200-second session and fixed 150-second pair/reset remain byte-identical. All 79 audio tests pass in Debug and Release across 26 suites; all 193 existing deterministic exports match PR #36 and all 14 original reference gates pass with unchanged fixtures and limits. Planner, iOS integration/UI, Release build, quality, repository, and extraction-guard checks pass. Hosted results remain attached to the PR checks.
