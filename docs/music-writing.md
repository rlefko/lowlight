# Songwriting and listening comparisons

The fixed PR 52 Focus opener spans 36 bars at 76.67 BPM. The lead plays on beats one and three in 27 bars and only on beat one in the other nine. Of 28 bars that have a predecessor eight bars earlier, 14 repeat both lead rhythm and pitches. Each of these observations comes from the native event fixture at seed 91,031.

## Listening protocol

Hold seeds, controls, sample rate, stereo layout, playback speed and start position fixed across revisions. The short comparisons play the first 105 seconds of Focus (91,031), Reflective (17), and Commute (509). A ten-minute Focus comparison includes the transitions between successive songs. A separate pair uses the new score with two different instrument palettes. Apply a constant gain to match loudness and check the encoded files before listening. Listen in a concealed order on one device at a fixed volume. Record which track you would keep playing, when you anticipated a repeating passage, and any entrances that felt distracting.

To capture source PCM and a score audit with the pinned native toolchain:

```sh
python3 -B tools/auditions/writing.py .build/writing-capture
```

The opt-in capture uses the production continuous renderer. It records 600 seconds of Focus and 120 seconds each of Reflective and Commute before any editing or level matching. Audio stays in the ignored build directory. The score audit covers all five presets, four fixed seeds (91,031, 17, 509, 8,731) and sixteen successive pieces in each session. It counts lead rhythms on a sixteenth-note grid, exact eight-bar lead and bass returns, silent lead bars and instrument entrances following a full bar of rest. Empty passages contribute to the rest count. These statistics help locate listening examples. Preference comes from the audition.

The [frozen PR 52 capture](../tests/fixtures/music-writing-v1/capture.json) records the PCM and score SHA-256 values and per-preset counts on arm64 macOS. The full ten-minute Focus capture also matched the first ten minutes of the independently retained PR 52 comparison PCM byte for byte.
