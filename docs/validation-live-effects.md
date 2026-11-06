# Live listening controls

Warmth softens guitar and piano and darkens their room return. Space changes the existing room's decay and wet level, including an active tail. Texture controls the level of the synthetic air while its two noise streams continue to advance. On the listening screen, Warmth sits beside Energy and Mood. Space and Texture are in More Controls with Tempo and Variation.

During a drag, the listener hears the new tone on sustained notes and new attacks. Each edit retargets a 6,400-frame ramp from its current value at the 32 kHz internal sample rate. The command starts beyond audio already prepared by the two peak protectors and the centered compressor. At steady playback, this adds 719 canonical frames (22.47 ms) before the beginning of the ramp, plus the wait for the next bounded render block. Device output latency is separate.

The app saves one full setting when a drag ends or an accessibility adjustment completes. Presets update the three effects together. Energy, Mood, Tempo, and Variation use a separate musical revision and the existing prepared transition. An effect-only edit leaves the selected score, preparation, and structural retry state intact. Pause retains the current ramp and room history. Relaunch uses saved settings and musical position with a fresh effects history and an entry fade when playback is requested.

## Renderer

Each admitted guitar/piano sample contains transposed, high-passed Float32 PCM and a calibration key. Its active voice runs the original two low-pass sections, calibrated note gain, and piano attack shaping before event gain and pan. A shared table holds 100 note/take keys × 101 quantized Warmth settings. The 40,400-byte resource is tied to the accepted assets and preparation version. Coefficients and the shared first-second piano curve are prepared off the render thread. See the [calibration recipe](../tools/calibration/README.md).

The ongoing session accepts one latest three-value target independently of successor preparation. The control producer computes the target room coefficients. A bounded native exchange transfers them to the single render consumer. Retargeting preserves the filter, delay, compressor, noise, and peak-protection histories. A fixed history covering the rack's lookahead lets both tonal voices and delayed effects evaluate the ramp on the same musical frame. Each admitted rack reads that session curve at its own placement, including a replacement song prepared before the edit or an original song restored after rollback. One fixed gain still applies to each song, with peak protection after the sum.

## Host callback measurements

Release builds used macOS 26.6, Xcode 26.6, and Swift 6.3.3. Each pull returns 256 stereo frames at 32 kHz, giving an 8,000 µs interval. The ordinary fixture plays seed 91,031 into its first overlap and reserves 28 voice slots. The dense fixture sustains 32 guitar/piano voices per rack across two overlapping racks. Both include room, air, both song protectors, and the shared session protector. Timing encloses only render. The first 16,384 frames and any partial final pull are excluded from timings. Complete stereo hashes include those frames.

**Fixed-control parity.** The finite comparisons used the PR 49 renderer (`c57f294`) and the calibrated voice renderer, with the same fixtures compiled on each revision. Every stereo Float32 word and both measured song gains matched within each architecture for 3,609,861 ordinary frames and 1,024,000 dense frames. The comparison passed in native arm64 and in x86_64 binaries running under Rosetta. Each version held 49,119,072 and 1,536,000 prepared PCM bytes respectively. All timings below are native arm64.

**Callback cost.** Times are µs per pull. Each mean is the median of the three run means. Each percentile is the highest of the three run percentiles, using nearest rank. Worst is the largest individual wall time. At this block size, the targets are p99 below 2,000 µs and p99.9 below 4,000 µs. [Performance targets](performance.md).

| Transport | Score | Condition | Mean thread CPU | Mean wall | Wall p99 | Wall p99.9 | Worst wall |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Finite | Ordinary | PR 49 | 45.6 | 45.7 | 95.2 | 114.4 | 160.9 |
| Finite | Ordinary | Calibrated voices | 51.1 | 51.3 | 93.8 | 108.9 | 324.9 |
| Finite | 64 voices | PR 49 | 110.0 | 110.3 | 147.9 | 336.6 | 479.3 |
| Finite | 64 voices | Calibrated voices | 160.5 | 160.9 | 198.3 | 224.5 | 248.9 |
| Ongoing | Ordinary | Effects disabled | 51.4 | 51.6 | 92.3 | 106.4 | 144.4 |
| Ongoing | Ordinary | Effects seeded and steady | 51.5 | 51.7 | 93.8 | 113.0 | 220.2 |
| Ongoing | Ordinary | Repeated edits | 54.7 | 54.9 | 102.8 | 120.3 | 145.6 |
| Ongoing | 64 voices | Effects disabled | 158.6 | 158.9 | 199.0 | 224.7 | 239.0 |
| Ongoing | 64 voices | Effects seeded and steady | 163.6 | 164.1 | 202.4 | 346.4 | 1,096.7 |
| Ongoing | 64 voices | Repeated edits | 165.8 | 166.1 | 207.7 | 232.8 | 259.5 |

