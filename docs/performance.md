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

`scripts/size-report` reports binary, remaining bundle bytes, and total unsigned Release arm64 size. CI builds the merge base in an isolated worktree with the same toolchain/configuration. The initial empty base is explicitly reported as a first baseline. Fail growth over the larger of 1 MiB or 5%, and the reviewed absolute cap in [size-budget.json](../size-budget.json). The shell cap is 5 MiB; bank import requires a reviewed budget change. This proxy is not an App Store download estimate.

For trusted release measurement, archive with the release signing identity outside PR jobs, then export with Xcode's distribution workflow and app thinning set to all supported device variants. Retain `App Thinning Size Report.txt`, export options, Xcode version, device variants, and compressed/uncompressed sizes. Signing assets remain outside Git. Distribution terms and intended App Store route require review before external distribution. No signed export or hardware measurements have run.
