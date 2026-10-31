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

Swift CodeQL uses the standard `macos-26-intel` runner with the same pinned Xcode 26.6, Swift 6.3.3, and CodeQL 2.27.3. It still builds the actual Release iPhone app and planning package for `arm64-apple-ios18.0`. The other Apple jobs remain on Apple Silicon. Both runner images provide the [pinned Xcode installation](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md); this change does not require a paid larger runner.

Measured hosted comparisons use unchanged application sources:

| Run | Swift host / preparation | Traced build | Entire Swift job |
| --- | --- | --- | --- |
| [PR 4](https://github.com/rlefko/lowlight/actions/runs/41167168037) | ARM, original | 13m12s | 15m22s |
| [Merged PR 4 baseline](https://github.com/rlefko/lowlight/actions/runs/41168394915) | ARM, original | 11m07s | 13m08s |
| [Preparation experiment](https://github.com/rlefko/lowlight/actions/runs/41168795774) | ARM, packages resolved first; debug enabled | 13m42s | 16m28s |
| [Intel comparison](https://github.com/rlefko/lowlight/actions/runs/41169295648) | Intel, original clean build; debug enabled | 5m48s | 8m57s |
| [Final PR 5](https://github.com/rlefko/lowlight/actions/runs/41170228749) | Intel, clean build; debug disabled | 8m24s | 11m47s |

Relative to the contemporaneous merged-base run, the Intel comparison reduced tracing by about 48% and the complete Swift job by about 32%. Its full workflow reached CI Gate in 9m05s. The final PR 5 repeat reduced tracing by about 24% and the Swift job by about 10% against that baseline. These are observed runs, not guaranteed latency; runner variation is visible even in the two original ARM runs. The package-preparation experiment did not demonstrate a benefit and is not retained. Tracer logs show expensive binary relocation/signing transitions on ARM. [CodeQL requires Rosetta for compiled builds on Apple Silicon](https://codeql.github.com/docs/codeql-overview/system-requirements/), but the logs do not isolate Rosetta's contribution from other host differences.

Coverage was checked beyond successful upload: both debug runs extracted the same 13 repository Swift files, with identical source hashes and 1,013 successfully extracted lines. Their manifest, planning, and app extractor invocations all succeeded. Normalized source lists, SDK, deployment target, optimization, and semantic flags match; compiler thread counts differ with the hosts. Both report zero unresolved nodes and zero code-scanning findings, errors, or warnings. Aggregate AST totals differ (ARM preparation: 690,146; Intel: 688,747; merged-base ARM: 694,300), so they are not treated as proof of AST identity or a fixed coverage threshold.

Every Swift run now decodes the existing `swift/diagnostics/successfully-extracted-files` result and requires all tracked app sources, package `Sources`, and package manifests. Missing, malformed, or incomplete inventories fail the job; generated extras are allowed. The small `swift-extraction-inventory` artifact is retained for seven days. This guard accompanies the real clean build, disabled compilation caches/integrated driver, normal security queries, upload, and merge protection.

Xcode task timings remain in the job log. Detailed CodeQL logs and a database bundle are opt-in through `codeql_debug` on manual workflow runs; they are off by default to avoid routine bundling/upload overhead. The [pinned action supports these debug artifacts](https://github.com/github/codeql-action/blob/v4.39.1/init/action.yml). Seven local coverage-gate tests exercise missing app/package/manifest files, invalid output, empty inventories, and outside-file substitutions. The actual Intel inventory also passes the expanded 13-file check.

### CodeQL archive setup

The native job now analyzes Swift and C++ together, with guards for all 17 tracked Swift sources/manifests and both C++ implementation/header files. Python runs separately. Setup uses the official CodeQL 2.27.3 `.tar.zst` bundles instead of `.tar.gz`; the action revision, CLI version, query packs, runner, fresh build, compilation-cache settings, categories, and required checks remain unchanged. The `/language:swift` category is the existing native comparison key.

The [pinned action's extraction code](https://github.com/github/codeql-action/blob/9b3254085494b55a0f7c4c2b3d2d52cc712ce370/src/tar.ts) supports Zstandard with BSD tar ≥3.4.3 or GNU tar ≥1.31 and zstd available on PATH. The macOS runner provides BSD tar 3.5.3 and zstd 1.5.7; the Linux logs show GNU tar 1.35 and working Zstandard extraction. No new installer or permanent benchmark job is added.

The [official 2.27.3 release](https://github.com/github/codeql-action/releases/tag/codeql-bundle-v2.27.3) publishes both formats:

| Platform | Gzip bytes | Zstandard bytes | Download reduction |
| --- | ---: | ---: | ---: |
| macOS | 1,259,640,549 | 878,370,760 | 30.3% |
| Linux | 695,275,440 | 558,869,612 | 19.6% |

Both downloaded macOS archives matched the official SHA-256 digests. Their decompressed tar streams are byte-for-byte identical: 3,189,903,360 bytes, SHA-256 `2d232ac295ead4b405d1514c7854dfca84847acf86a4ad779e586aea79220180`. Extraction also produced identical paths, modes, and hashes for 37,317 regular files and 5,657 directories across all four trials.

An exploratory local Apple M4 Max/arm64 comparison used BSD tar 3.5.3, libarchive 3.7.4, zstd 1.5.7, and the pinned action's commands: `tar xz -C DEST -f ARCHIVE` for gzip; `tar -x --zstd --ignore-zeros -f ARCHIVE -C DEST` for Zstandard. Four fresh-directory trials in gzip/Zstandard/Zstandard/gzip order took 7.332/6.579/6.031/7.054 seconds (means 7.193/6.305 seconds). Digest verification warmed the archives in filesystem caches; no cache purge or fsync was used. Timing includes process startup/extraction but excludes download and hashing. A brief disk-usage probe overlapped the reversed pair. Two trials per format on an uncontrolled local host establish neither hosted latency nor a fixed percentage gain.

Retained macOS gzip baselines both missed the tool cache:

| Run | Download | Extraction | Entire initialization | Fresh trace | Native job |
| --- | ---: | ---: | ---: | ---: | ---: |
| [PR 8](https://github.com/rlefko/lowlight/actions/runs/41215691162/job/124579740372) | 12.9 s | 46.7 s | 91.1 s | 10m49s | 16m43s |
| [PR 9](https://github.com/rlefko/lowlight/actions/runs/41219372696/job/124590614333) | 16.3 s | 57.5 s | 110.2 s | 9m42s | 15m12s |

Download, extraction, and initialization use adjacent timestamped log markers; trace/job times use GitHub's whole-second step metadata. Both runs used the same macOS image and tool versions, but separate workers with unrecorded CPU contention. The archive alone was identical while download/extraction already varied from 59.6 to 73.8 seconds. Compare those setup phases separately from compilation and analysis; whole-job variation is not an archive-speed measurement. Python's existing tool-cache hit provides no cold-extraction timing comparison.

Validation retains the 13 coverage-guard tests, the actual extracted-source inventories, CLI version and query counts, final analysis diagnostics/findings, aggregate CodeQL check, and CI Gate. Tool-archive caching is separate from compilation caching: the actual app and both packages still receive a fresh traced build. The slower trace remains a separate profiling concern.
