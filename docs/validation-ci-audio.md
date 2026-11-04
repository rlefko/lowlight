# Concurrent scheduled-song tests

`ScheduledSongTests` now uses Swift Testing’s default scheduling instead of the suite’s `.serialized` trait. Its four synchronous tests keep their original bodies, assertions, full-song lengths, and reset checks. No production audio code, fixture, comparison threshold, workflow job, timeout, or CodeQL setting changes.

The tests own their planners, preparers, renderers, and output buffers. Their shared sound bank and fixtures are read-only; the malformed-input test creates a unique temporary directory. The floating-point environment check enters and leaves its synchronous callback on the same thread. These tests do not write candidate exports. Other audio suites were already eligible to run concurrently. Swift Testing controls the actual scheduling; removing the trait does not prescribe a worker count. See Apple’s [parallelization documentation](https://developer.apple.com/documentation/Testing/Parallelization).

## Initial local screening

One complete Debug baseline/candidate pair was measured on November 3, 2026, on an Apple M4 Max with 16 cores and 128 GiB RAM, macOS 26.6, Xcode 26.6, and Swift 6.3.3. Both variants used separate prebuilt scratch directories, identical compiler flags and inputs, and the complete 64-test, 21-suite audio package. The only source difference was the suite trait. Build time was excluded. No candidate exports were enabled during timing, and other project builds/renders were paused for the pair.

| Full Debug suite | Serialized baseline | Default scheduling |
| --- | ---: | ---: |
| Command wall time | 475.91 s | 374.34 s |
| User CPU time | 3,320.15 s | 4,282.41 s |
| System CPU time | 11.14 s | 16.52 s |
| Maximum resident set size reported by `time` | 365,477,888 B | 350,978,048 B |
| Largest sampled process-tree RSS sum | 422,576,128 B | 407,470,080 B |

This pair reduced command wall time by 101.57 seconds (21.34%) while increasing user CPU time by 28.98%. It is screening evidence, not a general CI speedup or CPU-efficiency claim. Individual test durations can increase when tests share cores. The initial pair ran baseline first; two further pairs were planned before accepting the change, in candidate/baseline and baseline/candidate order, with every run retained.

The primary elapsed metric is `/usr/bin/time -l -p`’s `real` value around `swift test --skip-build --configuration debug`. One-second `ps` samples cover the command’s process tree; their RSS sum can count shared mappings more than once and can miss short peaks. The smaller direct-command “peak memory footprint” field is not the descendant test process’s peak and is not used as that measurement. Both screening runs reported zero process swaps and no thermal/performance warning. These observations do not establish a hosted memory bound. Concurrent scheduled tests can reserve up to six 32 MiB mixer arenas instead of two, in addition to other test memory; the engine’s per-mixer limits remain unchanged.

All input and compiled-artifact hashes were checked before and after each run. Raw test logs, `time` output, process samples, and VM/swap/thermal snapshots are retained in ignored local evidence. The same prebuilt commands and full test-name/count checks are used for the planned repeats; no slow observations are discarded.

## Correctness and hosted scope

The candidate’s separate Release run passed all 64 tests in 21 suites. All 193 deterministic PCM/scalar exports were byte-identical to the preceding accepted baseline, and all 14 original-reference comparison gates passed with their existing tolerances. Quality, repository checks, and all 13 CodeQL coverage-guard tests passed. This functional validation ran while other project validation was active and is not timing evidence.

A contemporary unchanged [main-push run](https://github.com/rlefko/lowlight/actions/runs/41736097797) took 1,599 seconds for Build and Tests: 825 seconds for the Debug audio step, 79 for Release audio, and 483 for simulator tests. Its actual Debug test run was 795.793 seconds. This is an observational baseline with a different trigger from a candidate PR, not a matched hosted A/B result. That push exposed eight Actions checks; it does not substitute for the PR’s nine-check acceptance.

The candidate PR must retain all existing planner, native optimized/sanitized, Debug/Release audio, simulator/UI, size, reference-audio, and CodeQL gates. Fresh Swift/C++ traced builds, source-inventory guards, query coverage, and findings protection are unchanged. Hosted runner variability and memory capacity remain separate acceptance concerns. No new app playback, device performance measurement, or physical-device deadline claim is made here.
