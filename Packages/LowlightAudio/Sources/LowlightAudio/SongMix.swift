// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum SongMixError: Error { case preparationFailed }

/// Single-owner song summing, quiet air, and HP32 at the canonical 32 kHz rate.
/// Preparation scans the complete air sequence off the callback; controls stay fixed.
public final class SongMix {
    public static let maximumInputFrames = UInt32(LL_AIR_MAX_FRAMES)
    public static let busLimit = Float(LL_SONG_MIX_BUS_LIMIT)
    private let handle: OpaquePointer

    /// Supply the original complete song length, even when rendering only a prefix.
    /// The frame origin affects air's tonal fade; its modulation remains song-local.
    public init(
        takeSeed: UInt32, inputFrames: UInt32, frameOrigin: UInt64,
        texture: Double, rackFades: SongRackFades
    ) throws {
        var fades = rackFades.configuration
        guard
            let handle = ll_song_mix_create(
                takeSeed, inputFrames, frameOrigin, texture, &fades)
        else { throw SongMixError.preparationFailed }
        self.handle = handle
    }

    deinit { ll_song_mix_destroy(handle) }

    /// Post-room logical song frames into a disjoint, preallocated stereo Float buffer.
    /// Remove upstream glue's 399 startup frames before calling; include its drained
    /// logical frames. This stage adds no latency or drain and consumes at most N frames.
    /// Audio fields must be finite within `busLimit`, with duck in 0...1.
    /// Invalid input clears output without advancing state. No concurrent calls.
    public func process(
        _ input: UnsafeBufferPointer<HarmonicGlueFrame>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Bool {
        guard output.count.isMultiple(of: 2), input.count == output.count / 2,
            input.count <= UInt32.max
        else {
            output.update(repeating: 0)
            return false
        }
        return ll_song_mix_process(
            handle, input.baseAddress, output.baseAddress, UInt32(input.count))
    }

    /// Rewinds air and clears HP32 history, retaining all prepared configuration.
    public func reset() { ll_song_mix_reset(handle) }
}
