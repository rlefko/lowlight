# The native listening experience

The main screen puts Play/Pause, Next, presets, Warmth, Energy, and Mood beneath a dusk horizon. More Controls opens a native sheet with Tempo, Space, Texture, and Variation. The transport reports preparation and playback separately. Returning to a saved session leaves Play available until you choose to listen. The [light screen](images/listening-light.png) shows Focus before Play. The [dark screen](images/listening-dark.png) shows Reflective playing. Both were captured from the same Release build on an iPhone 17 Pro simulator.

## Artwork and musical time

The [editable vector master](../tools/artwork/DuskHorizon.svg) supplies the default, dark, and tinted app icons and a square Now Playing poster. On macOS, run `python3 tools/artwork/render.py` with Pillow installed to regenerate the catalog. All four images reproduced byte for byte on the development host. The compiled catalog contained all three 1,024-pixel icon renditions and the 512-pixel poster. The default icon was inspected on the simulator Home Screen. A metadata test requests a 64-point thumbnail and checks that transport updates reuse the artwork.

The Canvas draws a sun, two ridges, and fine contour lines. The selected piece supplies the seed, tempo, and a canonical frame at 32 kHz. A monotonic clock advances the visual phase between playback updates, completing one cycle every four bars. Only the artwork schedules updates. Showing it again samples the current phase directly.

## Accessibility and visibility

The controls test edits all seven settings and checks their values after a silent relaunch. The home screen and controls sheet undergo XCTest audits for contrast, hit regions, descriptions, clipping, and Dynamic Type. The sheet audit checks contrast on first presentation, before running the other audit types and before Auto Tempo replaces its rows. Interaction tests then verify the tempo changes and restored values. At rest the audit permits UIKit to dim only the disabled Next button. A separate Release audit exercises the enabled transport during actual playback with all five checks. A deliberately unreadable saved record brought up Try Restoring Again and Start a Fresh Session. Retrying preserved the recovery choices. Starting fresh returned to Ready to play without starting audio. On the dark iPhone SE simulator, changing the retry label to the system background color raised its measured screenshot contrast from 1.94:1 to 10.85:1 against the lavender button.

On the iPhone 17e at standard text size and the 375 × 667-point iPhone SE (3rd generation) at the largest accessibility size, the tests reached the controls, changed their values, and restored them. The status and transport reflow in portrait, and the landscape screen keeps the transport reachable above the scrollable controls. The artwork is decorative and contributes no VoiceOver element.

Run the visibility probe to capture both the application’s scheduler ticks and actual Canvas draws. It checks the current gate and playback state in each settled three-second window. The background check also compares the generated frame positions reported on entry and return.

```sh
python3 -B tools/visuals/measure.py --visibility .build/horizon-visibility
```

| Playback window | Scheduler ticks | Canvas draws | Seconds |
| --- | ---: | ---: | ---: |
| Playing | 43 | 43 | 3.009 |
| About sheet | 0 | 0 | 3.009 |
| About dismissed | 43 | 42 | 3.001 |
| More Controls sheet | 0 | 0 | 3.004 |
| Artwork scrolled away | 0 | 0 | 3.010 |
| Artwork visible again | 42 | 42 | 3.010 |
| Home Screen | 0 | 0 | 3.008 |
| App active again | 43 | 43 | 3.003 |
| Paused | 0 | 0 | 3.002 |
| Low Power Mode input | 0 | 0 | 3.008 |
| Reduce Motion input | 0 | 0 | 3.009 |
| Static comparison | 0 | 0 | 3.002 |

The selected piece advanced from frame 1,134,252 to 1,290,582 while the app crossed the Home Screen, or 4.885 seconds of audio in 4.888 seconds on the clock. The hidden and paused windows exclude the initial transition and any one-time redraw. The two accessibility/power inputs were forced individually on the simulator. Production reads the system settings.

## Foreground cost

```sh
python3 -B tools/visuals/measure.py .build/horizon-measurements
```

These runs used an Apple M4 Max with 16 logical CPUs, macOS 26.6, Xcode 26.6 (17F113), and an iPhone 17 simulator running iOS 26.5. The script creates a fresh simulator with the pinned runtime. Each trial uses the same optimized app, the default seed 91,031, a clean installation, and the same preset. The static condition disables the visual schedule and keeps the horizon on screen. XCTest waits for Playing, warms up for 30 seconds, and records a second 30-second window. App-process CPU and peak physical memory come from XCTest. One log event records each gate transition. The harness verifies that the chosen mode held throughout the warmup and measured interval. Per-frame logging is disabled during these trials. Each installation starts the same first piece. Detection of the Playing label can vary slightly across trials.

| Pair | Order | Horizon | Clock (s) | App CPU (s) | One core (%) | Peak physical memory (MB) |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 1 | 1 | Animated | 29.530 | 3.421 | 11.58 | 105.34 |
| 1 | 2 | Static | 29.528 | 1.966 | 6.66 | 105.35 |
| 2 | 3 | Static | 29.521 | 1.995 | 6.76 | 105.20 |
| 2 | 4 | Animated | 29.522 | 3.459 | 11.72 | 105.45 |
| 3 | 5 | Animated | 29.528 | 2.889 | 9.78 | 105.24 |
| 3 | 6 | Static | 29.528 | 1.790 | 6.06 | 105.24 |

Across the three pairs, motion changed app CPU by a median +4.93 percentage points of one core (range +3.72 to +4.96). The median paired change in peak physical memory was +0.00 MB (range -0.02 to +0.25). CPU is normalized to each trial’s measured clock. Memory uses decimal MB. These short simulator observations exclude the system compositor and GPU, and do not establish energy use on an iPhone.

## Bundle size

The clean unsigned arm64 Release build totals **11,937,459 bytes** (11.38 MiB). The executable occupies 2,621,320 bytes and resources occupy 9,316,139 bytes. That is 570,077 bytes above the fresh PR 50 build of 11,367,382 bytes, within the 12,582,912-byte absolute budget. The incremental local gate measured 11,937,139 bytes with the same resource total. Screenshots and the editable SVG live outside the app bundle.

## Release acceptance

Physical iPhones are still needed for VoiceOver reading order and announcements, lock-screen artwork on real routes, minimum-OS behavior, and matched generator/AAC/idle energy trials. Simulator measurements describe the foreground app process on the development Mac. The [device protocol](performance.md) covers battery and thermal behavior.
