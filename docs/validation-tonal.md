# Native tonal sample preparation

`LowlightAudio` prepares the accepted guitar and piano recordings at 32 kHz, off the audio callback. This is the first part of milestone 4. It returns owned interleaved Float32 PCM before note envelopes, velocity, panning, mixing, or effects. The app links the package, but does not start playback or prepare notes at launch.

## Reference behavior

The implementation follows the frozen `render_room.guitar` and `render_room.piano` functions. It preserves nearest-root mapping, guitar round-robin modulo four, piano layer one and manifest-order ties (note 58 selects root 60), and the existing asset preprocessing. Pitch corrections and gains already baked into the bank are not applied again.

Transposition uses the same denominator limit of 2048, centered Kaiser-windowed polyphase FIR (beta 5, length `20 * max(up, down) + 1`), zero padding, and ceiling output frame count. The centered filter delay is removed during whole-note preparation; it adds no runtime transport delay. See [SciPy's documented resampling semantics](https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.resample_poly.html). Native Float32 arithmetic may differ slightly from the Python/NumPy paths; bit-identical output is not assumed.

Zero-state Butterworth high-pass and fourth-order low-pass filters preserve their reference ordering and Float32 conversion boundaries. Calibration uses frames 3,840–28,799 across all channels, with the original gain clamps and piano onset shaping. Finite warmth values are clamped to 0–1 and rounded to hundredths with Python-compatible tie handling. Invalid notes, round robins, and nonfinite controls fail before preparation.

## Bounds and ownership

This API accepts local file URLs only. Each manifest read is capped at 262,145 bytes and rejects data above 262,144 bytes. Asset paths must stay in the bank; decoding verifies the declared frame count, one/two channels, 32 kHz rate, and finite samples. Each input has at most 192,000 frames. Nearest-root transposition in MIDI 50–69 is at most two semitones, giving at most 215,513 output frames. The maximum owned output is about 1.65 MiB. Temporary decoder/filter buffers are released per call; there is no retained sample cache or whole-bank decode.

Preparation allocates, reads files, and processes an entire note. It must run on a preparation worker, never in an audio callback. The [64-voice mixer](validation-voices.md) owns bounded immutable copies for an offline score; a concurrent cache/worker handoff remains subsequent work. This API does not establish a real-time rendering guarantee.

## Reproduction and evidence

The 16 [frozen tonal cases](../tests/fixtures/tonal-v9/README.md) cover both channel layouts, every supported transposition ratio, root ties, round robins, and warmth endpoints. Short PCM24 windows total about 150 KB. Their independent oracle is the unchanged Python reference, never the native implementation. Predeclared tolerances are maximum absolute sample error ≤ `1e-5` and RMS error ≤ `1e-6`.

```sh
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-tonal.py \
  --compare .build/tonal-native --evidence .build/tonal-evidence
```

Initialize the pinned Python environment with `tools/reference/setup` as described in the [reference instructions](../tools/reference/README.md). Swift tests compare frozen windows and exercise deterministic round robins, invalid requests, quantization, and malformed/oversized metadata. The Python comparison regenerates complete notes from the frozen functions and checks every native sample, including regions outside those windows. Negative checks rejected out-of-window corruption, NaNs, truncation, and missing candidates. Fixture regeneration is a separate explicit command and is never run by CI.

Local Debug and Release tests passed with Xcode 26.6/Swift 6.3.3 on macOS arm64. Across 4,117,385 sample values, the greatest absolute error was `1.1921e-7`; the largest per-case RMS error was `5.9253e-9`. The unsigned iPhone Release build compiled the package. On the iOS 26.5 simulator, bundled guitar/piano preparation, all 77 bank decoder/hash checks, planner integration, and the launch/About/relaunch UI test passed. Hosted results are required on the PR; physical iOS 18 validation remains pending.

The Release test process records per-note preparation times and its own peak RSS in `.build/tonal-native/profile.json`. Two local runs measured about 3–21 ms per note and 23–32 MB peak test-process RSS. These include the test/framework environment and are not app working-set, callback, device, or energy measurements. No time/RSS threshold is enforced from one host's result.

CI transfers the macOS Release PCM and profile to the existing Linux Audio Regression job, which uses the pinned Python environment for the full comparison. A missing candidate artifact or failed comparison fails CI Gate. It retains `tonal-preparation-comparison` for seven days, including metrics/profile and labeled one-second reference/native dry-note WAV pairs with hashes and RMS levels. No loudness correction is hidden in these pairs. Listen for changes in brightness or uneven decay between each reference and native note. Complete note envelopes, bass/drums, room/compression, output limiting, and full-mix loudness/true-peak comparisons are still pending.
