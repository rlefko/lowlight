# Compare generator, local AAC, and idle on an iPhone

Use this procedure to measure the extra battery use of generating music compared with playing a local recording of the same performance. Run all nine trials on each phone. Budget at least 5 hours 15 minutes per phone for warmup and measurement, plus setup and cooldown. The simulator rehearsal exercises both playback paths and checks their frame counters. The hardware results, two-hour soaks, and release decision are still open.

## Prepare one build and one recording

From a clean checkout, run `scripts/setup` and `tools/reference/setup` with the project's pinned Python. The reference is a continuous Focus session starting at seed 91,031, rendered through the production session and song transitions at 32,000 stereo frames per second. Both playback arms start at frame zero. The native transport admits each prepared successor as playback crosses a song boundary. Retain the checkout SHA, the generated manifest, and the exact AAC used on both phones. Preparing another copy can change its container digest.

```sh
python3 -B tools/playback-comparison/trials.py prepare .build/comparison/short --seconds 45
python3 -B tools/playback-comparison/trials.py rehearse .build/comparison/short .build/comparison/rehearsal
python3 -B tools/playback-comparison/trials.py prepare .build/comparison/phone --seconds 2400
python3 -B tools/playback-comparison/fixture.py verify .build/comparison/phone
```

The fixture and each in-app snapshot name the score and bank recipe (`evolving-2.band-1`). Regenerate and stage a new AAC when that recipe changes. Legacy recordings still identify the earlier experiment.

The default export covers exactly 35 minutes. The 40-minute command above leaves time to lock the screen, align the measured window in the trace, and capture the endpoint before AAC runs out. Reserve about 1.5 GiB of temporary space for a 35-minute encode and decode, in addition to build products. Keep generated audio and device evidence in an ignored directory. The staging command copies the manifest and compressed AAC to the profile app’s data container.

Select **Lowlight Playback Comparison** in Xcode. It builds the Lowlight target with optimizations and the separate identifier `com.rlefko.lowlight.profile`. For a physical trial, install a development-signed build on the intended phone using an authorized local team and provisioning profile. Use the same installed executable for every arm on a phone. Record its SHA-256 with `shasum -a 256 path/to/Lowlight.app/Lowlight`, the full commit with `git rev-parse HEAD`, and the fixture's `aac_sha256`. After installing, open the profile app once to create its data directory and exit. Set the shell variable `phone` to the explicit development device identifier. Stage the verified fixture and retain a copy of its manifest with each record.

```sh
python3 -B tools/playback-comparison/trials.py stage .build/comparison/phone --device "$phone"
mkdir -p .build/comparison/older .build/comparison/current
cp .build/comparison/phone/manifest.json .build/comparison/older/
cp .build/comparison/phone/manifest.json .build/comparison/current/
python3 -B tools/playback-comparison/trials.py template .build/comparison/older/record.json --role older
python3 -B tools/playback-comparison/trials.py template .build/comparison/current/record.json --role current
```

## Capture one phone at a time

Choose an older supported iPhone and a current iPhone. Power Profiler requires iOS 26 or later. Keep functional coverage on earlier supported iOS versions in the device test matrix. In Settings → Developer → Performance Trace, enable Power Profiler, include the comparison app, and add Performance Trace to Control Center. After recording, share the original trace from Settings and open the expanded recording in Instruments. Use the overall system battery consumption per hour. Charging changes this reading to zero, and an active Xcode connection can keep the processor awake. [Apple’s Power Profiler instructions](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)

| Block | First | Second | Third |
| --- | --- | --- | --- |
| 1 | Generator | AAC | Idle |
| 2 | AAC | Idle | Generator |
| 3 | Idle | Generator | AAC |

