# Native sample registry capacity

A score can use many distinct prepared notes over its lifetime while playing only a few at once. The former 64-entry sample registry rejected valid native schedules independently of the 64-voice limit. The registry now holds at most 166 descriptors, covering the complete current normalized preparation-key domain.

| Instrument | Supported notes | Prepared variants per note | Maximum keys |
| --- | --- | --- | ---: |
| Guitar | 50–69 | Four takes | 80 |
| Piano | 50–69 | One take | 20 |
| Bass | 31–57 | Two takes | 54 |
| Kick | 0 | Two takes | 2 |
| Side-stick | 1 | Two takes | 2 |
| Closed hat | 0 | Two takes and two velocity layers | 4 |
| Shaker | 0 | Four takes | 4 |

Round-robin aliases normalize to those take counts. Guitar, piano, and bass retain their existing score-reachable sample prefixes; percussion retains its complete shaped body. This bound depends on the current validated event domain and sample-key mapping and must be revisited if either expands.

The extra 102 descriptors use 1,224 bytes per mixer. The fixed 32 MiB PCM arena, 2,048-event limit, 64 active voice slots, monophonic bass reservation, and stealing policy are unchanged. Rendering indexes the selected sample directly; it does not scan the larger table. There is no added decoding, eviction, refill, or allocation in the callback.

## Admission evidence

A bounded inventory covered 388 native schedules: eight control scenarios, four seeds, and twelve songs per chain, plus four frozen transition schedules. Of these, 140 used more than 64 sample keys; 139 still fit the existing PCM budget. The two frozen incoming cases require 73 keys / 24,689,592 bytes and 70 keys / 30,004,904 bytes. These counts use the existing prepared-body dimensions and reachable-prefix rules.

The matrix used all five presets, plus Focus with variation 1 and energy/tempo pairs 0/100, 1/60, and 1/100. Each scenario used seeds 0, 1, 91031, and `UInt64.max`, advancing twelve schedules. The four additional cases came from the frozen planning chains in `tests/fixtures/planning-v1/events.json`, including 60→100 and 100→60 BPM transitions.

One sampled dense 60 BPM song requires 33,970,508 bytes and remains over the 32 MiB limit. The descriptor change therefore does not establish that every valid native plan fits. Capacity failures remain explicit; bounded session admission and recovery still need their own policy.

## Validation

Native tests register and play all 166 sample indices across a 2,048-event score, then verify rejection of a 167th sample and 2,049th event without disturbing existing state. They fill the PCM arena to exactly 32 MiB, reject another sample, and retain at most 64 active readers through stealing, bass reservation, reset, and irregular render partitions. All 11 native suites passed optimized and with ASan/UBSan; the changed mixer suite also passed on x86_64. Independent compilation measured the mixer structure growing from 185,752 to 186,976 bytes.

The Swift domain test prepares all 166 keys and round-robin aliases using 441,848 PCM bytes. The 73-key song now passes complete preparation, replay, and reset, while the dense 60 BPM song still fails the PCM limit. Separate complete 73/70-key diagnostics rendered 3,709,428 / 5,672,314 finite stereo frames with the expected storage, zero stolen/dropped voices, and bit-identical reset playback under different partitions. These newly admitted renders are functional checks, not frozen waveform comparisons.

Local Debug and Release each passed 63 audio tests in 20 suites. All 193 existing deterministic exports and the complete 603-event native and 621-event reference-score outputs remain byte-identical to PR #29; all 14 unchanged audio comparison gates pass. The 23 planner tests passed in both configurations, along with the Release app build, seven iOS simulator tests, one UI test, quality/repository checks, and 13 extraction-guard tests. No Swift or native `.cpp` production file changed.

This change addresses one song's sample registry. Shared two-rack voice/storage admission, overlap transport and global peak protection, reference placement at nonzero origins, and physical-device playback remain separate work.
