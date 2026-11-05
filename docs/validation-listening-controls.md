# Presets and musical listening controls

This change exposes the existing Focus, Relax, Commute, Workout, and Reflective presets as complete normalized `Controls` snapshots. Selecting one replaces all preset values atomically, including the tone settings used when preparing its next song. Custom is derived from full-value comparison with those five presets; it is not an additional preset or a separately persisted selection.

| Surface | Controls |
| --- | --- |
| Main listening screen | Preset, Energy 0–100%, Mood from reflective to bright (−1…1) |
| More Controls | Explicit Auto Tempo, manual Tempo 60–100 BPM, Variation 0–100% |
| Deferred | Individual live Warmth, Space, and Texture adjustments and effect smoothing |

Auto remains an explicit `nil` tempo request. Turning Auto off starts manual Tempo at the rounded Auto target for the current Energy. Slider bindings update only the local preview. Gesture completion or an accessibility adjustment submits one full snapshot; choosing a preset or changing Auto commits immediately. Background entry and the app's Play/Pause action commit any remaining preview. There is no preparation or disk save for each drag sample. Existing native appearance and Dynamic Type behavior remain in use; simulator UI coverage is separate from device accessibility acceptance.

## Requested settings and musical application

The coordinator retains desired settings separately from applied settings. A positive monotonic revision identifies one complete request. Equal-revision/equal-value delivery is idempotent; a newer request supersedes older unaccepted work. Invalid non-finite values are rejected before entering preparation. Preview state is not overwritten by delayed rendered-song snapshots.

Queued means the latest request is waiting for preparation or an eligible boundary. Transitioning means the accepted transition boundary has begun and its rhythm handoff is still ahead. Applied settings follow the selected song at the shared rhythm handoff; preparing a candidate alone does not make it applied. A failed attempt retains the desired settings and exposes explicit Retry Changes. Controls retry is separate from retrying a failed settings save or playback startup. Editing, restore, retry, and background capture grant no autoplay permission, including while idle, paused, interrupted, or awaiting explicit recovery after a media-services reset.

The proposal uses a checkpoint from immediately before the current song was selected. Replaying this planning anchor preserves the selected song and its incoming transition while replacing the unplayed successor. Planning runs on a copy: failed, stale, or discarded proposals do not consume the accepted generator state or recent history. The earliest feasible eight-bar boundary must leave the physical-input damping lead, and the revised source must fit within the original prepared extent. A transition that cannot fit waits for a later eligible selection. Successful native acknowledgment precedes committed planning-history and placement changes.

## Native transaction and resource limits

An ordinary successor-preparation failure retains the same pending plan for Retry Next Song. A deterministic capacity failure cannot be corrected by repeatedly retrying that plan or editing controls while only one rack is admitted. Start a New Session is the explicit recovery: it discards the saved place, keeps the latest committed settings, atomically saves a settings-only record, and cancels the old remote registration. The app waits for the old coordinator to report both stopped and successful audio-session cleanup before installing a new silent lazy owner. Failed cleanup retains the old owner and exposes Retry Stopping Audio. The new owner starts only with a separate Play action. Pausing a latched preparation failure does not hide this recovery, and old observations or captures cannot restore the discarded place.

The outgoing bridge is prepared off the callback. Its event table preserves every live prefix index, including pending voice-steal indices; supplemental sample descriptors retain the original PCM references or copy validated note PCM into the unused tail of the current rack's fixed arena. Original tone/effect state and one measured gain remain continuous. Incompatible harmonic tails receive the existing 110 ms multiplicative damping before the pivot. The replacement song uses its newly planned controls.

The existing admission bounds remain: at most two prepared racks, 64 combined voice slots, 2,048 events and a 166-entry sample registry per rack, and 32 MiB of PCM arena per rack. Preparation scratch is bounded separately and does not represent a third song rack. The old unstarted successor, B, is withdrawn by the consumer and exclusively acknowledged to the worker before destruction. Only then can its replacement occupy the second rack. Revision/deadline checks run again before adoption. Accepted score storage remains retained through destruction of the first native borrower and mixer.

If replacement preparation fails or its publication becomes stale, the worker discards the candidate and restores original B, reusing it if it has not been destroyed or reconstructing it from the unchanged schedule otherwise. The original first rack, timeline, and accepted planning state remain in force. If preparation is late enough to reach original B's onset while B is absent, the render endpoint returns a bounded wait without consuming musical time. If rebuilding original B also fails, restoration remains latched for explicit retry. This can become audible waiting on a device; offline zero/short pulls must not be reported as successful real-time delivery. Retry and a later feasible boundary do not justify changing already rendered history. The callback neither allocates nor frees the proposal, scans a score, takes worker locks, performs I/O, nor prepares audio.

## Saved settings and migration

