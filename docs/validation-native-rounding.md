# Native DSP numeric environment validation

Native voice, glue, room, peak, air, mix, loudness, and gain operations use one private scoped floating-point policy. Each floating-point setup or processing call rounds to nearest, ties to even, and flushes subnormals. It restores the caller’s complete ARM64 FPCR/FPSR or SSE2 MXCSR on success and rejection. Callers may vary rounding, flush mode, and sticky exception flags; exception traps must stay masked and other controls must retain platform defaults. Pure integer bookkeeping and queries need no arithmetic guard. The policy is thread-local and synchronous; no state token crosses an asynchronous boundary.

Previously, voices, glue, room, and peak processing retained the caller’s rounding mode. Mixer setup also computed coefficients, ducking, and event gains under that ambient mode, and ARM64 voice rendering did not restore exception flags. The shared policy extends the behavior already used by the later native stages to these paths. It changes neither musical parameters nor the accepted default-rounding signal path.

The pinned Clang build enables `FENV_ACCESS` for native DSP arithmetic so the optimizer respects the scoped environment; disabling contraction alone does not establish that ordering. See the [Clang floating-point environment documentation](https://clang.llvm.org/docs/UsersManual.html#accessing-the-floating-point-environment).

## Boundaries

The scope below describes PR #25. [Voice preparation](validation-preparation-environment.md) subsequently adds the distinct gradual-underflow boundary for sample preparation and mixer construction.

This contract starts with already-prepared PCM and canonical C event/control values. It does not make Swift sample preparation, Double-to-Float event conversion, or planner timing independent of the host environment. Existing bass preparation includes valid subnormal Float samples; a later Swift preparation policy must preserve gradual underflow before the existing native registration/render flush boundary. Applying the native policy around the entire Swift initializer would change those accepted prepared bytes.

Nonzero negative subnormal values remain invalid for nonnegative control domains, even when flushing is enabled. Negative zero remains accepted. Validation uses raw IEEE representations where flushing could otherwise turn an invalid input into zero. The native API retains its existing ownership, input bounds, finite stream lengths, and per-call failure behavior.

## Validation

The native integration suite prepares all eight processors under each supported rounding/flush combination, then independently varies processing modes. Within each architecture, it compares every intermediate output bit, loudness result, and gain against the default-mode run. This covers 64 setup/render combinations on ARM64 and 256 on x86_64, with irregular chunks, reset, and both finite drains. Each setup, processing, reset, and rejection call audits exact control/status restoration; real-time calls also audit allocations and frees. Signaling NaNs, negative subnormals, and signed zero exercise validation boundaries and rejected-call rollback.

The same new test compiled against the unchanged PR #24 sources fails in mixer bus setup because it leaks the inexact exception flag. Optimized ARM64 and x86_64/Rosetta runs pass with this change. The pinned compiler’s optimized IR for all nine arithmetic translation units uses constrained floating-point operations; representative setup and processing paths keep arithmetic between mode installation and restoration.

All nine native suites pass optimized and under AddressSanitizer/UndefinedBehaviorSanitizer. All 47 audio tests in 16 suites pass in Debug and Release, and all 193 deterministic candidate files remain byte-identical to PR #24, including the prepared bass subnormals. All 14 unchanged reference comparison gates pass. The unsigned Release app build, seven iOS integration tests, UI smoke test, strict formatting/lint, resource checks, and 13 extraction-guard tests pass.

Strict environment semantics reduce some compiler optimizations, including fixed-gain vectorization. A same-process Apple M4 Max diagnostic on macOS 26.6 used separate before/after libraries, identical Clang `-O2 -ffp-contract=off` flags, three paired trials with the middle order reversed, and 4,000 measured 256-frame calls after 512 warmup calls. Median trial means increased from 42.1 to 56.5 µs for 64 harmonic voices and from 0.25 to 0.34 µs for gain. The larger increase is about 0.18 percentage points of the 8 ms internal frame interval. This measurable cost is accepted for the numeric contract. These host/simulator checks do not establish device energy or callback deadlines. Full rack preparation/replay, two-rack transport, and physical-device performance remain separate work.
