# Frozen dry percussion

`percussion-prefix.flac` renders 13 seconds from 36 unchanged accepted percussion note-ons before 12 seconds in the [v9 score](../v9/events.json). It includes kicks, closed hats, and stick/rim hits (`snare`, note 1), with both recorded takes, overlapping tails, and exact silence from frame 392,079. Six prepared mono bodies occupy 345,600 bytes. The accepted first song contains no shaker events.

`percussion-controls.flac` renders a separate five-second **synthetic test score**, not additional accepted composition. Its 20 events cover all 12 supported bodies, velocity 0/1, the Double hat-layer boundary 0.71999999/0.72 and the Float32-aliasing pair 0.719999999/0.72, pan extremes, ghost-hit velocity, wrapped round robins, one-frame versus 16-second gates, zero/five-second releases, and soft/connected articulation. Its silence begins at frame 126,400. All 12 bodies occupy 441,152 bytes. Swift also renders the same score with only gate/release/articulation and valid warmth changed and requires identical output.

Both clip oracles call the unchanged `instruments.add_note` function. Prepared-body comparisons use unchanged `instruments.pitched` plus its original fixed closed-hat/snare decay operations. Kick preparation includes the deterministic sine/recording hybrid; no per-hit noise generator exists. Stick/rim, closed hats, and shaker use recorded sources. Duration/release/articulation do not alter these one-shots. Open hats and normal snare hits are dormant reference branches outside the supported event contract.

Twelve manifest cases cover two kicks, two stick hits, two takes at each of two closed-hat layers, and four shaker takes. Every full mono body is verified in CI; no additional full body recordings are tracked. Float32 hashes and peak/RMS values record provenance rather than requiring cross-platform hash equality. Two independent PCM24 clips provide local waveform gates, with full-precision original output checked against native output in CI. Predeclared limits are maximum absolute error ≤ `1e-5` and RMS error ≤ `1e-6`; PCM24 quantization contributes at most about `1.2e-7`.

```sh
.tools/reference/bin/python tools/reference/verify-percussion.py --integrity
.tools/reference/bin/python tools/reference/verify-percussion.py
.tools/reference/bin/python tools/reference/verify-percussion.py \
  --compare .build/tonal-native/percussion --evidence .build/tonal-evidence/percussion
```

Candidates must contain exactly 14 little-endian Float32 files: `percussion-prefix.f32` (416,000 stereo frames), `percussion-controls.f32` (160,000 stereo frames), and the 12 mono body filenames/dimensions in the manifest. Verification checks all samples, dimensions, finite output, and exact tail silence. Evidence includes full aligned WAV pairs, hashes, errors, dry loudness, and four-times oversampled peaks, without level correction. Accepted event velocities retain the planner's energy response. Later bus filters/gains and their energy factors, shared ducking, rack fades, room, and mastering are excluded; dry levels are not full-mix targets or limiter evidence.

The separate [generator](../../../tools/reference/freeze-percussion.py) refuses implicit replacement and is never called by CI. Regeneration requires explicit fixture review and must not accommodate native regressions. Existing [v9 provenance](../../../tools/reference/provenance.json), [bank notices](../../../docs/sound-bank.md), and CC0 percussion assets remain unchanged. These developer fixtures are never bundled in the app.