The app's version-2 `ListeningRecord` contains normalized committed controls and optional encoded `SessionRestartIntent` data. Its read/encode limit is 1,048,576 bytes. It can store settings before first Play, and its requested settings can differ from the selected rendered song stored in the restart. Captures merge only the musical restart into the newest committed settings. A single serial atomic replacement plus one coalesced pending record prevents an earlier capture or in-flight save from reverting a later user choice. Failed writes retain the latest record for explicit save retry without stopping music.

The nested package restart format is version 2, bounded to 524,288 bytes, with an optional planning anchor validated by replaying it and reproducing the captured checkpoint. Standalone package version-1 and version-2 files remain readable. They migrate to the app wrapper only on the next successful save; loading itself never overwrites the file. A legacy restart without an anchor preserves the selected song's original transition until a later anchored selection. Structural keys distinguish standalone restart data from app wrappers; a malformed wrapper missing controls or containing mixed wrapper/checkpoint fields is rejected. Invalid or unsupported files remain intact until a successful explicit fresh-session/settings save.

Restore remains silent. Saved data contains no PCM, active DSP state, queued Next or controls transaction, gesture preview, or autoplay flag. Restoring the musical position still warms a bounded song prefix and fades in on explicit Play, with the existing limitations for predecessor tails and old output-protector history. Atomic file replacement does not promise power-loss durability.

## Final validation record

The integrated app passed 40 simulator unit tests in seven suites and both UI flows, including settings persistence without starting playback. Recovery tests used real native preparation and an offline audio graph: failed cleanup retained the old owner, explicit Stop retry preceded silent replacement, and an ordinary successor failure remained recoverable after Pause. The isolated app candidate also passed dark appearance at the largest accessibility text size; light and dark screenshots were visually inspected. These simulator results do not establish physical-device or VoiceOver acceptance. Earlier playback evidence is recorded separately in [PR48 validation](validation-playback-integration.md).

| Final integrated evidence | Result |
| --- | --- |
| Toolchain | Xcode 26.6 (17F113), Swift 6.3.3, SwiftLint 0.65.1, clang-format 21 |
| Planner Debug and Release | 25 tests in four suites passed in each configuration |
| Audio Debug and Release | All 173 regular cases passed; final Release also discovers the disabled-by-default stress case (174 cases / 48 suites total) |
| Native optimized, ASan/UBSan, and TSan | Complete native DSP gate passed, including concurrent publication, rollback, lifetime, allocation, and floating-point checks |
| Focused Swift worker/coordinator TSan | 73 tests in 17 suites passed without sanitizer warnings |
| Integrated app and UI | 40 tests in seven suites and two UI flows passed |
| Reference audio | All 193 preserved exports byte-identical; all 14 original-reference comparisons passed |
| Repository, assets, formatting/lint, and CI guards | Passed, including 31 Python guard tests |
| Two-hour production-worker controls stress | Passed: 7,200 seconds / 230,400,000 stereo frames; full settings coverage and clean stop; measurements below |
| Representative transition audition | Five bit-preserving Float32 WAV excerpts verified against observed transitions; subjective listening pending |
| Unsigned arm64 Release app | 11,227,672 bytes total: 2,224,176 executable + 9,003,496 resources; within the 12 MiB budget |
| Equivalent merged-base comparison | Fresh PR48 build: 10,855,376 bytes; growth 372,296 bytes, within the existing growth allowance |
| Appearance and accessibility | Light/standard text and dark/largest text simulator flows passed and screenshots reviewed; physical-device and VoiceOver acceptance pending |

The engine checkpoint `d5463e9` passed the complete local gate, with Debug groups of 158, ten, and five tests. The final app checkpoint authenticated those receipts and verified every existing package source/test, native test, toolchain configuration, and sound-bank input remained unchanged. It retained that Debug/native/planner/TSan evidence, rebuilt the Debug test inventory, reran complete Release audio and reference comparisons, and ran the final app, UI, size, and repository gates. The new stress harness was compiled in both configurations, verified disabled without its opt-in environment, and separately passed the two-hour production-worker run below. Input manifests, command receipts, and logs remain outside version control.

CI now requires three complementary Debug jobs: core, controls transactions, and controls workers. The actual dispatcher arguments cover all 174 compiled test identifiers exactly once: 159, ten, and five respectively; the core count includes the opt-in stress case. The default local command and Release command still select the full suite. Test deadlines use monotonic clocks. Ownership fixtures reach ordinary retirement through real musical Next and bound consumer progress during preparation, retaining actual applied-handoff and endpoint-lifetime assertions.

