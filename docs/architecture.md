# Architecture

The app is a SwiftUI shell with an About sheet and the accepted sound bank. The local `LowlightPlanning` package owns native song plans and planner checkpoints. It has no playback engine, audio session, settings persistence, or external package dependencies. Resource membership is explicit in the Xcode project and package manifest.

Responsibilities stay separate: deterministic Swift planner, future event/transport model, bank preparation, a small C/C++ DSP kernel if needed, playback coordinator, persistence, and UI. Prefer a few modules with clear ownership. See the [native planning decision](adrs/002-native-planning.md) for algorithm versioning, bounded history, and checkpoint scope.

The audio callback will render from preallocated storage only. No planning, decoding, allocation, locks, logging, I/O, async calls, or UI updates belong there. Plan one successor, use at most two song racks, and enforce 64 total voices with deterministic stealing. Handle arbitrary callback frame counts in bounded subblocks.

Preserve the canonical 32 kHz signal path and convert at the output boundary. Keep effect and limiter state continuous. Offline rendering must exercise production DSP. Whole-song gain analysis needs a bounded-memory pass off the callback; its startup and CPU costs must be measured.

Persist versioned musical intent atomically off the callback. Restoring a checkpoint does not restore DSP state. Relaunch must stay silent until Play, then restore gracefully with a fade.