1. Restore the same audio route, audible system volume, Low Power Mode setting, screen setup, and background workload. Allow the phone to cool to nominal thermal state. Use the same OS build throughout a phone's sequence. Record an anonymous device alias and the model. Use a separate row and a new UUID for each launch.
2. With the phone unlocked, launch the app in the chosen mode. The command below selects generator. Use `aac` and `idle` for their rows. Disconnect the Mac, charger, and debugger before collecting the window. Start the on-device trace, return to the comparison screen, tap Start, wait for Playing (Running for idle), and lock the screen. Record the warmup start after that transition and lock.
3. Allow at least five uninterrupted warmup minutes. Record a subsequent window of at least 30 uninterrupted minutes with the screen locked. Use the same passage and duration in every arm. For example, start the trace window 360 seconds after each acknowledged start and select exactly 1,800 seconds. The report allows a five-second spread across all nine offsets and all nine durations. Keep the route, volume, thermal state, and charging state fixed. Avoid pausing or refreshing during the window. If the route drops, a call interrupts playback, the app fails, or a phone heats up, retain the failed record and repeat the trial from a fresh launch.
4. After the measured window, unlock, tap Refresh while the trial is still active, then end the trace from Control Center. Collect the two JSON snapshots before relaunching or replacing the final snapshot. Record offset-aware timestamps from the trace and snapshots. Retain the original shared `.aar` archive, its SHA-256, and the corresponding snapshots alongside the phone's record. Tap Stop after retrieving the snapshots.
5. In Instruments, select the exact measured interval and record its whole-system rate (`fraction_per_hour` or `percentage_points_per_hour`) and a positive absolute uncertainty in that same unit. Set `metric` to `whole_system_battery_drain`, and `capture` to `on_device_power_profiler`. Enter `locked`, `unplugged`, and `nominal` only when the trace supports those conditions. Record how you obtained the uncertainty (for example, the resolution and variability of the interval readings). Include the observed thermal, charging, and display conditions throughout. If a reading, unit, uncertainty, or trace is unavailable, leave the trial incomplete.

```sh
trial=$(uuidgen)
DEVICECTL_CHILD_LOWLIGHT_COMPARISON_MODE=generator \
DEVICECTL_CHILD_LOWLIGHT_COMPARISON_TRIAL_ID="$trial" \
  xcrun devicectl device process launch --device "$phone" --terminate-existing com.rlefko.lowlight.profile
```

After ending the selected window, reconnect and copy its snapshots before Stop or the next launch. For the first row on the older phone, run the following command. Copy the shared archive into the same directory and enter its relative path and SHA-256 in that row.

```sh
python3 -B tools/playback-comparison/trials.py collect .build/comparison/older --device "$phone" --block 1 --mode generator
```

The generator and AAC use the same playback audio-session policy. Idle uses the same static screen with zero rendered frames and creates no audio session or engine. Read the generator's render position and the AAC player's elapsed position at the endpoints. These counters show transport progression. Both snapshots identify the installed executable, platform, and trial UUID. A pause/resume increments the start count and disqualifies the run. The report checks the trace digest and uses the operator’s transcription of its interval and readings. Measuring acoustic latency needs a physical output observation.

## Interpret the report

```sh
python3 -B tools/playback-comparison/trials.py report .build/comparison/older/record.json
python3 -B tools/playback-comparison/trials.py report .build/comparison/current/record.json
```

Review each phone separately. Compare the three absolute measurements within each block, then subtract that block's idle rate from both playback rates. The relative comparison uses the local AAC cost above idle as its denominator. A denominator close to zero can make a tiny battery difference look large. The report combines per-reading uncertainty with the observed spread of the three blocks. It withholds a ratio if the AAC cost above idle cannot be resolved within 10% of its median or the paired difference cannot be resolved within 10 percentage points. Keep the absolute readings, uncertainty, and block spread with every reported percentage. Interpret the project’s roughly 10% target only when the measurements can resolve a difference that small.

## Evolving score and band reference

The current Focus comparison uses the `evolving-2.band-1` recipe. Two independent continuous renders of the 35-minute passage produced identical PCM. A separate 45-second export matched its prefix byte for byte. Core Audio decoded each AAC to the source frame count.

| Passage | Stereo frames at 32 kHz | Native LUFS | Decoded AAC LUFS | Native / decoded sample peak |
| --- | ---: | ---: | ---: | ---: |
| 45 seconds | 1,440,000 | -21.2153 | -21.2182 | 0.562388 / 0.567760 |
| 35 minutes | 67,200,000 | -20.6994 | -20.7015 | 0.562391 / 0.567760 |

The 35-minute source PCM SHA-256 is `bef25d8f7b106a6c2c2641629df14b11aee0f1796087dbfc6bb20bd13a3fee11`. The rehearsed 27,317,786-byte AAC has SHA-256 `e43add6b4901cd95a6fdaa3a692577aa29f0accbb4d9ab9ff0932357461605f9`.

