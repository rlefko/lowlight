# Testing and contributing

Run `./scripts/setup` once after cloning. It verifies the pinned Xcode/Swift versions, downloads SwiftLint with checksum verification, and installs the tracked Git hooks. Development setup needs internet access; the app does not. Use `./scripts/quality fix` for explicit Swift formatting and `./scripts/quality` to check without changing files.

Pre-commit checks whitespace and staged Swift files from an index snapshot, so partial staging is preserved. Nothing is automatically staged or rewritten. The commit-message hook requires an emoji and one concise sentence fragment without final punctuation.

Use one focused behavior change per PR. Titles start with an emoji and use short Title Case; branches use `rlefko/` plus the title in kebab case without its emoji. Keep handwritten code near 300–500 changed lines, explaining coherent exceptions. Include relevant validation and material limitations. The owner reviews the concrete result before merging; no automatic merges or direct feature pushes to the default branch.

## Checks

`./scripts/test-dsp` runs the C++ kernel tests optimized and with AddressSanitizer/UndefinedBehaviorSanitizer, including allocation and voice-limit audits. `./scripts/test-audio` (or `release`) checks native instrument preparation, complete voice output, and malformed input boundaries. CI transfers the macOS Release samples to the Linux Audio Regression job for comparison against the original Python functions and retains dry-note A/B evidence; see [tonal preparation](validation-tonal.md) and [voice validation](validation-voices.md), [bass validation](validation-bass.md), [percussion validation](validation-percussion.md), [rhythm bus validation](validation-rhythm.md), [harmonic glue validation](validation-glue.md), [stereo room validation](validation-room.md), and [peak protection validation](validation-peak.md).

`./scripts/test-planner` runs Swift Testing on the native planning package without a simulator or audio hardware; add `release` to verify the same vectors with production optimization. `./scripts/build test` runs native bank/planning integration checks and the launch/About/dismiss/relaunch UI smoke test. `./scripts/build release` builds the unsigned device app used by size reporting. Use XCTest/XCUITest for UI and appropriate performance coverage.

Tests create a temporary device using the runtime and device type pinned in [toolchain.env](../config/toolchain.env), wait for it to boot, and delete only that device afterward. Install the pinned runtime in Xcode Settings > Components for local development. CI initializes Xcode and downloads that exact runtime only if it is missing; it never substitutes another OS version. Set `SIMULATOR_DESTINATION` to an explicit Xcode destination to use an existing device instead.

CI runs Quality, Build and Tests, Audio Regression, Size Budget, CodeQL (Swift/C++/Python), and an always-running CI Gate. Build and Tests runs the hardware-independent planning/event/timing suite in Debug and Release before iOS integration/UI tests. Audio Regression verifies the bank, frozen reference, derived grammar, and independent event oracles, then reproduces the short sound fixtures using pinned developer dependencies. Native Swift Testing checks every bundled note's decoder output and resource membership. CodeQL analyzes Swift and C++ in separate Intel jobs, each running the same clean app build; Python tools run in a separate Linux job. Long session soaks, physical-device energy trials, and signed exports stay outside commit hooks and ordinary PR checks.

Both native CodeQL jobs use standard Intel runners while compiling fresh arm64 app/package targets with compilation caches disabled. Swift and C++ extraction/analysis run in parallel; each job verifies its own source inventory. After analysis, `scripts/verify-codeql-coverage.py` checks the decoded inventories against tracked app/package Swift sources, package manifests, and C/C++ package sources/headers. The retained `swift-extraction-inventory` and `cpp-extraction-inventory` artifacts support coverage review. Run its failure-path tests with `python3 -B -m unittest discover -s tests -p test_codeql_coverage.py`. See [CI performance evidence](performance.md#ci-performance-follow-up) for timing and validation limits.

CodeQL setup uses the pinned bundle's Zstandard archive through the pinned action's supported extraction path. The hosted images provide compatible tar and zstd tools. Tool-cache hits may skip download/extraction; compare cache misses and those setup phases separately from the fresh app trace. See [archive measurements](performance.md#codeql-archive-setup) for content verification and timing limits.

Manual workflow runs require a `size_base` commit/ref. Enable `codeql_debug` only when tracer logs and database bundles are needed (`codeql-debug-swift` and `codeql-debug-cpp`); ordinary runs retain the small extraction inventory and build timings. PRs compare against their actual merge base; main-branch runs compare against the previous head. A missing project counts as a first size baseline only when the base tree is empty.

The active [main-branch ruleset](https://github.com/rlefko/lowlight/rules/26254576) requires PRs, resolved review conversations, an up-to-date CI Gate from GitHub Actions, and CodeQL findings protection. Force pushes and deletion are blocked, with no bypass actors. CodeQL errors/warnings and medium-or-higher security findings block merging. Read the active branch rules back through GitHub's API when changing protection; workflow YAML alone is insufficient. Owner-authored PRs use mandatory CI and an explicit manual review/merge handoff because GitHub cannot accept self-approval.

## Verified tool references

Tool versions and SHA pins were checked against upstream sources on October 30, 2026. Hosted runner images change, so the exact toolchain check fails visibly if the selected installation disappears.

- [macOS 26 arm64 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [CodeQL compiled build options](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages)
- [Preparing a traced CodeQL build](https://docs.github.com/en/code-security/tutorials/customize-code-scanning/prepare-code-for-analysis)
- [SwiftLint releases](https://github.com/realm/SwiftLint/releases)
- [Official swift-format](https://github.com/swiftlang/swift-format)
- [Required check behavior](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)
- [Pull request approval restrictions](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/approving-a-pull-request-with-required-reviews)
- [Xcode app thinning reports](https://developer.apple.com/documentation/xcode/reducing-your-app-s-size)
- [Installing Xcode simulator runtimes](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
