# Songwriting and listening comparisons

The fixed PR 52 Focus opener spans 36 bars at 76.67 BPM. The lead plays on beats one and three in 27 bars and only on beat one in the other nine. Of 28 bars that have a predecessor eight bars earlier, 14 repeat both lead rhythm and pitches. Each of these observations comes from the native event fixture at seed 91,031.

## Listening protocol

Hold seeds, controls, sample rate, stereo layout, playback speed and start position fixed across revisions. The short comparisons play the first 105 seconds of Focus (91,031), Reflective (17), and Commute (509). A ten-minute Focus comparison includes the transitions between successive songs. A separate pair uses the new score with two different instrument palettes. Apply a constant gain to match loudness and check the encoded files before listening. Listen in a concealed order on one device at a fixed volume. Record which track you would keep playing, when you anticipated a repeating passage, and any entrances that felt distracting.

To reproduce the original source PCM and score audit with the pinned native toolchain:

```sh
python3 -B tools/auditions/writing.py --classic .build/writing-capture
```

The opt-in capture uses the production continuous renderer. It records 600 seconds of Focus and 120 seconds each of Reflective and Commute before any editing or level matching. Audio stays in the ignored build directory. The score audit covers all five presets, four fixed seeds (91,031, 17, 509, 8,731) and sixteen successive pieces in each session. It counts lead rhythms on a sixteenth-note grid, exact eight-bar lead and bass returns, silent lead bars and instrument entrances following a full bar of rest. Empty passages contribute to the rest count. These statistics help locate listening examples. Preference comes from the audition.

The [frozen PR 52 capture](../tests/fixtures/music-writing-v1/capture.json) records the PCM and score SHA-256 values and per-preset counts on arm64 macOS. The full ten-minute Focus capture also matched the first ten minutes of the independently retained PR 52 comparison PCM byte for byte.

## Writing choices

