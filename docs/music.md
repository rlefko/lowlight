# Music and control baseline

Revision 8 sound and revision 9 variation/control direction are accepted. Preserve the supplied grammar: 26 progression families, six key centers, six contour templates, and 28/36/44-bar forms. Eight-bar melodic identities repeat with authored variation. Quarter-beat melody anchors, restrained swing, repeated-pitch damping, compatible tails, and monophonic bass are required.

Avoid the last four families and 64 exact key-normalized musical signatures. Use an explicit versioned PRNG and stable serialization. A deterministic exhaustion fallback must relax the oldest novelty restriction without stopping playback. The finite grammar can recur.

Transitions use a common-tone four-bar pivot, one clock, a 16-beat tempo ramp, linear tonal fades, and bass/drum ownership transfer at the midpoint. Quantize absolute event times to sample frames. Organic tempo drift is at most 3 BPM per song.

| Preset | Energy | Mood | Warmth | Space | Texture | Variation |
| --- | --- | --- | --- | --- | --- | --- |
| Focus | 0.35 | 0.15 | 0.78 | 0.44 | 0.09 | 0.55 |
| Relax | 0.10 | 0.05 | 0.88 | 0.55 | 0.07 | 0.35 |
| Commute | 0.58 | 0.35 | 0.72 | 0.42 | 0.08 | 0.60 |
| Workout | 0.88 | 0.65 | 0.63 | 0.35 | 0.06 | 0.65 |
| Reflective | 0.27 | -0.80 | 0.82 | 0.50 | 0.07 | 0.50 |

All presets use Auto tempo, near `64 + 34 × energy`; explicit tempo is 60–100 BPM. Mood ranges from −1 to 1 and biases minor-family probability with `0.5 − 0.46 × mood`. The other controls range from 0 to 1. Energy still changes activity at fixed tempo; variation zero does not freeze the sequence.

Warmth, Space, and Texture need smooth live updates. Structural changes use musical boundaries, one coalesced latest request, and versioned prepared work. Aim to start an audible change within eight bars. These live behaviors are new native work, not verified prototype features.
