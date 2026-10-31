# Testing and contributing

Run `./scripts/setup` once after cloning. It verifies the pinned Xcode/Swift versions, downloads SwiftLint with checksum verification, and installs the tracked Git hooks. Development setup needs internet access; the app does not. Use `./scripts/quality fix` for explicit Swift formatting and `./scripts/quality` to check without changing files.

Pre-commit checks whitespace and staged Swift files from an index snapshot, so partial staging is preserved. Nothing is automatically staged or rewritten. The commit-message hook requires an emoji and one concise sentence fragment without final punctuation.

Use one focused behavior change per PR. Titles start with an emoji and use short Title Case; branches use `rlefko/` plus the title in kebab case without its emoji. Keep handwritten code near 300–500 changed lines, explaining coherent exceptions. Include relevant validation and material limitations. The owner reviews the concrete result before merging; no automatic merges or direct feature pushes to the default branch.

## Checks

`./scripts/build test` runs the launch/About/dismiss/relaunch UI smoke test. `./scripts/build release` builds the unsigned device app used by size reporting. The shell has no logical model to unit test yet; introduce Swift Testing with planner and state-machine behavior. Use XCTest/XCUITest for UI and appropriate performance coverage.

CI runs Quality, Build and Tests, Audio Regression, Size Budget, CodeQL, and an always-running CI Gate. Audio Regression reports that it is not applicable only while engine code is absent; adding audio code requires real regression tests. Long renders, physical-device energy trials, and signed exports stay outside commit hooks and ordinary PR checks.

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
