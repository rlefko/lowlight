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

PRs 7–11 analyzed Swift and C++ together in one native job, with guards for all 17 tracked Swift sources/manifests and both C++ implementation/header files. Python runs separately. Setup uses the official CodeQL 2.27.3 `.tar.zst` bundles instead of `.tar.gz`; the action revision, CLI version, query packs, runner, fresh build, compilation-cache settings, categories, and required checks remain unchanged. The `/language:swift` category is the existing native comparison key.

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

### Parallel native CodeQL analysis

Swift and C++ now use separate `macos-26-intel` matrix jobs, following [GitHub’s recommendation to analyze languages in parallel](https://docs.github.com/en/code-security/reference/code-scanning/workflow-configuration-options#languages-to-be-analyzed). Each job still builds the actual unsigned Release arm64 iPhone app and both local packages from a clean, separate DerivedData directory. The Xcode/Swift/CodeQL pins, query suites, all three compilation-cache/driver flags, extraction guards, and merge protection remain unchanged. Python keeps its Linux job. No product, sample-bank, or renderer source changes accompany this CI change.

The Swift category remains `/language:swift`, the existing comparison key. C++ gains `/language:cpp`; Python retains `/language:python`. The Swift and C++ jobs each require their corresponding extracted-source inventory, and CI Gate requires the entire matrix to succeed. The new C++ category must be checked alongside the preserved Swift category; successful upload alone does not establish a complete or passing scan.

The change removes serial C++ work from the Swift job at the cost of one additional fresh app build and an additional concurrent Mac runner. In PR 11’s combined job, C++ finalization and query/SARIF processing consumed about 98 seconds after build tracing. Parallelism can shorten the native critical path when the C++ job finishes before Swift. The remaining Swift package-resolution and extraction cost still needs profiling; no compilation caching or target omission is used to conceal it.

For measurement, report the native wall span from the first native job start to the last native job finish, and the time from workflow creation to that finish. The longest individual job omits delays when the jobs start at different times; the sum measures runner use, not elapsed feedback time. Report queue delay and whole-workflow completion separately. The matched manual runs use nondefault branches, identical application/package/toolchain source trees, the same workflow trigger, and debug disabled. A main-push or PR run has different analysis context and is supplementary evidence, not a matched timing treatment.

The first matched pair used [combined run 41227008751](https://github.com/rlefko/lowlight/actions/runs/41227008751) and [split run 41227070866](https://github.com/rlefko/lowlight/actions/runs/41227070866). App/package/project/test/toolchain/build-script/reference-tool Git objects are identical. All three native jobs missed the tool cache and both C++ executions restored the same 32,597,260-byte TRAP cache from `fbc0b56`; CodeQL extraction caching is distinct from the disabled compiler caches.

| First matched pair | Init | Fresh trace | Analysis | Native job |
| --- | ---: | ---: | ---: | ---: |
| Combined Swift/C++ | 1m55s | 9m38s | 2m18s | 14m22s |
| Split Swift | 49s | 8m27s | 2m30s | 12m10s |
| Split C++ | 58s | 1m18s | 50s | 3m27s |

The observed native execution span fell by 132 seconds, while summed native runner time rose from 14m22s to 15m37s. This is not a stable percentage improvement: initialization alone accounts for 66 seconds of the difference, including identical archive extraction taking 68.4 seconds versus 24.1 seconds on different workers. The candidate’s C++ job queued for 7m51s during concurrent main/baseline/candidate workflows; this is not a controlled estimate of ordinary PR queue cost. It still finished before Swift, so native span equals the Swift job duration in this trial.

The first pair reached native completion 14m57s versus 12m46s after workflow creation. However, the complete workflows reached CI Gate in 15m02s versus 16m46s: the candidate’s Build and Tests job waited for a runner, then its downstream audio check finished after CodeQL. This trial does not establish faster overall PR feedback.

The repeat used [combined run 41228406940](https://github.com/rlefko/lowlight/actions/runs/41228406940) and [split run 41228473706](https://github.com/rlefko/lowlight/actions/runs/41228473706), with the same respective source commits and inputs.

| Second matched pair | Init | Fresh trace | Analysis | Native job |
| --- | ---: | ---: | ---: | ---: |
| Combined Swift/C++ | 2m37s | 15m22s | 6m21s | 25m00s |
| Split Swift | 1m23s | 7m36s | 1m23s | 10m58s |
| Split C++ | 1m32s | 2m09s | 1m17s | 5m28s |

The split’s actual native wall span was 12m48s because Swift started 1m50s after C++; its longest job alone would understate elapsed time. Native runner use totaled 16m26s. The repeated split reached native completion 13m40s after workflow creation and CI Gate in 13m44s. The combined control took 25m04s to native completion and 25m24s to CI Gate. All native jobs again missed the tool cache; both repeat arms restored the same 32,594,764-byte C++ TRAP cache from `25fd93c`. This is a different cache from the first pair, so compare within each pair.

Both pairs favored native completion, while whole-workflow results were mixed. Retain the split to remove serial C++ work, with the extra build and runner requirement explicit. The large repeat difference is not an isolated matrix effect: Swift compile task time varied from 510.804 seconds in the control to 256.173 seconds in the candidate, and initialization/analysis also varied. These observations establish neither a fixed percentage gain nor routine ten-minute feedback.

Across both pairs, the actual native SARIF rule-ID union is identical: 27 Swift plus 58 C++ rules match the combined 85; Python’s 43 rule IDs also match. Normalized source inventories are identical, with all 17 tracked Swift sources/manifests and both C++ files verified. Swift’s inventory additionally includes the public C header. Those analyses have zero errors, warnings, and findings, and Swift reports zero unresolved AST nodes. The [PR’s aggregate CodeQL status](https://github.com/rlefko/lowlight/pull/12/checks) and new-category acceptance require separate verification on its merge commit.
