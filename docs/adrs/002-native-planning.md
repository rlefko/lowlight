# 002: Versioned native song planning

Use a local Swift package, `LowlightPlanning`, for song plans and planner checkpoints. It has no audio, UI, network, or third-party package dependencies. Planning and checkpoint encoding run off the future audio callback. The app links the package; its tests also run directly on macOS without a simulator.

The ordered grammar data preserves the accepted 26 families, 16 chord voicings, six key centers, six contours, weighted 28/36/44-bar forms, phrase arcs, and five presets. `tools/reference/verify-grammar.py` compares this derived resource with the immutable Python catalog. Chord lookup uses a dictionary, but random selection and tie breaking use ordered arrays. Preserve duplicate inner chord voices and the original pitch-class-then-MIDI candidate order.

Native algorithm version 1 uses [SplitMix64](https://raw.githubusercontent.com/vigna/dsiutils/master/src/it/unimi/dsi/util/SplitMix64Random.java) with direct 64-bit seeding, wrapping arithmetic, rejection sampling for bounded choices, and the top 53 bits divided by 2^53 for uniform values. RNG state is serialized as 16 lowercase hexadecimal digits. Tempo uses nearest-even rounding to hundredths. Native seeds intentionally identify a different sequence from Python's `random.Random`; the accepted v9 plans/events remain separate immutable inputs for DSP comparison.

The native signature format is a versioned canonical string containing progression names and key-normalized melodic pitch classes at their quarter-beat anchors. It excludes key, tempo, timbre, recorded takes, and form length. Using the complete string avoids hash collisions and Swift's randomized `Hasher` behavior. This format is separate from the Python reference's JSON/SHA-256 signature.

The initial native test vectors were independently obtained by adapting the frozen Python draft algorithm to this RNG. Reproduce those four plans with `.tools/reference/bin/python tools/reference/native-plan-vectors.py`; it prints candidates without writing fixtures or expected test values. This adapter retains Python's decimal rounding, which agrees for these vectors; it is not a general claim of cross-language floating-point parity.

Keep four recent family IDs and 64 recent signatures. Normal selection allows at most 128 candidate drafts. If they all repeat a signature, retain the final valid candidate and remove the oldest signature-history prefix only until that candidate becomes admissible. The fixed catalog leaves candidates in each mode after excluding four families, so the family guard remains intact. Record only the latest bounded fallback diagnostic. This makes exhaustion deterministic and finite without asserting that the musical grammar is infinite.

Planner checkpoints contain version identifiers, RNG state, normalized settings, the pending song, sequence index, bounded histories, and the latest fallback diagnostic. Encoding is deterministic; restoration rejects incompatible or malformed state. Settings changes affect the next unplanned song. A checkpoint preserves musical intent, not audio-engine or effect state.

PR 3 deliberately stops at song-level plans. Note-event expansion, the common-tone pivot, the shared beat/frame clock, and transport position form the next focused change. Playback and physical-device performance remain later milestones.
