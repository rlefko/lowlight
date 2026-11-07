# Music and controls

Each piece opens with a four-bar introduction, presents an eight-bar theme, changes the arrangement, then reprises the theme ahead of its outgoing four-bar pivot. A call and reply give the piece a rhythmic identity. The first half of the reprise recalls the hook. The second half can lift the register, add a pickup or change the cadence. Longer forms make room for a breakdown with a quiet guide tone, and the 44-bar form also develops its theme before the breakdown. Harmony draws from 26 progression families and six key centers.

A session moves among three ensembles. One leads with electric piano, one features soft vibraphone, and the third features a single tenor line with short and sustained articulations. Guitar and piano can take the answering phrase. Bass pickups, kick placement, half-time backbeats and instrument entrances change with the section. The rhythm section makes space during handoffs and the lead can rest for an entire bar. Variation affects the return of the tune as well as differences between selections. Lower Energy leaves more space.

A fresh installation chooses and saves a session seed. Reopening an old save retains its selected piece and position under the original writing rules. If the incoming piece has already entered a crossfade, it also keeps its original score. The first unheard successor uses the new writing. The original arrangements are still reproducible for the blind listening comparisons. See [songwriting and listening comparisons](music-writing.md).

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

Warmth colors the guitar, piano, electric piano, vibraphone, tenor and room return together. Space sets room return and decay. Texture sets the level of the quiet air. The three effects follow dragging with 200 ms ramps. Choosing a preset starts those ramps and commits one complete setting. Energy, Mood, Tempo, and Variation follow the latest request at a prepared musical handoff. See [live controls and listening comparisons](validation-live-effects.md).
