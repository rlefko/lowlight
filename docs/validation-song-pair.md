# Finite protected song pairs

`PreparedSongPair` owns the first two adjacent schedules of a session, prepared through one private `SongPreparationPool`. It accepts already formed schedules and validates their shared transition and finite endpoint before decoding. The endpoint must fall after the second song starts and no later than the third song would start. Both songs still undergo complete finite-source loudness analysis; truncating the session does not change their measured gain.

## Rendering and ownership

The native pair borrows two fresh, distinct song replays exclusively. Swift keeps both owners private, so callers cannot advance or reset a child independently. Construction and destruction run off the callback, and all calls must be serialized. Both racks remain reserved through EOF and reset. There is no callback retirement, pool mutation, or successor preparation. Admission retains the existing combined 64-voice limit, two fixed 32 MiB PCM arenas, and per-rack score/sample limits. Registered PCM bytes are separate from arena reservation and total process memory.

Rendering uses fixed 256-frame scratch and the children's absolute frame origins. It sums the older song before the newer song in Float32, applies the original 0.4-second entry and 2.8-second finite exit fades as separate Double products stored back to Float32, then runs one continuous session peak protector. Each child already removes its glue and song-peak delays. The pair removes only the additional 160-frame session delay and drains it at EOF, returning exactly the declared frame count for arbitrary output partitions.

Invalid buffer dimensions leave progress intact. A downstream failure silences the entire call and latches a terminal fault; child processors may already have advanced, so retry requires reset. Reset rewinds both complete song paths and session protection without releasing reservations or repeating gain analysis. The render and reset paths perform no allocation or deallocation and restore the caller's floating-point environment.

## Validation

All 12 native suites pass optimized and under ASan/UBSan; the focused pair suite also passes under x86_64 emulation. Tests cover placement around lookahead/block boundaries, complete and truncated children, arbitrary partitions, EOF, partial reset, admission/allocation failures, downstream faults, floating-point restoration, and allocation/free audits. Seventeen independently frozen original-operation probes exercise active session peak reduction. Three short Swift tests compare actual prepared children through an independent composition, verify retained/released reservations, and reject invalid schedule pairs before decoding.

A 150-second public-API render of the accepted Commute audition (warmth 0.86, seed 91031) matches an independently frozen pre-change composition byte for byte: all 4,800,000 stereo frames at 32 kHz, SHA-256 `060d6642dd8dcb4dce8e62ae4a09b374ce67947a03413f20de247098daf47ad1`. Reset with irregular 1/159/160/161/257/1023/4096-frame buffers produces the same hash. Construction from already formed schedules restores hostile caller floating-point settings. Reservations stay at two racks, 28 voice slots, and 64 MiB of PCM arenas, with 44,911,672 registered PCM bytes and zero steals/drops. This is sound and lifecycle evidence, not a device performance measurement.

## Scope

This is a finite initial-session renderer. It does not plan under arbitrary caller floating-point settings, replace retired racks, transfer ownership between threads, or drive an audio device. Planning and public clock conversion still need their own numeric boundary before automatic continuous transport. Device playback, two-hour soaks, and energy measurements remain pending.

The accepted native audition uses Float32 composition before final encoding. Its parity comparison does not introduce the original exporter's intermediate PCM24 quantization or claim equality with that quantized export pipeline.
