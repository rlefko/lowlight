// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum SongFixedGainError: Error { case unmeasurableBody, preparationFailed }

/// One immutable song gain prepared off the callback from its measured body.
/// Apply after HP32 and before song peak protection, including intro/outro/tails.
/// This stage does not select the body or render/replay the song.
public final class SongFixedGain {
    public static let targetLUFS = -20.5
    public static let inputLimit = Float(LL_SONG_GAIN_INPUT_LIMIT)
    public let decibels, linearMultiplier: Double
    private let handle: OpaquePointer

    public init(measurement: SongLoudnessMeasurement) throws {
        guard let loudness = measurement.integratedLUFS else {
            throw SongFixedGainError.unmeasurableBody
        }
        guard let handle = ll_song_gain_create(loudness) else {
            throw SongFixedGainError.preparationFailed
        }
        var values = LLSongGainValues()
        guard ll_song_gain_get(handle, &values) else {
            ll_song_gain_destroy(handle)
            throw SongFixedGainError.preparationFailed
        }
        self.handle = handle
        decibels = values.gain_db
        linearMultiplier = values.linear_multiplier
    }

    deinit { ll_song_gain_destroy(handle) }

    /// Equal-length, disjoint, preallocated interleaved stereo buffers.
    /// Input must be finite within `inputLimit`. Failure clears the output.
    /// Multiplication keeps the prepared Double factor until the Float store.
    /// No allocation, gain changes, stream position, latency, or drain.
    public func process(
        _ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>
    ) -> Bool {
        guard input.count == output.count, input.count.isMultiple(of: 2),
            input.count / 2 <= UInt32.max
        else {
            output.update(repeating: 0)
            return false
        }
        return ll_song_gain_process(
            handle, input.baseAddress, output.baseAddress, UInt32(input.count / 2))
    }
}
