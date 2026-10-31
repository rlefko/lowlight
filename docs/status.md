# Milestones and release gates

| Milestone | Status |
| --- | --- |
| 1. Establish the Project Foundation | Local branch ready for review; [validation](validation-foundation.md); remote PR pending |
| 2. Preserve the Audio Reference | Source inventory verified; import pending review of milestone 1 |
| 3. Add Deterministic Song Planning | Planned |
| 4. Match the Accepted Instrument Sound | Planned |
| 5. Blend Continuous Sessions | Planned |
| 6. Support Background Playback | Planned |
| 7. Add Expressive Listening Controls | Planned |
| 8. Polish the Native Listening Experience | Planned |
| 9. Validate the MVP on Devices | Planned |

No remote is configured. Repository permissions, visibility/plan support for CodeQL and rulesets, hosted CI results, and required-check enforcement are unverified. A local workflow cannot enforce merging. Keep the branch unmerged until the remote is selected, checks actually pass, and the owner reviews the concrete result. No PR URL or approval exists yet.

Next: review the foundation, then preserve the audio reference in a separate PR. The engine and sample bank have not been imported into this branch.

Release gates include sound parity, two-hour native soaks, on-device offline first launch and locked-screen playback, interruption/route behavior, energy/memory/size evidence, accessibility and appearance checks, dependency/asset license inventory, distribution-route review, and an explicit release decision. No App Store submission is authorized by completing a milestone.
