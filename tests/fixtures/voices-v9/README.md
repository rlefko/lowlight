# Frozen dry tonal voices

The fixture selects the first eight seconds of guitar/piano note-ons from the accepted [v9 event score](../v9/events.json), then renders 12 seconds including their natural/release tails. All 21 event records are copied unchanged. It uses the original `render_room.voice` and `place` functions with warmth 0.78, without room, compression, per-song gain, bass/drums, or mastering. It is a tonal score prefix, not the complete song mix.

The prefix requires 18 distinct prepared samples (about 15.01 MiB), peaks at seven active voices, and ends in exact silence. It includes chord/support/melody gestures, connected notes, both instruments and channel layouts, round robins, and the accepted repeated-pitch/harmonic release decisions already present in the events. Synthetic kernel tests cover overload/stealing and edge cases absent from this musical excerpt.

The native event model quantizes absolute onset/gate/release endpoints. The original reference rounds each relative duration separately. Six selected events differ by at most one frame; the manifest records the independently measured difference from applying absolute endpoints to the original renderer. The frozen oracle retains the **original relative durations**, and tolerances remain maximum absolute error ≤ `1e-5` and RMS error ≤ `1e-6`. PCM24 fixture quantization contributes at most about `1.2e-7`; the full verification compares native Float32 output against a fresh full-precision original render as well.

`manifest.json` records source dimensions, input/audio hashes, raw Float32 provenance, resource/voice counts, dry loudness and four-times oversampled peak measurements. These measurements describe this unmastered prefix, not full-mix loudness or a true-peak limiter guarantee. The source and samples retain their existing [v9 provenance](../../../tools/reference/provenance.json) and [bank notices](../../../docs/sound-bank.md). Fixtures are developer-only resources and are never bundled in the app.

```sh
.tools/reference/bin/python tools/reference/verify-voices.py
.tools/reference/bin/python tools/reference/verify-voices.py \
  --compare .build/tonal-native/voices --evidence .build/tonal-evidence/voices
```

Native candidates are full interleaved little-endian Float32 at `voice-prefix.f32`, with exactly 384,000 stereo frames. Verification checks every sample, exact dimensions, finite output, and silence after the final tail. Evidence contains aligned reference/native WAV files, hashes, loudness/peak metrics, and errors, without hidden level correction. Listen for changed attacks, decay, stereo placement, or overlap balance.

The separate [fixture generator](../../../tools/reference/freeze-voices.py) refuses implicit replacement. CI only verifies; regeneration requires an explicit fixture review and must not accommodate a native regression.
