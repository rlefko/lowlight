# Voice preparation environment validation

`TonalSamplePreparer.prepare` and complete `TonalVoiceMixer` construction execute with round-to-nearest, ties to even, and gradual underflow. Sample decoding, resampling, filtering, calibration, envelopes, control validation, sample-key selection, and Double-to-Float event conversion share that scope. The caller’s ARM64 FPCR/FPSR or SSE2 MXCSR is restored on success and failure.

This complements the [native DSP policy](validation-native-rounding.md), which flushes subnormals during processing. Prepared bass samples already contain valid subnormal Float values; keeping gradual underflow during preparation preserves those accepted bytes. Nested native registration/loading temporarily uses its existing flushing policy and restores the surrounding preparation mode before Swift resumes.

## Synchronous ownership

A small C entry point invokes the Swift body exactly once on the calling thread. The private Swift adapter keeps its invocation alive for that call, captures success or the original error in a typed `Result`, then returns or rethrows after native restoration. No borrowed context survives the call. Mixer construction creates its handle inside the scope and destroys it there on failure.

This is off-audio-thread preparation work. It does not introduce an asynchronous state token or allow work to migrate between threads. Callback implementations must return normally; Swift errors stay inside the adapter until the C call returns. Callers may vary rounding, flushing, and accrued exception flags; exception traps must be masked and other floating-point controls must retain platform defaults. The scope covers Float/Double preparation on the pinned toolchain.

## Scope and validation

The contract begins with supplied controls, already-formed note events, and fade descriptors. Planning, reference import, beat/frame derivation, the bank manifest initializer, and unrelated Swift APIs remain outside it. No waveform formula, sample/voice capacity, planning version, reference fixture, or comparison tolerance changes.

Local validation on the pinned Xcode 26.6 toolchain passed:

- Nine native suites in optimized and ASan/UBSan builds, plus the floating-point matrix on x86_64. The preparation boundary checks all rounding/flush combinations, clear and accrued flags, nesting, same-thread execution, null arguments, and zero boundary allocations.
- 51 Swift audio tests across 17 suites in Debug and Release. New cases cover real sample bodies, the exact 16 accepted bass subnormals, hat-layer selection before Float conversion, mixer output, invalid controls, and decode failure after native setup.
- All 193 deterministic exports remain byte-identical to PR #25, and all 14 unchanged reference comparison gates pass. No fixtures or tolerances changed.
- Release app build, seven simulator integration tests and one UI test, formatting/lint, resource checks, and 13 coverage-guard tests. Test-only floating-point helpers are absent from the app build and executable symbols.

Separate controls using the old implementation compiled successfully and reproduced caller-status corruption and different rendered bits under altered rounding. The updated implementation passes the same checks.

Optimized Swift IR keeps numeric preparation inside the callback and error propagation after native return. All nine existing native processing units retain identical optimized assembly on ARM64 and x86_64, excluding source-file labels. This change adds preparation work only; it does not alter steady-state DSP instructions or establish physical-device energy performance.

Full rack preparation/replay, two-rack transport, and physical-device performance remain later work.
