# Third-party code

The native quiet-air stage adapts a small subset of NumPy 2.3.5, pinned to commit `c3d60fc8393f3ca3306b8ce8b6453d43737e3d90`. It reproduces the accepted reference's random samples and Float32 reduction order without shipping NumPy or a Python runtime. Original project modifications remain GPL-3.0-only; the adapted material retains its original attribution and licenses.

| Native source | Upstream material |
| --- | --- |
| `NumpyRandom.cpp` | SeedSequence's four-word pool/hash mixing from `bit_generator.pyx`; PCG64 initialization from `_pcg64.pyx` and `src/pcg64`; the Double normal sampler from `src/distributions/distributions.c` |
| `NumpyZiggurat.h` | Unchanged Double normal tables `ki_double`, `wi_double`, `fi_double`, and the two normal-tail constants from `ziggurat_constants.h` |
| `QuietAir.cpp` | Float32 pairwise reduction ordering from `_core/src/umath/loops_utils.h.src`; mean rounding follows `_core/_methods.py` |

The subset supports one bounded integer seed and the original PCG64 XSL-RR generator, not PCG64DXSM or NumPy's full API. The three tables and two constants occupy 6,160 bytes. A finite raw-draw limit rejects preparation if the accepted sequence cannot be replayed within the declared work bound; it does not substitute a different noise stream.

[Source paths and SHA-256 hashes](../config/numpy-source-provenance.json) identify the exact upstream inputs. Each path resolves beneath the [pinned NumPy source tree](https://github.com/numpy/numpy/tree/c3d60fc8393f3ca3306b8ce8b6453d43737e3d90). [Complete preserved notices](../Lowlight/ThirdParty/NumPy-Random-Notices.txt) include the NumPy BSD terms, SeedSequence and PCG MIT notices, and the original random/distribution notices. Source headers retain the applicable attribution, including PCG's historical header and explicit MIT relicensing notice.

The notice file is an explicit app resource and is available offline under **About → Software notices**. [The resource digest](../config/third-party-notices.json) is checked by `scripts/check-repository`; these notices are separate from the [CC0 sound-bank inventory](sound-bank.md). No external runtime package is added. Distribution-route review remains a release gate.
