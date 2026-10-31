# Testing and contributing

Run `./scripts/setup` once after cloning. It verifies the pinned Xcode/Swift versions, downloads SwiftLint with checksum verification, and installs the tracked Git hooks. Development setup needs internet access; the app does not. Use `./scripts/quality fix` for explicit Swift formatting and `./scripts/quality` to check without changing files.

Pre-commit checks whitespace and staged Swift files from an index snapshot, so partial staging is preserved. Nothing is automatically staged or rewritten. The commit-message hook requires an emoji and one concise sentence fragment without final punctuation.

Use one focused behavior change per PR. Titles start with an emoji and use short Title Case; branches use `rlefko/` plus the title in kebab case without its emoji. Keep handwritten code near 300–500 changed lines, explaining coherent exceptions. Include relevant validation and material limitations. The owner reviews the concrete result before merging; no automatic merges or direct feature pushes to the default branch.

## Checks

`./scripts/build test` runs the launch/About/dismiss/relaunch UI smoke test. `./scripts/build release` builds the unsigned device app used by size reporting. The shell has no logical model to unit test yet; introduce Swift Testing with planner and state-machine behavior. Use XCTest/XCUITest for UI and appropriate performance coverage.

Tests create a temporary device using the runtime and device type pinned in [toolchain.env](../config/toolchain.env), wait for it to boot, and delete only that device afterward. Install the pinned runtime in Xcode Settings > Components for local development. CI initializes Xcode and downloads that exact runtime only if it is missing; it never substitutes another OS version. Set `SIMULATOR_DESTINATION` to an explicit Xcode destination to use an existing device instead.

CI runs Quality, Build and Tests, Audio Regression, Size Budget, CodeQL (Swift/Python), and an always-running CI Gate. Audio Regression verifies the bank and frozen reference, then reproduces the short sound fixtures using pinned developer dependencies. Native Swift Testing checks every bundled note's decoder output and resource membership. CodeQL analyzes the app with a clean traced build and the Python tools in a separate Linux job. Long session soaks, physical-device energy trials, and signed exports stay outside commit hooks and ordinary PR checks.

Manual workflow runs require a `size_base` commit/ref. PRs compare against their actual merge base; main-branch runs compare against the previous head. A missing project counts as a first size baseline only when the base tree is empty.

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
