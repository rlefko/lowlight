# Native tonal voices

`LowlightAudio` now renders prepared guitar/piano notes through the production C++ kernel, behind the offline harness. It preserves the accepted attack/release curves, velocity law, connected-note gain, piano stereo width, and pan law. This is another focused part of milestone 4; [bass](validation-bass.md) and [percussion](validation-percussion.md) are now implemented; bus processing, room/compression, mastering, continuous transport, and app playback remain pending.

## Ownership and limits

Setup copies PCM into a 32 MiB arena with at most 64 sample descriptors, then validates and copies at most 2,048 sorted events. The Swift bridge prepares each distinct instrument/note/take once per score and releases temporary preparation buffers. The kernel retains no Swift objects or borrowed array storage. Capacity failures are explicit; there is no eviction or asynchronous refill in this PR.

The C API has one owner. Creation, sample registration, score loading, reset, and destruction require an idle renderer; concurrent calls are unsupported. Rendering writes every interleaved stereo frame at 32 kHz, in subblocks of at most 256 frames, with no allocation, freeing, locks, I/O, or logging. The allocation audit intercepts C++ `new`/`delete`; source review checks the remaining call path. Scoped ARM64/SSE2 floating-point controls flush denormals and restore the caller's exact control state. Future device callbacks must call the C kernel directly; the Swift convenience wrapper is not a general Swift real-time guarantee.

At most 64 sample readers are active, including stolen voices during their fade. Guitar/piano overload selects the lowest eligible priority, then releasing voices, then the oldest voice, with stable slot-order ties. Bed/support notes cannot displace answers or melody; answers cannot displace melody. A selected voice fades linearly over 160 frames (5 ms), then its one pending replacement begins from sample zero. Natural sample completion may start the replacement earlier. This intentionally delays an overloaded onset by at most 5 ms to keep the strict reader limit. Slots with pending replacements cannot be stolen again; an arrival with no eligible slot is dropped. Saturating counters expose steals and drops without logging.

Sample inputs have one/two channels, at most 215,513 frames, finite amplitudes within ±8, and must fit the arena. Guitar/piano events use canonical absolute endpoints, with hold/release limits of 16/5 seconds; starts must be at most `2^52 − 215513`. This conservative start bound leaves room for the longest supported sample. Invalid score loads preserve the current score and render position. Reset retains the immutable samples/score and clears voices, position, and counters.

## Independent sound comparison

The [frozen voice excerpt](../tests/fixtures/voices-v9/README.md) contains 21 tonal note-ons from the first eight seconds of the accepted v9 score, rendered for 12 seconds including tails. It uses 18 prepared samples (15,741,256 bytes, about 15.01 MiB) and peaks at seven simultaneous voices. The oracle calls the unchanged Python `render_room.voice` and `place` functions, independently of the C++ implementation. It adds no room, mastering, or hidden level correction.

The native timeline rounds absolute gate/release endpoints; the original oracle rounds relative durations. Six selected events differ by one frame. The original waveform is retained, and predeclared limits of maximum absolute error ≤ `1e-5` and RMS error ≤ `1e-6` include that known contribution. A reference-only endpoint comparison measures maximum `6.1854e-6` and RMS `2.3083e-7`.

Local native Release output across all 768,000 sample values measures maximum error `6.1844e-6` and RMS error `2.3084e-7`. Native/reference dry levels are about −31.960 LUFS and −19.036 dBTP using 4× oversampling. These dry-note levels are not full-mix loudness targets or a limiter result. Both outputs have exact silence from frame 375,010. Native output is bit-identical across fixed 512-frame buffers and irregular 1/17/64/127/256/1,023-frame partitions.

```sh
./scripts/test-dsp
./scripts/test-audio
LOWLIGHT_AUDIO_OUTPUT="$PWD/.build/tonal-native" ./scripts/test-audio release
.tools/reference/bin/python tools/reference/verify-voices.py --integrity
.tools/reference/bin/python tools/reference/verify-voices.py \
  --compare .build/tonal-native/voices --evidence .build/tonal-evidence/voices
```

The C++ harness runs optimized and AddressSanitizer/UndefinedBehaviorSanitizer builds. It covers timing, partition invariance, stereo/pan, envelope endpoints, truncated/one-frame releases, copied ownership, sample/event/byte limits, invalid-load preservation, priority/age/tie decisions, simultaneous steals and drops, allocation/free counts, and floating-point control restoration. Swift tests cover the bridge, empty/invalid scores, odd buffer rejection, and the complete reference excerpt. The iOS integration test renders bundled guitar and piano notes and verifies finite audio followed by silence.

Local Debug/Release package tests (six each), the optimized/sanitized C++ harness, five iOS integration tests, and the launch/About/relaunch UI test passed with Xcode 26.6/Swift 6.3.3 on the iOS 26.5 simulator. The unsigned Release iPhone app also builds. Physical iOS 18 validation remains pending.

An exploratory macOS benchmark used Apple M4 Max (16 logical CPUs), Apple clang 21.0.0, `-O2 -ffp-contract=off`, 64 stereo voices, and 256-frame callbacks at 32 kHz. Sixteen PCM buffers occupied 20,480,128 bytes. Each scenario measured 50,000 callbacks after 2,500 warmups, excluding setup/reset/checks. Five-second releases measured p99/p99.9/worst at 92/104/307 µs; repeating a complete 64-voice steal every callback measured 125/135/1,139 µs. All callbacks retained exactly 64 active voices with no drops. The 8 ms buffer interval provides context only: this as-fast-as-possible host probe had uncontrolled scheduling/load and does not establish device deadlines, energy, or worst-case execution time for every possible 2,048-event burst.

CI compares the full macOS Release output on Linux using the pinned reference environment. The seven-day `tonal-preparation-comparison` artifact includes `voices/comparison.json` and aligned `voice-prefix-reference.wav` / `voice-prefix-native.wav` pairs. Compare them at unchanged playback volume, listening for onset, decay, stereo-position, or level differences. Negative checks reject missing/truncated candidates, nonfinite values, corruption outside the old note windows, and any nonzero tail after the declared silence frame. Fixture regeneration requires explicit overwrite authorization and is never run by CI.

CodeQL traces Swift and C++ from one fresh, cache-disabled Release app build, then requires both source inventories, including the public C header. This retains the Intel tracing runner and avoids a second app build for the new language. Hosted extraction, size, and check results belong to the PR; simulator/host tests do not establish iPhone callback timing, energy, or complete sound parity.

The combined native upload retains the existing `/language:swift` comparison identifier so GitHub can compare it with the main-branch baseline; both language query packs and extraction guards remain required. The [first combined run](https://github.com/rlefko/lowlight/actions/runs/41203998896) extracted all 17 Swift files and the C++ source/header, with zero analysis findings/errors/warnings. It took 11m19s to trace and 18m29s for the complete native job. The job allows 30 minutes for runner variation; this is a timeout allowance, not a speed improvement. Further CI performance work remains separate.