On the pinned iPhone 17 simulator, all seven comparison tests passed with zero skips. Generator and AAC advanced, paused, resumed, stopped, and relaunched at frame zero. Idle held at zero. The profile rejected missing audio, damaged audio, an invalid mode, and a PR 52 manifest with an intact AAC. The final rejection exercised the performance recipe check. Physical energy comparisons still require matched device trials.

## PR 52 baseline evidence

With Xcode 26.6 (17F113) and Swift 6.3.3 on Apple Silicon, two native renders of the 2,100-second reference produced the same 537,600,000-byte interleaved Float32 source. The locally retained reference has the following measurements.

| Reference | Result |
| --- | --- |
| Source and gapless decoded length | 67,200,000 stereo frames each at 32 kHz |
| Source / decoded integrated loudness | −20.5707 / −20.5735 LUFS (0.0027 LU difference) |
| Source / decoded sample peak | 0.670614 / 0.667889 |
| AAC file size | 26,978,859 bytes |
| Source PCM SHA-256 | `ab61c454419487fb4d0304481485be5f19f11bf20de0ab4469efcc34a25cd6df` |
| This AAC SHA-256 | `80a14cfcaf320db26afdd87b62707a797241d1028dc98db8342f9ec87462b9aa` |

These measurements describe the original PR 52 performance. The current rehearsal adds a seventh case that rejects an older recipe with otherwise valid AAC.

The short repeat check (`fixture.py smoke .build/comparison/repeat`) also produced identical native PCM across two fresh 12-second sessions. The verifier rejected modified AAC bytes and a manifest with a 1 LU discrepancy.

On the pinned iPhone 17 simulator (iOS 26.5), the six-case rehearsal used the full AAC. The following frames came from explicit refreshes during the short transport test. Both playback counters advanced, held steady across a pause and after Stop, and returned to zero on relaunch.

| Arm | First sample | Second sample | Paused | Resumed | Stopped |
| --- | ---: | ---: | ---: | ---: | ---: |
| Generator | 4,779 | 56,662 | 75,094 | 160,769 | 179,200 |
| AAC | 48,203 | 99,408 | 118,051 | 204,721 | 223,368 |
| Idle | 0 | — | — | — | 0 |

Missing and corrupted AAC and an unknown launch mode each produced a visible failure with zero frames. The runner checked the XCTest case identifiers and counted six passes with zero skips. The shorter 45-second fixture also passed the same rehearsal. The report returned `inconclusive` for an empty physical campaign. Its synthetic regression cases exercise mismatched devices, simulator receipts, stale executables, interrupted playback, mismatched passages, and an unresolved AAC baseline.

The unsigned arm64 Release app measured **11,941,491 bytes**, including 9,316,139 resource bytes, versus 11,938,875 bytes on merged PR 51 (+2,616 bytes). All 96 resource paths matched. The compiled asset catalog differed only in its recorded build timestamp when inspected with `assetutil --info`. All five asset renditions matched. The separate profile binary contained the mode and trial selectors and the AAC filename. The shipping binary excluded all three strings, and neither app bundled generated audio. The normal Release launch test supplied the comparison environment variable, reached the listening screen, and exercised Play, Pause, and About.

To repeat the size check, build unsigned Release in this checkout and the PR 51 merge (`acc27083bfb6295ecdf1e95918552715b3fac34a`) with `scripts/build release`, then pass the two `Release-iphoneos/Lowlight.app` paths and the base SHA to `scripts/size-report`. The generic arm64 profile build uses:

```sh
xcodebuild -project Lowlight.xcodeproj -scheme 'Lowlight Playback Comparison' \
  -configuration PlaybackComparison -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ProfileDevice ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

## Remaining physical checks

Record warm Play to first audible output on the oldest agreed phone and Pause to silence with route latency identified. Collect callback p99/p99.9, underruns, working set, and foreground/background memory. Run separate two-hour locked-screen and foreground/control soaks on the candidate, including post-warmup memory drift. Exercise route changes and interruptions, confirm offline first launch, and review appearance and accessibility on hardware. Use a separately authorized distribution build for thinned download size. Target thresholds and remaining release decisions are in [performance and size](performance.md) and [milestone status](status.md).
