# Sound bank and parity

The accepted revision 9 archive was inspected before native implementation. Its SHA-256 is `64f61c7bc012aa862a26cfc0de28a03681acdde1174992f970f1b5d281c2ca61`. The 77 active asset checksums match: 8,825,758 compressed bytes and approximately 53.03 MiB decoded float32 samples. These are bank measurements, not app download or working-set measurements.

The separate 720-second evolving session, 131-second Mood/Energy reel, and 61-second fixed-performance Warmth reel match the archived QA hashes. Historical documentation awaiting v9 feedback has been superseded by acceptance of the v9 direction. The first [native tonal preparation comparisons](validation-tonal.md) now pass; full-mix parity remains pending.

The prototype's structural verification was rerun with Python 3.12.14 and NumPy 2.3.5: 865 plans over 24 hours, 854 signatures, no recent-history violations, and 20 exact checkpoint continuations, matching archived results. This did not rerender DSP or establish native sound parity. Initialize native Focus from its preset (variation 0.55), rather than the prototype's bare controls default (0.60).

The app contains the 77 active lossless notes, exact source manifests, and applicable FreePats/VCSL/VSCO Community notices. See the [bank inventory and verification procedure](sound-bank.md). Six unmodified v9 Python modules and short developer fixtures live outside the app under `tools/reference/` and `tests/fixtures/`. Research archives and long listening recordings stay outside Git and the app bundle. Analysis-only uploaded recordings must never become fixtures or resources.

No samples have been reencoded. Native tests decode every FLAC with AVAudioFile and compare frame counts, sample rates, channels, finite values, and interleaved float32 PCM hashes against an independent FFmpeg decode. Tests also verify exact app resource membership. Simulator evidence does not establish decoder support on the oldest deployment target; iOS 18 device validation remains pending. Reference-tool dependencies are pinned separately from app runtime dependencies.

Frozen v9 event plans must play independently of the native PRNG. Predeclare tolerances and align added delays before comparing identical scores/takes. Keep body loudness within about 1 LU of baseline and measure output true peak against −1 dBTP. Use aligned, loudness-matched A/B excerpts with hashes, measurements, and one focused listening question. Descriptor agreement alone is not a quality score.

The current harness freezes the first archived song and its 621 events. Reproduction uses the original whole-song gain calculation, then compares short body and outgoing-tail excerpts; it does not certify native DSP or a full two-song bridge. See [reference commands and fixture metadata](../tools/reference/README.md). Integrity checks never rewrite expected output.

Preserve the post-sum linked peak protector (5 ms lookahead, −2.2 dBFS target, 0.7 ms attack, 100 ms release). It is not a formal true-peak limiter. Centered detectors, resampling, cached filtering, and whole-song gain measurement require explicit causal porting decisions.

## Milestone 2 validation

On Xcode 26.6 with the iOS 26.5 simulator, all 77 bundled FLAC files decoded through AVAudioFile with exact compressed and float32 PCM hash matches, original rates/channels/frame counts, and finite samples. Resource membership, the launch/About/relaunch smoke test, and the unsigned Release build passed. The iOS 18 runtime and physical devices remain untested.

The frozen Python 3.12.14 renderer reproduced both eight-second fixtures with zero PCM, RMS, and integrated-loudness differences on macOS arm64. Full-song gain agreed with the archived value within 4.4e-8 dB. Corrupted/missing fixtures, an extra source module, and modified candidate PCM were rejected. These checks establish the developer oracle; complete native synthesis and full-mix comparison remain later gates. Native guitar/piano preparation is covered separately in the [tonal validation](validation-tonal.md).
