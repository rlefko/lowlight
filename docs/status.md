# Milestones and release gates

| Milestone | Status |
| --- | --- |
| 1. Establish the Project Foundation | [PR #1](https://github.com/rlefko/lowlight/pull/1) open; local [validation](validation-foundation.md) passed; hosted checks and owner review pending |
| 2. Preserve the Audio Reference | Source inventory verified; import pending review of milestone 1 |
| 3. Add Deterministic Song Planning | Planned |
| 4. Match the Accepted Instrument Sound | Planned |
| 5. Blend Continuous Sessions | Planned |
| 6. Support Background Playback | Planned |
| 7. Add Expressive Listening Controls | Planned |
| 8. Polish the Native Listening Experience | Planned |
| 9. Validate the MVP on Devices | Planned |

The [public repository](https://github.com/rlefko/lowlight) is configured and administrative access was verified. The active [main-branch ruleset](https://github.com/rlefko/lowlight/rules/26254576) requires PRs, resolved review conversations, up-to-date CI Gate results from GitHub Actions, and CodeQL results with no errors/warnings or medium-or-higher security findings. It blocks deletion and force pushes and has no bypass actors. Active rules were read back from GitHub after configuration.

Hosted CI and actual CodeQL analysis are in progress. Keep the PR unmerged until checks pass and the owner reviews the concrete result. Owner review is a manual handoff because the PR author cannot self-approve. No approval or release exists yet.

Next: review the foundation, then preserve the audio reference in a separate PR. The engine and sample bank have not been imported into this branch.

Release gates include sound parity, two-hour native soaks, on-device offline first launch and locked-screen playback, interruption/route behavior, energy/memory/size evidence, accessibility and appearance checks, dependency/asset license inventory, distribution-route review, and an explicit release decision. No App Store submission is authorized by completing a milestone.
