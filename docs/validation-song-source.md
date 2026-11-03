# Finite song mix rendering

`SongRenderSource` owns the prepared voices, harmonic glue, stereo room, quiet air, and HP32 mix for one finite song. It accepts an existing `SongRenderLayout`, canonical events, and fades on the same absolute clock. Every event onset must fall inside the declared song; gates, releases, and effect tails stop at its declared end. The layout already includes the intended allocation tail.

The source returns exactly `layout.inputFrames` logical stereo frames at 32 kHz, before body analysis, fixed gain, and song peak protection. It removes glue's 399 startup frames before room or air can consume them, then drains glue to recover the final logical frames. This keeps the first event, room history, air modulation, and HP32 aligned without storing a complete song.

## Ownership and lifecycle

Swift privately retains the prepared mixer; the native composition borrows it and owns the downstream stages and fixed 256-frame scratch buffers. No second owner can render or reset that mixer through the public Swift source. Construction, sample decoding, air normalization, and destruction happen off the audio callback. Swift setup uses the existing gradual-underflow preparation scope; native calls retain their scoped processing policy and restore caller floating-point state.

`render(into:)` accepts a preallocated interleaved stereo buffer and returns the number of frames written. It clears unused capacity, returns zero at EOF or for zero capacity, and advances the logical cursor only after a successful call. Rendering and reset use fixed storage, with no allocation, locks, or I/O. Calls must be serialized by one owner.

Invalid buffer dimensions leave progress unchanged. If a downstream stage unexpectedly fails after earlier stages advance, the complete output is silenced and the source remains faulted until reset. This is not rollback of the internal signal history. Reset rewinds voices, glue, room, air, HP32, and the logical cursor together, retaining prepared samples and air normalization.

## Validation

Ten native suites pass optimized and under AddressSanitizer/UndefinedBehaviorSanitizer; the source suite also passes on x86_64. Tests compare an independently assembled primitive chain across lengths around the 399-frame boundary, translated origins, irregular pulls, EOF, and resets. They audit allocation/free counts, pointer bounds, setup failure cleanup, and floating-point restoration. A test-only redirected room call fails after earlier output was produced, proving complete-call silencing, the terminal fault, and reset recovery; production builds contain no injection hook.

The complete accepted first song now runs through the production source: 621 events and 3,711,911 stereo frames, using 23,363,076 prepared PCM bytes, with no steals or dropped events. Output and reset replay are byte-identical to the corrected [full-song baseline](validation-reference-timing.md), SHA-256 `9c1c75e52fbf14025fef1bd12dceca483d6e923ef21cb5c04a0685f9a1ebf20b`. Maximum/RMS error against the unchanged original remains `3.3527613e-8` / `2.4571809e-9`, within the existing `1e-5` / `1e-6` limits. A separate body-meter pass retains −30.318920002223475 LUFS and the same 859/859/849 total/absolute/gated block counts. This is one complete song, not a session or playback test.

The new native source allocation is 23,608 bytes on ARM64, including 23,552 bytes of scratch. Its borrowed mixer and existing downstream processor allocations are additional. Optimized Swift IR confirms no allocation or floating-point arithmetic in the render wrapper and verifies that native destruction precedes release of the mixer. These host checks do not establish device memory, energy, or callback deadlines.

All 55 Swift audio tests in 18 suites pass in Debug and Release. All 193 deterministic exports remain byte-identical to PR #26; the two existing musical mix prefixes now exercise this production source directly. The Release app build, seven simulator integration tests, UI smoke test, strict formatting/lint, resource checks, and 13 extraction-guard tests pass. All 14 unchanged reference comparison gates pass.

The next preparation layer can stream this source through `SongBodyLoudness`, retain one fixed gain, reset the source, and replay through song peak protection. That two-pass preparation, nonzero-origin reference import, shared two-rack voice/memory limits, transport, playback, and physical-device performance remain separate work.