Moving the filters into active voices raised mean thread CPU by 11.94% on the ordinary finite score and 45.91% at 64 voices, using the median of three paired percentage changes. For ongoing playback, seeding effects added 0.14% and 1.35% relative to the same transport with effects disabled. Repeated edits added 7.34% and 4.55%. Each ongoing rotation rendered 3,609,856 ordinary and 1,023,744 dense frames. The seeded and disabled hashes matched exactly. The edited output had its own repeatable hash and settled at the last requested revision.

The drag pattern alternates all three controls between two targets, interrupting ramps after 8, 24, or 32 ms, then allows them to settle. A full-history interruption can materialize 559 prior profiles in one pull. Each rotation captured 1,757 such adoptions on the ordinary score and 495 at 64 voices. Their worst individual pulls were 145.6 and 219.4 µs. The JSON separates these pulls, shorter interruptions, adoption after settling, continuing ramps, and settled playback. Device energy, actual output latency, and physical-device callback headroom still require the matched phone trials in the [performance plan](performance.md).

**Fixed storage.** The gain resource adds 40,400 bytes. Both racks share one 309,328-byte runtime calibration table, including gains, 12,928 bytes of coefficients and 256,000 bytes of piano attack factors. Against PR 49, arm64 Clang record layouts add 23,824 bytes per rack across its mixer, source, room, and air objects. Each pair adds 104,456 bytes for live state, including the 102,856-byte history. These fixed objects add 461,432 bytes for one pair, two racks, and one shared table. Process RSS also includes allocations, temporary preparation storage, and the platform audio stack. Admission still caps the pair at two 32 MiB PCM arenas and 64 simultaneous voice slots.

## Reproducing the checks

