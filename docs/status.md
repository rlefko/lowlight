# Milestones and release gates

| Milestone | Status |
| --- | --- |
| 1. Establish the Project Foundation | [PR #1](https://github.com/rlefko/lowlight/pull/1) merged; [hosted results](https://github.com/rlefko/lowlight/pull/1/checks) passed |
| 2. Preserve the Audio Reference | [PR #2](https://github.com/rlefko/lowlight/pull/2) merged; [hosted results](https://github.com/rlefko/lowlight/pull/2/checks) passed |
| 3. Add Deterministic Song Planning | [PR #3](https://github.com/rlefko/lowlight/pull/3) and [PR #4](https://github.com/rlefko/lowlight/pull/4) merged; [event/timing validation](validation-events.md) and [hosted checks](https://github.com/rlefko/lowlight/pull/4/checks) passed |
| 4. Match the Accepted Instrument Sound | [PR #6](https://github.com/rlefko/lowlight/pull/6) merged; [PR #7](https://github.com/rlefko/lowlight/pull/7) merged; [PR #8](https://github.com/rlefko/lowlight/pull/8) merged; [PR #9](https://github.com/rlefko/lowlight/pull/9) merged ([percussion validation](validation-percussion.md)) |
| 5. Blend Continuous Sessions | Planned |
| 6. Support Background Playback | Planned |
| 7. Add Expressive Listening Controls | Planned |
| 8. Polish the Native Listening Experience | Planned |
| 9. Validate the MVP on Devices | Planned |

The [public repository](https://github.com/rlefko/lowlight) is configured and administrative access was verified. The active [main-branch ruleset](https://github.com/rlefko/lowlight/rules/26254576) requires PRs, resolved review conversations, up-to-date CI Gate results from GitHub Actions, and CodeQL results with no errors/warnings or medium-or-higher security findings. It blocks deletion and force pushes and has no bypass actors. Active rules were read back from GitHub after configuration.

Required hosted CI and CodeQL results are tracked in each PR's checks. Keep new PRs unmerged until checks pass and the owner reviews the concrete result. Owner review is a manual handoff because the PR author cannot self-approve. No release exists yet.

[PR #5](https://github.com/rlefko/lowlight/pull/5) merged with all hosted checks passing. Its Intel CodeQL runner and extraction guard remain in place; PR #10 reduced the tool archive size without changing the fresh app trace.

Current scope: PR #10 is merged with [hosted checks](https://github.com/rlefko/lowlight/pull/10/checks) passed. The next focused milestone 4 change adds the accepted rhythm bus: drum low-pass filters, energy gains, and score-keyed kick ducking, with [independent comparison evidence](validation-rhythm.md). Harmonic compression/room, rack transitions, mastering, and playback remain later work. No native playback engine exists yet. CodeQL trace profiling remains a separate performance follow-up.

Release gates include sound parity, two-hour native soaks, on-device offline first launch and locked-screen playback, interruption/route behavior, energy/memory/size evidence, accessibility and appearance checks, dependency/asset license inventory, distribution-route review, and an explicit release decision. No App Store submission is authorized by completing a milestone.
