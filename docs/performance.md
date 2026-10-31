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

`scripts/size-report` reports binary, remaining bundle bytes, and total unsigned Release arm64 size. CI builds the merge base in an isolated worktree with the same toolchain/configuration. Fail unexplained growth over the larger of 1 MiB or 5%, and the reviewed absolute cap in [size-budget.json](../size-budget.json). PR 2 proposes a 12 MiB cap and a growth allowance tied only to the exact foundation commit, accounting for 8,975,997 bytes of lossless notes/provenance plus license display. The usual growth rule applies again when the merge base changes. This proxy is not an App Store download estimate.

The local milestone 2 build with Xcode 26.6 measures 9,187,620 bytes: 210,432 binary bytes and 8,977,188 resource bytes. The foundation commit built with the same Release/iphoneos/arm64 configuration measures 189,919 bytes, for an increase of 8,997,701 bytes. This fits the proposed 9,500,000-byte allowance for that exact base and the 12 MiB absolute cap. Boundary checks reject extra growth, a different or missing base SHA, and an oversized total bundle.

For trusted release measurement, archive with the release signing identity outside PR jobs, then export with Xcode's distribution workflow and app thinning set to all supported device variants. Retain `App Thinning Size Report.txt`, export options, Xcode version, device variants, and compressed/uncompressed sizes. Signing assets remain outside Git. Distribution terms and intended App Store route require review before external distribution. No signed export or hardware measurements have run.

## CI performance follow-up

The [first successful hosted CodeQL run](https://github.com/rlefko/lowlight/actions/runs/41160582564) took 14m58s, including a 12m37s clean traced build. Delays occurred during compiler startup/probing and Swift compilation; the completed log did not show a package-resolution stall. The scan extracted the real app and reported zero findings. Investigate this in a separate focused change: compare measured cold/warm runs and supported tracing/toolchain options while retaining a fresh unsigned build and complete extraction. Routine warm-cache feedback near ten minutes remains a goal, not an achieved result.