Run the normal quality, planner, DSP, audio, app, and size checks in the [build instructions](../README.md#build). Native tests exercise rapid reversals, arbitrary pull sizes, concurrent publication, room-tail and air continuity, exact settled-target acknowledgments, and two-rack overlap. The original 193 frozen exports and 14 reference comparisons run alongside direct production PCM checks against PR 49.

Prebuild the Release tests with the pinned toolchain. Run these commands from the repository root on a quiet host. Each fixture writes JSON under `.build`. The finite fixture emits one file per score. To reproduce the fixed-control comparison, put the same `LiveCallbackEvidenceTests.swift` in a separate checkout at `c57f294`, build it there, and run the two revisions in baseline/candidate, candidate/baseline, baseline/candidate order. Compare `stereoFloat32SHA256`, `gains`, `frames`, `measuredBlocks`, `requiredVoiceSlots`, and `preparedPCMBytes` within each architecture. Use fresh output directories for each trial. The ongoing fixture writes six files per rotation and checks final control revisions, complete hashes, and voice counters.

```sh
xcrun swift build -c release --build-tests -Xswiftc -enable-testing --package-path Packages/LowlightAudio
LOWLIGHT_CALLBACK_EVIDENCE="$PWD/.build/finite-1" \
  xcrun swift test -c release --skip-build --package-path Packages/LowlightAudio --filter LiveCallbackEvidenceTests
for rotation in 0 1 2
do
  LOWLIGHT_EFFECT_CALLBACK_ROTATION="$rotation" \
  LOWLIGHT_EFFECT_CALLBACK_EVIDENCE="$PWD/.build/ongoing-$rotation" \
    xcrun swift test -c release --skip-build --package-path Packages/LowlightAudio --filter LiveEffectsCallbackEvidenceTests
done
```

The rotations start with effects disabled, the steady seed, and the changing target respectively, cycling through all three modes on identical prepared racks. Read `wallNanoseconds` and `threadCPUNanoseconds` directly for the finite fixture. For ongoing results, concatenate those arrays across `buckets` for each score and mode or take the individual bucket of interest. The warmup and partial-pull exclusions are already applied.

The opt-in soak uses the app's preparation worker, musical handoffs, and render endpoint. Its 240 effect cycles span two logical hours. Each cycle exercises supersession, a reversal during the 200 ms ramp, and a return to the committed setting.

```sh
LOWLIGHT_EFFECT_AUDITIONS="$PWD/.build/effect-auditions" \
  xcrun swift test -c release --package-path Packages/LowlightAudio --filter LiveEffectsAuditionTests
python3 tools/auditions/compare-effects.py .build/effect-auditions
LOWLIGHT_CONTROLS_SOAK_SECONDS=7200 LOWLIGHT_CONTROLS_SOAK_ACCELERATION=8 \
  LOWLIGHT_CONTROLS_SOAK_OUTPUT="$PWD/.build/live-soak" \
  xcrun swift test -c release --package-path Packages/LowlightAudio --filter SessionControlsStressTests
```

The audition test renders six versions of seconds 24–48 from seed 1 and Focus using the same production path. Each pair changes one effect to 0 or 1 at four seconds into its clip and returns to Focus at 16 seconds. The raw four-second prefix must match across all six passes. The comparison script requires FFmpeg, measures loudness and true peak, and applies one fixed attenuation per file to match the two excerpts. It records hashes and levels in `comparison.json`. Listen for the quality of guitar/piano attacks and sustained notes, smooth changes in room tails, and a quiet texture at the top of its range.

## Two-hour controls soak

The production worker rendered 230,400,000 stereo frames at 32 kHz. It observed all 28 intended musical revisions and excluded all 28 deliberately superseded revisions. All seven scheduled settings appeared across 92 selections. All ten Next requests led to a later selection, five preparation suspensions completed, and the worker stopped cleanly. Each of the 240 effect cycles superseded one target, reversed an active ramp, and returned to the committed value. The final requested and settled effect revisions were both 985.

The first fixed-schedule run observed 27 of 28 intended handoffs. Relax was still pending when Commute superseded it. An isolated rerun applied Relax at 284.154 seconds, the same generated frame as PR 49. The coverage fixture now treats each four-minute slot as the earliest time to submit an intended setting. If the preceding musical revision is still pending, it gives it another 30 seconds of music, paces that period at real time, and records the delay. The deliberate bursts still submit obsolete requests back to back. The passing two-hour run needed zero such deferrals.

At up to eight times real time, the run took 1,429.5 seconds after initial preparation. Requests took 12.970–72.597 seconds of music to reach the first observed applied snapshot (median 24.756). Those intervals cover structural handoffs. The three live effects use the much shorter ramp described above. Peak absolute amplitude was 0.776304 and stereo RMS was 0.079579. Of 214,604 pulls, 873 returned zero while waiting for preparation and one returned a partial block. The offline harness resumes at the next available frame. Its test process reached 106,102,784 resident bytes. A device run is still needed to measure audible interruptions, memory drift, and energy.

## Local regression checks

The three engine commits each passed the complete Debug audio partitions, the Release suite, native DSP tests in optimized and sanitizer configurations, the focused Swift Thread Sanitizer run, 25 planner tests in each configuration, app tests, and the size check. The test runner verified that the Debug partitions covered every compiled test once. The calibration commit discovered 177 audio tests. The native effects and playback coordination commits each discovered 178. The focused Swift sanitizer selections covered 73, 74, and 74 tests respectively, including their opt-in skip guards.

The final app change discovered 179 audio tests and ran all 52 suites in Release, including four opt-in cases skipped by default. It reran app and device builds, Debug discovery and opt-in guards, and verified the previous native, Debug, and sanitizer results against identical engine inputs. Each of the four changes reproduced all 193 frozen exports byte for byte and passed 14 independent reference comparisons. The full gain-table comparison checked all 10,100 entries. Separate enabled runs exercised the callback fixtures, the long soak, and the isolated listening pairs.

## Isolated listening pairs

All six 24-second stereo WAVs have finite Float32 samples. Each pair has the same score and performances with one effect at its two extremes. All six raw four-second prefixes match byte for byte. The endpoints have equal measured integrated loudness after matching. The RMS differences use unadjusted stereo samples from seconds 5–15, after the first ramp settled.

| Effect | Both clips, LUFS | True peak, low / high (dBTP) | RMS difference |
| --- | ---: | ---: | ---: |
| Warmth | -21.26 | -5.00 / -5.01 | 0.038440 |
| Space | -21.57 | -5.00 / -6.02 | 0.032529 |
| Texture | -21.26 | -5.00 / -5.01 | 0.001742 |

The comparison script records each raw and WAV SHA-256 for reproduction. The shared raw prefix SHA-256 is `d6f465497b157890bc3ec566bd32f46cc1d88b582b95ac3ac2a7be5203712ebf`. The measurements confirm an isolated signal change at each control. Subjective listening on headphones and speakers remains an owner acceptance step.

## App size and controls

The unsigned arm64 Release app occupies 11,368,494 bytes, including a 2,323,896-byte executable and 9,044,598 resource bytes. An equivalent fresh build of PR 49 occupies 11,227,952 bytes. The 140,542-byte increase fits the 1,048,576-byte growth allowance and the 12,582,912-byte bundle budget. Both builds use the same Xcode version, device destination, architecture and signing settings. A second build in the per-commit check measured 11,367,526 bytes and also passed both gates. The signed, thinned download needs a distribution build.

On a fresh iPhone 17 simulator running iOS 26.5 with the default light appearance and text size, 41 app tests in seven suites and both UI flows passed. The UI flows covered Play/Pause, About, editing all seven values, persistence, and silent relaunch. Five screenshots captured the light appearance.

On the same simulated model and OS in dark mode at the largest accessibility text size, seven listening-model tests and the complete edit, save, and relaunch UI test passed. Five screenshots cover the main controls, the secondary sheet, Auto and manual tempo, and restored Custom values. The Mood value wraps to its own line. Scrolling the sheet exposes Variation and the explanatory text. VoiceOver operation and touch reachability on physical devices still need a listening and accessibility pass.
