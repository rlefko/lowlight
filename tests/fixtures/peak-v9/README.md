# Accepted linked peak protection

These developer-only fixtures execute unchanged `master_stream.protect` with
the accepted per-song −5 dBFS and session −2.2 dBFS settings. FLOAT WAV inputs
preserve the supplied Float32 samples. Tracing captures each original `y` before
PCM24 writing, and stops before the final level-policy assertion and file rename.
No gain equation or maximum-window implementation produces the oracle.

The stereo peak detector looks from the current frame through 160 future frames.
The linked gain smoother uses the accepted 0.7 ms attack and 100 ms release.
Initial state is zero dB; the smooth attack can leave a first-frame transient
above the nominal setting. These fixtures preserve that behavior. This is not a
brickwall or true-peak guarantee, and PCM24 quantization is outside this stage.

Six tiny cases cover N=1, 2, 159, 160, 161, and 162 with complete frozen outputs.
Other sparse recipes cover threshold levels, positive/negative and asymmetric
stereo, attack/release, increasing/decreasing 161-frame ramps, equal peak expiry,
and the original 64,000-frame processing boundary. Records assign both channels;
unlisted frames are zero. Extreme native input-bound and empty-stream invariants
are tested separately because the original file protector has no empty-input
contract and absolute audio tolerances are unsuitable for extreme magnitudes.

The musical input is captured after whole-body normalization and before per-song
protection from the unchanged original renderer, using all 621 frozen events and
the full 3,711,911-frame song. Only 128,160 input frames are stored: four seconds
plus the required 160 future frames. Both musical cases compare 128,000 outputs
without declaring an artificial endpoint. The song case is additionally compared
with the actual original per-song output. The session diagnostic reuses the input
at an explicit ×4 gain to exercise protection; it is not the accepted mastered
session. Its unprotected WAV is supplied alongside the reference/native pair.

Native candidates are interleaved little-endian stereo Float32. Remove the first
160 physical zero frames before comparing. `complete=true` cases finish/drain
exactly 160 additional frames; `complete=false` cases use their supplied future
input and do not finish. The room and earlier pipeline stages are not rerun by
the native fixture test.

The predeclared full-waveform maximum/RMS limits are 2e-6/2e-7. Verification
checks original source/score hashes, exact inventory and dimensions, finite
fingerprints and full tiny outputs, regenerated independent input recipes,
channel metrics, and every native sample. The shared musical file is checked
against a fresh full-song capture within those same limits. Full reference PCM
hashes are recorded for provenance rather than enforced across platforms.
`freeze-peak.py` is separate from CI and refuses replacement without `--replace`.
