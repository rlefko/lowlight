# Foundation validation — October 30, 2026

Local branch: `rlefko/establish-the-project-foundation`. Intended PR title: **🛠️ Establish the Project Foundation**. An empty base commit contains no product files; all implementation is on the feature branch.

Validated with Xcode 26.6 (17F113), Swift 6.3.3, and the iOS 26.5 SDK/runtime:

- `scripts/setup`: pinned SwiftLint 0.65.1 download checksum and tool versions passed.
- `scripts/quality`: official Swift formatting and selected SwiftLint rules passed.
- `scripts/build test`: iPhone 17 simulator, one launch/About/license/credits/dismiss/relaunch test, zero failures; test execution 12.658 seconds.
- `scripts/build release`: unsigned arm64 device build passed, deployment target iOS 18.
- `scripts/check-repository`: documentation links, complete license, acknowledgment, and foundation resource inventory passed.
- Hook checks accepted a valid staged file with an invalid working copy and rejected an invalid staged file with a valid working copy. Index and working copy remained unchanged.
- Workflow YAML, embedded Bash, Ruby syntax, positive/negative commit convention cases, and failed/skipped/canceled CI dependency cases passed local checks.
- Size checks accepted exactly 1 MiB growth and rejected 1 MiB + 1 byte growth, absolute-budget overflow, and a simulator app presented as a device build.
- Light and dark simulator screenshots were inspected without clipping. This is not a physical-device accessibility audit.

The [first unsigned size baseline](foundation-size-baseline.json) is 188,672 bytes for the app binary, 1,191 bytes for other bundle files, and 189,863 bytes total. There is no prior app for a growth comparison. Different build paths can affect binary size; CI will establish its own first baseline. These measurements exclude signing and app thinning.

The [light](images/foundation-light.png) and [dark](images/foundation-dark.png) simulator screenshots are retained as documentation only, outside app resources. Local build evidence remains under `.build/`: `script-test.log`, `script-release.log`, and `DerivedData/Logs/Test/*.xcresult`. Hosted runs retain their own test and size artifacts.

The public repository and [PR #1](https://github.com/rlefko/lowlight/pull/1) now exist. Administrative access and the active [main-branch protection rules](https://github.com/rlefko/lowlight/rules/26254576) were verified through GitHub's API. CI Gate is bound to the observed GitHub Actions app ID. CodeQL findings protection is enabled; an uploaded analysis still needs its findings checked.

Current hosted Actions and traced CodeQL results are recorded in the [PR checks](https://github.com/rlefko/lowlight/pull/1/checks). Physical-device behavior, native audio parity, battery/memory measurements, and signed-export sizes remain pending. No owner approval or release exists yet.
