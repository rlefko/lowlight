// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum SongLoudnessError: Error { case preparationFailed, incompleteBody }

public struct SongLoudnessMeasurement: Equatable, Sendable {
    /// Nil when the supplied body contains no blocks above the loudness gates.
    /// Such a body has no usable normalization gain.
    public let integratedLUFS: Double?
    public let totalBlocks, absoluteBlocks, gatedBlocks: UInt32
}

/// Single-owner, fixed-storage analysis of a stereo Float body at 32 kHz.
/// Run during song preparation, off the audio callback. Supply only the selected
/// post-HP32 body; K-weighting starts with zero history at its first frame.
public final class SongLoudnessMeter {
    public static let minimumBodyFrames = UInt32(LL_LOUDNESS_MIN_FRAMES)
    public static let maximumBodyFrames = UInt32(LL_LOUDNESS_MAX_FRAMES)
    public static let inputLimit = Float(LL_LOUDNESS_INPUT_LIMIT)
    private let handle: OpaquePointer

    public init(bodyFrames: UInt32) throws {
        guard let handle = ll_loudness_create(bodyFrames) else {
            throw SongLoudnessError.preparationFailed
        }
        self.handle = handle
    }

    deinit { ll_loudness_destroy(handle) }

    /// Input is interleaved L/R, finite, and bounded by `inputLimit`.
    /// Invalid calls preserve all progress. Successful finish requires a reset
    /// before any further processing, including an empty buffer.
    public func process(_ input: UnsafeBufferPointer<Float>) -> Bool {
        guard input.count.isMultiple(of: 2), input.count / 2 <= UInt32.max else {
            return false
        }
        return ll_loudness_process(handle, input.baseAddress, UInt32(input.count / 2))
    }

    /// Requires exactly the declared body length. Repeated successful calls return
    /// the same measurement. An incomplete attempt does not finalize the meter.
    public func finish() throws -> SongLoudnessMeasurement {
        var result = LLLoudnessResult()
        guard ll_loudness_finish(handle, &result) else {
            throw SongLoudnessError.incompleteBody
        }
        return SongLoudnessMeasurement(
            integratedLUFS: result.measurable ? result.integrated_lufs : nil,
            totalBlocks: result.total_blocks, absoluteBlocks: result.absolute_blocks,
            gatedBlocks: result.gated_blocks)
    }

    /// Clears filters, accumulated power, and completion, retaining body length.
    public func reset() { ll_loudness_reset(handle) }
}
