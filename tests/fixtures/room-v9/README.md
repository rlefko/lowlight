# Accepted stereo room fixtures

These developer-only fixtures call the unchanged `render_room.room` from the
accepted v9 source. They include the original `tonal * .92 + wet` sum and the
space-dependent decay and wet gain. They do not use `instruments.room`.

All inputs and candidates have seven Float32 fields: tonal left/right, bass
left/right, drums left/right, and duck. The room adds no latency. It changes only
tonal fields; duck and the four rhythm fields pass through at the same frame.

Three short cases cover one frame and the first left/right early reflections.
Their complete expected arrays are frozen. Four eight-second cases cover all
space/warmth control corners. Sparse exact dyadic `input_events` define a left
impulse, a right impulse, opposite-polarity and same-polarity stereo impulses,
and pass-through sentinels. Unlisted frames have zero audio and duck one. Records
assign all seven fields. This recipe avoids storing repeated silent input arrays.
Probes cover early taps, comb and allpass boundaries, and late tails.

The two 13-second musical cases use the same 63 accepted events as the rhythm and
glue fixtures, with guitar and piano focus. The original song allocation remains
3,711,911 frames through fades, linked compression, and room processing; capture
and cropping happen afterward. Accepted space is .44 and warmth is .78. Room
tails persist after the dry harmonic voices end. Rhythm mixing, shared
duck application, air, mastering, transitions, and playback remain outside this
fixture. Audition WAVs are harmonic-only, unmastered, post-room audio.

The verifier regenerates every sample with the original functions and compares
all native values. Predeclared maximum/RMS limits are 2e-6/2e-7 for synthetic
cases and 1e-5/1e-6 for musical cases, with the tonal pair also checked separately.
Endpoint tails from frame 64,000 use stricter 1e-8/1e-9 limits. Synthetic rhythm
fields and all duck fields must match exactly. Musical tolerances retain the
earlier absolute event endpoint rounding allowance; they are not mastering limits.

Input definitions, inventory, lengths, source provenance, frozen file hashes,
finite probes, peaks, and RMS are checked. Full Float32 hashes identify the
freezing platform; regenerated reference hashes are reported rather than required
to be identical across platforms. Numerical comparisons remain mandatory.
`freeze-room.py` is separate from verification and CI, and refuses replacement
unless `--replace` is explicitly supplied for review.