An eight-bar theme with a four-bar literal return gives the listener a reference point for hearing the changed ending. Theme-conditioned generation research tested the musical value of a recognizable theme returning in different forms. Lowlight implements that idea with seeded phrase and section rules. [Shih et al., Theme Transformer](https://arxiv.org/abs/2111.04093)

The bass and kick sometimes meet on the same beat and sometimes answer one another. The lead, hats and comping can enter offbeat while a clear backbeat remains audible. Experiments with polyphonic rhythms found that the distribution of syncopation across parts influenced groove ratings. That informed where the variations go and why longer rests are part of the arrangement. [Sioros et al., Syncopation and Groove in Polyphonic Music](https://online.ucpress.edu/mp/article/39/5/503/182325/Syncopation-and-Groove-in-Polyphonic-MusicPatterns)

The blind comparison asks when a listener anticipates the repeat and which version they would leave playing. In a study using repeating instrumental music, staggered instrument entrances had the largest effect on listening time, and enjoyment best predicted when participants stopped. Lowlight varies who enters and who rests as the theme develops. The score counts below describe how the music changed. The listening decision belongs to the listener. [Janata et al., Psychological and Musical Factors Underlying Engagement with Unfamiliar Music](https://doi.org/10.1525/mp.2018.36.2.175)

## Reproduce the listening comparison

With the pinned Xcode toolchain, Apple AudioToolbox and FFmpeg available, capture both versions from this checkout. The final engine in classic mode reproduced the three PR 52 source files (14 minutes total) and the 320-piece score audit byte for byte on arm64 macOS.

```sh
python3 -B tools/auditions/writing.py --classic .build/writing-classic
python3 -B tools/auditions/writing.py .build/writing-evolving
python3 -B tools/auditions/listening.py .build/writing-classic .build/writing-evolving .build/listening
open .build/listening/index.html
```

The first three pairs compare the first 105 seconds from each seed. The fourth contains both uninterrupted ten-minute Focus sessions. The fifth plays the same 105 seconds of the new Focus score through the original instruments and the expanded band. Timings, pitches, controls and other players in this last pair come from the same score. Each file gets one constant gain adjustment. The encoder verifies gapless 32 kHz stereo duration, integrated loudness and true peak on the decoded previews. The page conceals the order and switches between recordings at the same point. Open `answer-key.json` after listening to see identities, gains, levels and file hashes.

## What changed in the score

Each row covers four fixed seeds and sixteen successive pieces per seed. A rhythm is the set of sixteenth-note attack positions in a nonempty bar of the lead part. An exact return counts both those attack positions and pitches against the bar eight bars earlier. A returning phrase can span a different interval. An answering instrument can still be playing when the lead rests.

| Preset | Median distinct rhythms per piece, old → new | Exact eight-bar returns / eligible bars, old → new |
| --- | ---: | ---: |
| Focus | 2 → 7 | 646/1,760 → 90/1,816 |
| Relax | 2 → 7 | 870/1,752 → 78/1,784 |
| Commute | 3 → 8 | 563/1,672 → 90/1,816 |
| Workout | 4 → 8 | 543/1,640 → 89/1,816 |
| Reflective | 2 → 7 | 657/1,760 → 84/1,808 |

All 320 new scores recalled the first four bars of their theme in the reprise and changed its ending. The electric-piano, mallet and reed ensembles appeared in 106, 109 and 105 selections respectively. The 11,600 bars included 2,537 in which both lead and answer rested. In the longer forms, one quiet guide tone carries the second bar of the breakdown while the rhythm section rests. The longest gap between the end of a note's written release and the next attack was 0.86 seconds. Recorded decays and the shared room also affect what the listener hears.

Native preparation admitted every one of the 320 scores. The largest individual rack used 15,529,692 bytes of prepared PCM. The largest adjacent pair used 27,405,292 bytes and the highest combined voice reservation was 27 of 64. Slots and decoded PCM depend on the score and the two neighboring selections.

The [expanded score and source PCM fingerprints](../tests/fixtures/music-writing-v2/capture.json) record every preset. Across five decoded audition pairs the greatest within-pair difference was 0.01 LU, and the loudest measured true peak was −4.99 dBTP. Two legacy restores, one in the body and one four beats into the outgoing crossfade, each reproduced the next 65,536 stereo frames of the PR 52 engine byte for byte.

## Playback measurements

The production Focus renderer ran for ten minutes per trial on arm64 macOS with 256-frame pulls (8 ms). Three runs per edition alternated in the order classic, evolving, evolving, classic, classic, evolving. The first 16,384 frames were excluded from timing. The table gives median per-pull thread CPU across the three trial means and the worst per-trial wall percentile. Preparation ran on the control side and was timed separately.

| Edition | Mean thread CPU (µs) | Worst p99 / p99.9 wall (µs) | First pair, median seconds | Successor, median seconds | Peak prepared PCM / reserved voices |
| --- | ---: | ---: | ---: | ---: | ---: |
| Classic | 53.7 | 93.5 / 105.8 | 1.74 | 1.01 | 56,947,548 B / 28 |
| Evolving | 46.5 | 82.8 / 98.9 | 1.43 | 0.79 | 22,617,244 B / 20 |

Each timing run completed 19,200,000 frames with zero dropped events and zero stolen voices. Host wall percentiles depend on scheduler load. During a separate run alongside native and simulator builds the worst p99.9 was 13.44 ms for classic and 10.09 ms for evolving. Physical callback latency, energy, memory drift and warm Play time require the on-device trial.

The unsigned arm64 Release app measured 14,160,243 bytes (2,755,880 executable and 11,404,363 resources), compared with 11,941,739 bytes from the PR 52 base. The 28 FLAC files and manifest added 2,088,224 resource bytes. The app budget is 50,000,000 bytes.

The two-hour accelerated acceptance run covers 230,400,000 stereo frames. Its gate requires all 28 planned controls changes to settle, all five presets and both fixed-tempo Variation extremes to occur, every accepted Next request to change the selection, and all 240 live-effect cycles to finish. The worker must stop cleanly with finite output and the final setting applied. The receipt includes peak and RMS, explicit preparation waits, and host process high-water memory. A preliminary run revealed an issue in the test schedule: after a slow handoff, the final controls request fell just inside an eight-minute window reserved for draining. The runner now lets an already-planned request use that window. It slows the accelerated consumer while a revision is pending so the worker can prepare an eligible phrase, including for the last edit. Every revision must still settle.

Run the opt-in Release measurements from the checkout root. The soak writes a JSON receipt and bounded excerpts below the selected output directory.

```sh
mkdir -p .build/writing-validation
LOWLIGHT_WRITING_TIMING="$PWD/.build/writing-validation/timing.json" \
  xcrun swift test -c release --package-path Packages/LowlightAudio \
  --scratch-path .build/WritingAudio --filter WritingPlaybackEvidenceTests/measureWriting
LOWLIGHT_CONTROLS_SOAK_EDITION=2 LOWLIGHT_CONTROLS_SOAK_SECONDS=7200 \
  LOWLIGHT_CONTROLS_SOAK_ACCELERATION=64 LOWLIGHT_CONTROLS_SOAK_OUTPUT="$PWD/.build/writing-validation/soak" \
  xcrun swift test -c release --package-path Packages/LowlightAudio \
  --scratch-path .build/WritingAudio --filter SessionControlsStressTests/productionControlsSoak
```