Tests cover exact preset values and Custom matching, one commit per gesture, settings-only persistence, malformed/migrated records, coalesced-save races, silent restore, idle/paused changes, stale startup, suspension/reset/stop, explicit retry, burst supersession, natural versus early handoffs, immutable-prefix identity, original-B rollback, and late preparation waits. New-session recovery covers failed deactivation, a paused latched preparation error, preserved settings without autoplay, and old remote/capture/save work that cannot revive the discarded place. Two deterministic request/retry regressions reproduce their failures when the coherent mailbox snapshot fix is removed. A passing no-fault soak does not replace these controlled failure and race cases. The unsigned size measurement is a build proxy, not a signed/thinned download estimate.

## Reproducible offline controls stress

`SessionControlsStressTests.productionControlsSoak` exercised the production `SessionPreparationWorker`, its controls mailbox/snapshot, and its real native render endpoint. The final-source Release run on November 5, 2026 passed with this invocation from the repository root:

```sh
LOWLIGHT_CONTROLS_SOAK_SECONDS=7200 \
LOWLIGHT_CONTROLS_SOAK_ACCELERATION=8 \
LOWLIGHT_CONTROLS_SOAK_OUTPUT="$PWD/.build/controls-soak-final" \
xcrun swift test --configuration release \
  --package-path Packages/LowlightAudio \
  --scratch-path .build/ControlsCoordinator \
  --filter SessionControlsStressTests
```

The harness uses `ContinuousClock` for deadlines and elapsed-time measurement so host wall-clock corrections do not alter timeout behavior. The completed recipe is:

1. Start an ongoing worker with seed 1 and Focus. Produce exactly 230,400,000 stereo frames at 32 kHz with a reusable buffer and repeated pull sizes 1, 17, 256, 1,023, and 4,093. Truncate the final request to reach the target. Check every written sample for finiteness and accumulate peak/RMS without retaining a two-hour PCM array.
2. Submit 28 final snapshots at generated seconds 240, 480, and subsequent multiples of 240 through 6,720. Leave an eight-minute musical tail for the last request to finish. Repeat Relax, Commute, Workout, Reflective, Focus, then Custom. Custom starts from Focus, sets Energy 0.58, Mood 0.35, and manual Tempo 92, and uses Variation 0 on scheduled changes 6 and 18 and Variation 1 on changes 12 and 24. Before each even-numbered final change, submit superseded Tempo 60 and 100 revisions. Deliver every revision twice to exercise idempotence. Record the actual consumer frame at each submission; block sizes can place it slightly after the nominal scheduled second.
3. Request musical Next at generated second 120 and each subsequent 720-second interval, ten requests total. Request capture every generated second and after each observed selection change. At every fifth scheduled controls change, stop pulling, suspend preparation, wait for acknowledgment, submit the new settings while suspended, and resume the same worker. No audio restart or substituted renderer is used.
4. Count zero and short pulls separately. A zero pull does not advance generated time or append fabricated silence. Yield one millisecond after a zero pull and fail an uninterrupted no-progress interval exceeding 30 seconds of monotonic elapsed time. After successful pulls, sleep for their logical duration divided by eight; this explicit pacing allows preparation time and is not a maximum-throughput benchmark. Require the final desired and applied settings/revisions to agree, all intended settings and Next outcomes to appear, and terminal stop/join to complete without worker or controls errors.

| Completed soak result | Measurement |
| --- | --- |
| Logical duration / stereo frames | 7,200 seconds / 230,400,000 |
| Selections / Next outcomes / suspensions | 92 / 10 of 10 / 5 |
| Intended settings changes applied | 28 of 28 |
| Superseded revisions applied | 0 of 28 |
| Distinct applied settings | 7: all five presets and Custom at 92 BPM with Variation 0 and 1 |
| Final requested / applied revision and state | 57 / 57 / `none` |
| Zero pulls / short pulls / total pulls | 741 / 1 / 214,475 |
| Sample peak / RMS | 0.776304305 / 0.079563484 |
| Maximum process RSS | 105,054,208 bytes (100.1875 MiB) |
| Monotonic elapsed time, excluding initial preparation | 1,339.526887792 seconds |
| Total recorded command elapsed time, including compilation/preparation | 1,402.663 seconds |
| Source stability / process exit / worker cleanup | 498 recorded inputs unchanged / exit 0 / clean stop |

The 85 snapshot observations include queued, transitioning, and applied states for every final change. Request-to-applied observation delays ranged from 12.970250 to 65.766719 seconds of logical music time, with a median of 30.066375 seconds. These intervals include musical boundary waiting and do not measure wall-clock preparation latency. Observation frames record the consumer position when the worker's published snapshot changed; they are not instrumented sample-exact native handoff timestamps. The receipt contains no per-pull frame/time trace, so the aggregate waits cannot be assigned to individual excerpts or used to infer an exact missed deadline or later-selection deferral.

