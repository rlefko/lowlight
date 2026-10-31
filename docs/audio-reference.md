# Sound bank and parity

The accepted revision 9 archive was inspected before native implementation. Its SHA-256 is `64f61c7bc012aa862a26cfc0de28a03681acdde1174992f970f1b5d281c2ca61`. The 77 active asset checksums match: 8,825,758 compressed bytes and approximately 53.03 MiB decoded float32 samples. These are bank measurements, not app download or working-set measurements.

The separate 720-second evolving session, 131-second Mood/Energy reel, and 61-second fixed-performance Warmth reel match the archived QA hashes. Historical documentation awaiting v9 feedback has been superseded by acceptance of the v9 direction. No fresh native sound comparison has run.

The prototype's structural verification was rerun with Python 3.12.14 and NumPy 2.3.5: 865 plans over 24 hours, 854 signatures, no recent-history violations, and 20 exact checkpoint continuations, matching archived results. This did not rerender DSP or establish native sound parity. Initialize native Focus from its preset (variation 0.55), rather than the prototype's bare controls default (0.60).

Milestone 2 will import only active lossless notes, exact source manifests, applicable FreePats/VCSL/VSCO Community notices, a frozen reference harness, and short developer-only fixtures. The current app contains none of these assets. Research archives and long listening recordings stay outside Git and the app bundle. Analysis-only uploaded recordings must never become fixtures or resources.

Validate native FLAC decoding or prove sample-preserving lossless conversion and its size impact. Preserve original provenance and CC0 notices, and verify every imported hash and target membership. Pin reference-tool dependencies separately from app runtime dependencies.

Frozen v9 event plans must play independently of the native PRNG. Predeclare tolerances and align added delays before comparing identical scores/takes. Keep body loudness within about 1 LU of baseline and measure output true peak against −1 dBTP. Use aligned, loudness-matched A/B excerpts with hashes, measurements, and one focused listening question. Descriptor agreement alone is not a quality score.

Preserve the post-sum linked peak protector (5 ms lookahead, −2.2 dBFS target, 0.7 ms attack, 100 ms release). It is not a formal true-peak limiter. Centered detectors, resampling, cached filtering, and whole-song gain measurement require explicit causal porting decisions.
