// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum QuietAirError: Error { case preparationFailed }

/// Finite, single-owner air layer at 32 kHz. Prepare and destroy off the audio callback.
/// Preparation validates the full noise stream and computes its fixed normalization with bounded memory.
public final class QuietAir {
    public static let maximumInputFrames = UInt32(LL_AIR_MAX_FRAMES)
    private let handle: OpaquePointer

    /// `inputFrames` includes the song's five-second allocation tail; valid lengths are 1...maximumInputFrames.
    /// `takeSeed` must be below 2^31 and texture finite in 0...1. Fades use the mixer's absolute clock.
    /// `frameOrigin` is the absolute frame of this song's first sample; modulation remains song-local.
    /// Invalid configuration, allocation failure, or a noise stream exceeding the fixed work bound throws.
    public init(
        takeSeed: UInt32, inputFrames: UInt32, frameOrigin: UInt64, texture: Double,
        rackFades: SongRackFades
    ) throws {
        var configuration = rackFades.configuration
        guard
            let handle = ll_air_create(
                takeSeed, inputFrames, frameOrigin, texture, &configuration)
        else { throw QuietAirError.preparationFailed }
        self.handle = handle
    }

    deinit { ll_air_destroy(handle) }

    /// Adds air directly to an already allocated interleaved Float stereo mix.
    /// Modulation, fade, and addition use Double before the single final Float store.
    /// No added latency/drain. Input must be finite and count cannot exceed the remaining stream.
    /// Failure clears the supplied buffer without advancing state. No concurrent calls.
    public func add(to buffer: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard buffer.count.isMultiple(of: 2), buffer.count / 2 <= UInt32.max else {
            buffer.update(repeating: 0)
            return false
        }
        return ll_air_add(handle, buffer.baseAddress, UInt32(buffer.count / 2))
    }

    /// Replays the same prepared stream and envelopes from the song's first frame.
    public func reset() { ll_air_reset(handle) }
}
