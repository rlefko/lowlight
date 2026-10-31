# Milestones and release gates

| Milestone | Status |
| --- | --- |
| 1. Establish the Project Foundation | [PR #1](https://github.com/rlefko/lowlight/pull/1) merged; [hosted results](https://github.com/rlefko/lowlight/pull/1/checks) passed |
| 2. Preserve the Audio Reference | [PR #2](https://github.com/rlefko/lowlight/pull/2) merged; [hosted results](https://github.com/rlefko/lowlight/pull/2/checks) passed |
| 3. Add Deterministic Song Planning | Native song plans/checkpoints implemented on `rlefko/add-deterministic-song-planning`; local [validation](validation-planning.md) passed; note events and shared transition timing follow in a separate PR |
| 4. Match the Accepted Instrument Sound | Planned |
| 5. Blend Continuous Sessions | Planned |
| 6. Support Background Playback | Planned |
| 7. Add Expressive Listening Controls | Planned |
| 8. Polish the Native Listening Experience | Planned |
| 9. Validate the MVP on Devices | Planned |

The [public repository](https://github.com/rlefko/lowlight) is configured and administrative access was verified. The active [main-branch ruleset](https://github.com/rlefko/lowlight/rules/26254576) requires PRs, resolved review conversations, up-to-date CI Gate results from GitHub Actions, and CodeQL results with no errors/warnings or medium-or-higher security findings. It blocks deletion and force pushes and has no bypass actors. Active rules were read back from GitHub after configuration.

Required hosted CI and CodeQL results are tracked in each PR's checks. Keep new PRs unmerged until checks pass and the owner reviews the concrete result. Owner review is a manual handoff because the PR author cannot self-approve. No release exists yet.

Current scope: native song planning without playback. Keep note-event expansion and the shared bridge clock together in the next focused PR before starting instrument DSP. No native sound engine exists yet. CodeQL latency remains a [performance follow-up](performance.md#ci-performance-follow-up).

Release gates include sound parity, two-hour native soaks, on-device offline first launch and locked-screen playback, interruption/route behavior, energy/memory/size evidence, accessibility and appearance checks, dependency/asset license inventory, distribution-route review, and an explicit release decision. No App Store submission is authorized by completing a milestone.
