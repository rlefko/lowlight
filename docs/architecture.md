# Architecture

The app is a SwiftUI shell with an About sheet and the accepted sound bank. The local `LowlightPlanning` package owns native song plans, note events, a shared transition clock, and intent checkpoints. `LowlightAudio` prepares guitar/piano/bass/percussion samples off the audio thread and renders them through its small C++ `CLowlightDSP` target; see the [tonal preparation](validation-tonal.md), [tonal voice](validation-voices.md), [bass](validation-bass.md), [percussion](validation-percussion.md), and [rhythm bus](validation-rhythm.md) evidence. The optional bus view retains separate dry guitar/piano, processed bass/drums, and kick duck control for the later harmonic rack; both output views share one voice pool and continuous state. There is no playback engine, audio session, settings persistence, or external package dependency. Resource membership is explicit in the Xcode project and package manifest.

Responsibilities stay separate: deterministic Swift planner and event timeline, bank preparation, a small C/C++ DSP kernel, playback coordinator, persistence, and UI. Prefer a few modules with clear ownership. See the [native planning decision](adrs/002-native-planning.md) for algorithm versioning and bounded history, and the [shared-time decision](adrs/003-events-and-shared-time.md) for transitions and checkpoint limits.

The audio callback will render from preallocated storage only. No planning, decoding, allocation, locks, logging, I/O, async calls, or UI updates belong there. Plan one successor, use at most two song racks, and enforce 64 total voices with deterministic stealing. Handle arbitrary callback frame counts in bounded subblocks.

Preserve the canonical 32 kHz signal path and convert at the output boundary. Keep effect and limiter state continuous. Offline rendering must exercise production DSP. Whole-song gain analysis needs a bounded-memory pass off the callback; its startup and CPU costs must be measured.

Persist versioned musical intent atomically off the callback. Restoring a checkpoint does not restore DSP state. Relaunch must stay silent until Play, then restore gracefully with a fade.
