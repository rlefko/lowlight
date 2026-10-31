# Frozen dry tonal preparation

These short windows come directly from the unmodified accepted `render_room.guitar` and `render_room.piano` functions, before event envelopes, panning, mixing, room, compression, or mastering. The source and bank remain governed by the existing [v9 provenance](../../../tools/reference/provenance.json) and [sound-bank inventory](../../../docs/sound-bank.md). They are developer fixtures, never app resources.

The 16 cases cover nearest-root ties (including piano 58 → 60), supported-range endpoints, transposition in both directions, guitar round-robin wrapping, piano layer 1/stereo, and warmth 0, 0.78, and 1. Imported guitar pitch/gain corrections and piano octave mappings are already baked into the bank; preparation must not apply them again. Piano ignores the event round-robin value.

Each FLAC concatenates four independently indexed 1,024-frame windows from a complete prepared note: attack, the start/end of the calibration interval, and the sample tail. The manifest records the full output dimensions, peak, RMS, and interleaved little-endian Float32 SHA-256 from fixture creation. Full hashes record provenance; float arithmetic across platforms is checked with tolerances rather than a bit-exact promise.

The declared limits are maximum absolute error ≤ `1e-5` and RMS error ≤ `1e-6`, with exact frame/channel counts and finite samples. PCM24 window quantization contributes at most about `1.2e-7`. Verification first reproduces the windows and full-array metrics from frozen v9, then compares **every sample** of each native full-length `.f32` candidate against the regenerated independent reference. It does not infer full-note parity from the short windows alone.

Use the existing pinned Python environment; no network access is needed after setup:

```sh
.tools/reference/bin/python tools/reference/verify-tonal.py
.tools/reference/bin/python tools/reference/verify-tonal.py --compare .build/tonal-candidates --evidence .build/tonal-evidence
```

The evidence command writes one-second, identically timed dry guitar and piano reference/native WAV pairs with hashes and RMS measurements. The comparison uses unchanged gain; any gain correction must be explicit, never hidden by the test. These isolated notes do not establish full-mix loudness, true-peak safety, device performance, or listening acceptance.

The separate [fixture generator](../../../tools/reference/freeze-tonal.py) records the exact case inputs and extraction procedure. It refuses to replace an existing oracle unless explicitly invoked with `--replace`; CI never invokes it. Regeneration requires a dedicated fixture review and must not be used to accommodate a native regression.
