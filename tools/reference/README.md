# Frozen revision 9 reference

This is a developer-only sound oracle, not an iPhone engine. The six files in `v9/` are byte-for-byte copies from the accepted archive. Their checksums, the archive checksum, and the archived session-plan checksum are recorded in [provenance.json](provenance.json). Do not format or edit the frozen modules.

The frozen [song](../../tests/fixtures/v9/song.json) is the first actual plan from the accepted two-hour session. Its [621 events](../../tests/fixtures/v9/events.json) retain absolute/local timing, pitches, velocities, articulation, releases, and takes. Rendering injects these events directly, so a future native PRNG does not change this comparison score. NumPy's pinned generator still supplies the reference synthetic air.

## Run

Use Python 3.12.14. Setup downloads only developer dependencies; all versions and transitive package hashes are locked. There are no Python dependencies in the app.

```sh
tools/reference/setup /path/to/python3.12
.tools/reference/bin/python tools/reference/check.py --integrity
.tools/reference/bin/python tools/reference/check.py --render
.tools/reference/bin/python tools/reference/verify-events.py
```

CI can install the same environment with `python -m pip install --require-hashes -r tools/reference/requirements.lock`. After setup, rendering and comparison work offline. `--integrity` uses only the standard library. `--render` assembles an ignored temporary prototype tree, references the bundled bank, and preserves whole-song loudness analysis and the original signal path. It writes candidates and reports only beneath `.build/`; it never replaces reviewed fixtures.

The separate [planning-v1 event oracle](../../tests/fixtures/planning-v1/events.json) covers 2,322 events across three native-generator scores, including both directions of a 60↔100 BPM transition. `verify-events.py` uses only the standard library to rederive these through the frozen event algorithm and independent RNG adapter. The [manifest](../../tests/fixtures/planning-v1/manifest.json) fixes provenance hashes and tolerances; initialization refuses to overwrite existing fixtures. These metadata tests complement the unchanged v9 audio oracle and do not establish native sound parity.

## Fixtures and tolerances

Both clips are stereo, 32 kHz, lossless 24-bit FLAC, eight seconds each. Together they occupy 949,897 bytes. Exact file and decoded-PCM checksums and measured levels are retained in the provenance and [measurements](../../tests/fixtures/v9/measurements.json).

- `focus-body.flac`: canonical frames 512,000–767,999, covering the first song's body at 16–24 seconds.
- `outgoing-tail.flac`: canonical frames 3,328,000–3,583,999, covering the outgoing rack at 104–112 seconds. It includes the rhythm handoff and room tail, without a successor rack. It is not a complete transition fixture.

The initial oracle was generated from the frozen Python reference, before native DSP exists. Reproduction limits were declared before rendering: maximum absolute error `2e-6` full scale, RMS error `2e-7` full scale, and integrated loudness difference `0.01 LU`. These allow small floating-point differences while remaining far below the musical signal. PCM frame count, channel count, sample rate, and finite values must also match. Native DSP alignment and acceptance tolerances will be declared separately before its implementation; descriptor agreement alone will not establish sound parity.

The reference peak protector uses future lookahead without inserting output frames. A causal native implementation must align its latency before comparing these frame positions. Its final gain reduction is zero for this particular song; these clips do not establish limiter stress coverage. The Focus score does not play shaker notes. The bank inventory and native decode test cover the complete sample set separately.

The developer renderer processes one full 116-second rack, including the five-second tail, to preserve the reference's noncausal body normalization. The initial macOS arm64 run took about 19 seconds and peaked near 1,070 MiB RSS. Only the two short clips are retained in Git; full intermediates are deleted. This is not the production memory model or a device-performance result.

Original code is GPL-3.0-only; see the repository [license](../../LICENSE). Original reference audio: copyright © 2026 Ryan Lefkowitz. Recorded-note sources retain their CC0 notices and provenance in the [sound bank](../../Lowlight/SoundBank). Third-party Python packages retain their own licenses and are installed only for development.

The [rhythm bus oracle](../../tests/fixtures/rhythm-v9/README.md) captures raw harmonic stems and processed bass/drums/duck from the unchanged session renderer. `verify-rhythm.py --integrity` validates compact fixtures; `--compare .build/tonal-native/rhythm --evidence .build/tonal-evidence/rhythm` regenerates complete waveforms and compares every native value. Its rhythm-only audition pairs exclude the still-pending harmonic effects and mastering.
