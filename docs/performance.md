# Performance and size

These targets are unverified until measured on physical iPhones. No battery, latency, or production-readiness claim follows from the prototype or simulator.

| Measure | Initial target |
| --- | --- |
| Warm Play to audio | ≤ 1 second on oldest agreed test phone |
| Pause response | ≤ 150 ms excluding route latency |
| Callback p99 / p99.9 | < 25% / < 50% of buffer interval |
| Engine working set | ≤ 96 MiB |
| Total background / foreground | ≤ 120 / 160 MiB |
| Two-hour upward memory drift | Investigate > 5 MiB after warmup |
| Thinned download | ≤ 30 MiB |
| Background energy | Within about 10% of local AAC or measurement uncertainty |

Run two-hour locked-screen and foreground/control soaks without underruns. Compare generator, local AAC in the same app/session, and idle under matched device/OS/route/volume/thermal conditions. Use at least three alternating trials of at least 30 minutes per playback condition on an older and a current supported phone. Report absolute readings, incremental cost above idle, variability, and limitations. Measure visuals separately.

`scripts/size-report` reports binary, remaining bundle bytes, and total unsigned Release arm64 size. CI builds the merge base in an isolated worktree with the same toolchain/configuration. Fail unexplained growth over the larger of 1 MiB or 5%, and the reviewed absolute cap in [size-budget.json](../size-budget.json). PR 2 introduced a 12 MiB cap and a growth allowance tied only to the exact foundation commit, accounting for 8,975,997 bytes of lossless notes/provenance plus license display. The usual growth rule applies again when the merge base changes. This proxy is not an App Store download estimate.

The local milestone 2 build with Xcode 26.6 measures 9,187,620 bytes: 210,432 binary bytes and 8,977,188 resource bytes. The foundation commit built with the same Release/iphoneos/arm64 configuration measures 189,919 bytes, for an increase of 8,997,701 bytes. This fits the proposed 9,500,000-byte allowance for that exact base and the 12 MiB absolute cap. Boundary checks reject extra growth, a different or missing base SHA, and an oversized total bundle.

For trusted release measurement, archive with the release signing identity outside PR jobs, then export with Xcode's distribution workflow and app thinning set to all supported device variants. Retain `App Thinning Size Report.txt`, export options, Xcode version, device variants, and compressed/uncompressed sizes. Signing assets remain outside Git. Distribution terms and intended App Store route require review before external distribution. No signed export or hardware measurements have run.

## CI performance follow-up

The [first successful hosted CodeQL run](https://github.com/rlefko/lowlight/actions/runs/41160582564) took 14m58s, including a 12m37s clean traced build. Delays occurred during compiler startup/probing and Swift compilation; the completed log did not show a package-resolution stall. The scan extracted the real app and reported zero findings. Investigate this in a separate focused change: compare measured cold/warm runs and supported tracing/toolchain options while retaining a fresh unsigned build and complete extraction. Routine warm-cache feedback near ten minutes remains a goal, not an achieved result.

The [PR 2 run](https://github.com/rlefko/lowlight/actions/runs/41162564665) took 11m27s for Swift CodeQL, with a 9m34s traced build and zero findings. No tracing optimization was made, so this timing difference does not establish a speedup. The next investigation should enable the pinned action's [supported debug logging](https://github.com/github/codeql-action/blob/v4.39.1/init/action.yml) and inspect `build-tracer.log` and Swift extractor logs to distinguish startup, compiler, and extractor costs before choosing a change.

The [PR 3 run](https://github.com/rlefko/lowlight/actions/runs/41164881078) took 11m17s for Swift CodeQL, including 9m47s tracing, with zero findings and 675,108 extracted AST nodes. The planner target compiled under tracing; PR file-coverage diagnostics were disabled, so retained artifacts do not prove individual-file coverage. The simulator test step also took 10m16s, including 5m25s booting/migrating the simulator. Investigate these separate costs without treating cold infrastructure time as planner execution time.

The [PR 4 run](https://github.com/rlefko/lowlight/actions/runs/41167168037) took 15m22s for Swift CodeQL, including 13m12s tracing and 64s analysis/upload. It extracted 687,407 AST nodes with zero unresolved nodes, findings, errors, or warnings. The traced build spent about 2m03s before the first Xcode output and 6m06s resolving the single local planning package. That interval does not establish a network stall.

The current experiment resolves packages before CodeQL initialization, then runs the same clean unsigned app build with compilation caches and the integrated Swift driver disabled. Preparation must not compile app/package targets. The analyzed build uses fresh DerivedData and reports Xcode task timings; CodeQL debug logs support diagnosing any remaining startup/extractor cost. This follows the distinction between [dependency setup and traced compilation](https://docs.github.com/en/code-security/tutorials/customize-code-scanning/prepare-code-for-analysis). Hosted measurements are required before claiming an improvement.

After normal security analysis, the workflow decodes CodeQL's existing `swift/diagnostics/successfully-extracted-files` query result and requires every tracked Swift source under the app and package `Sources` directories. Missing or malformed extraction evidence fails the job. This inventory is a guard against skipped targets; successful queries and uploaded results alone would not establish that all intended sources were analyzed. Security queries, upload, merge protection, and the other required jobs remain required.
