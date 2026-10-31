# Frozen bass voices

The fixture copies six unchanged bass events with onset before 12 seconds from the accepted [v9 score](../v9/events.json), then renders 13 seconds including their tails. Its independent oracle calls the original `render_room.bass_voice` and `place` functions. It includes no bass bus gain, ducking, room, or mastering, and uses neither the older `instruments.bass_voice` nor `add_note` path.

Five distinct prepared mono bodies occupy 1,459,884 bytes. The prefix covers all four reachable sample roots, both recorded takes, transposition in both directions, repeated pitches, short/long notes, and synthesis continuing after the recording ends. The accepted events have already undergone the planner's monophonic damping. They do not overlap, and the rendered tail ends at frame 385,743. The voice ignores warmth, pan, and articulation and produces identical left/right channels.

The 54 manifest cases cover every supported MIDI note 31–57 and both takes. Each independent prepared body follows `instruments.pitched('bass', note, 1, rr)`, mono averaging, the original second-order 180 Hz high-pass and 650 Hz low-pass, then Float32 multiplication by 0.08. `pitched` includes nearest-root/take selection, rational resampling, and its second-order 1800 Hz low-pass. Manifest order resolves ties: note 31 selects root 34, note 36 selects 34, and note 41 selects 38. Raw Float32 hashes and peak/RMS values record provenance; platform-independent verification compares every native sample within the declared tolerances rather than requiring identical floating-point hashes.

The native event model rounds absolute onset/gate/release endpoints, while the original bass voice rounds relative hold and combined duration/release. These six events have identical rounded endpoints; the manifest records the independently measured zero waveform difference. The frozen oracle retains the original durations. Maximum absolute error ≤ `1e-5` and RMS error ≤ `1e-6` are fixed before native comparison. PCM24 quantization contributes at most about `1.2e-7`; CI also compares full native Float32 arrays with freshly rendered original arrays.

```sh
.tools/reference/bin/python tools/reference/verify-bass.py --integrity
.tools/reference/bin/python tools/reference/verify-bass.py
.tools/reference/bin/python tools/reference/verify-bass.py \
  --compare .build/tonal-native/bass --evidence .build/tonal-evidence/bass
```

Native candidates are little-endian Float32: `bass-prefix.f32` contains exactly 416,000 interleaved stereo frames; `body-31-0.f32` through `body-57-1.f32` contain the full mono bodies declared in the manifest. Verification requires the exact 55-file set, dimensions, finite samples, centered output, and exact final silence. Evidence includes aligned full-length reference/native WAV files, hashes, dry loudness/peak measurements, and every case's errors, without hidden gain correction. Dry levels and four-times oversampled peaks are not full-mix targets or a limiter guarantee.

The separate [generator](../../../tools/reference/freeze-bass.py) refuses implicit replacement and is never called by CI. Regeneration requires explicit fixture review and must not accommodate a native regression. Source and samples retain the existing [v9 provenance](../../../tools/reference/provenance.json) and [bank notices](../../../docs/sound-bank.md). These fixtures are developer resources and are never bundled in the app.