The retained `controls-soak.json` receipt SHA256 is `6607755c94f3c6147b6c040201cf0f40142ce0e12ae82617a0ac1920caf20d6f`. The command/source receipt SHA256 is `20d89e94b443bc8592a4f2b064927cf4aae07944cb1990a2e793dfaae225cb3f`; it records `inputs_unchanged=true` and exit 0. The tested `SessionControlsStressTests.swift` source SHA256 is `1f6d2c27613ee21987bb8729f099bb9109ead16ebf5f1dd2fcfd32fe713b639b`. All 150 production-source and sound-bank hashes also matched the final C3 integration tree; that comparison manifest SHA256 is `2c97917a6a2bac8bab02b2edae7507c6c8113379be37822a80935c7fa04bc2d1`. Generated audio, receipts, and their input-hash manifests remain outside version control.

This paced offline run establishes correctness and settings coverage through production DSP. Process-wide RSS is not an engine-only working-set measurement. It did not observe live rack/voice/PCM counters or establish hardware callback deadlines, energy use, thermal behavior, or continuous real-time delivery. Admission limits and failure/rollback interleavings remain the responsibility of their focused tests.

## Representative audition and device acceptance

Five 32 kHz stereo Float32 WAVs were converted from the soak's completed raw excerpts without gain changes. Each decoded WAV reproduces its source Float32LE bytes exactly, and every excerpt sample is finite. All windows contain their intended request, first observed transitioning state, and first observed applied state. The first excerpt begins with Focus; the other excerpts retain 60 seconds of context before their scheduled request and more than 145 seconds after observed application.

| Excerpt / global window | Revision and target | Request → transitioning → applied, seconds within clip | Peak / RMS |
| --- | --- | --- | --- |
| First 720 seconds / 0–720 s | 2, Relax | 240.023438 → 277.753438 → 284.154063 | 0.776304305 / 0.080954254 |
| Same first excerpt | 5, Commute | 480.046875 → 502.785937 → 509.524000 | Same file |
| Workout / 660–900 s | 6, Workout | 60.070312 → 74.050625 → 79.777500 | 0.776304305 / 0.079756520 |
| Manual Tempo / 1,380–1,620 s | 13, Custom, 92 BPM, Variation 0 | 60.012719 → 88.775000 → 94.670312 | 0.477282584 / 0.080587845 |
| Auto Tempo / 1,620–1,860 s | 14, Relax, Auto | 60.004188 → 79.029094 → 84.755938 | 0.605649471 / 0.078722703 |
| Variation / 2,820–3,060 s | 25, Custom, 92 BPM, Variation 1 | 60.112812 → 77.798750 → 83.694063 | 0.562390864 / 0.079824680 |

The complete raw/WAV hashes, exact observed frames, preceding/requested control snapshots, and conversion metadata are retained in `auditions-receipt.json`. WAV SHA256 values are:

| Excerpt | SHA256 |
| --- | --- |
| First 720 seconds | `4afcbe424e82da12f3c22ad9e51d36ea612b8592855a6fbee95689c4ac05c336` |
| Workout | `bb81ec077ba87ce17d0d9beed7a3fb0fcbfe0bfb0ffa4cbfd0932c11c2e6a6d2` |
| Manual Tempo | `449999f135371a9b34f9e0a4b4239a888fba19c822a398fbfe2607803c0e064d` |
| Auto Tempo | `9fd9b8fc9053aa8e6c7d2d4eebd5c36053e908912c1fe622e4a14b03a6750203` |
| Variation | `e9e90b72a32537624d313680ae94f1f990bed308e5f35ba5c9cb167e085092d9` |

Conversion used `ffmpeg -f f32le -ar 32000 -ac 2 -i INPUT -map 0:a:0 -c:a pcm_f32le -rf64 auto OUTPUT.wav`; decoding back to Float32LE verified the raw SHA256. These excerpts are the logical native stream: preparation waits were omitted rather than inserted as silence. They are not evidence of uninterrupted real-time playback. Manual/Auto Tempo and Variation excerpts change complete snapshots, including other controls, and do not isolate one control in an A/B experiment. The observations confirm excerpt coverage, not sample-exact native boundary timestamps or sound quality.

Subjective listening remains pending. Review the excerpts for clicks, accidental silence, abrupt level changes, incompatible sustained harmony, doubled/missing drums, discontinuous tempo, and audible corruption across the bridge. Record listening notes separately. Even a favorable audition does not establish complete-song parity, exhaustive preset quality, or device deadline/energy targets.

Physical-device acceptance remains open: verify VoiceOver adjustment and labels, large text and reachability, light/dark appearance, offline first launch, silent relaunch with settings-only and position records, foreground and locked-screen editing/playback, interruptions, remote commands, route changes, and actual media-services reset. Repeat two-hour signed Release listening/control soaks on the agreed older and current supported iPhones, recording route, OS, memory drift, glitches, thermal behavior, and energy against the matched local AAC baseline in [performance targets](performance.md). Individual live effect controls require their own smoothing, continuity, and resource evidence before expanding this scope.
