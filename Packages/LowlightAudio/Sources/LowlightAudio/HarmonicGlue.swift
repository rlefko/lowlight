// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum HarmonicFocus: UInt8 { case guitar, piano }
public enum HarmonicGlueError: Error { case invalidConfiguration, allocationFailed }
public typealias HarmonicGlueFrame = LLGlueFrame

/// Single-owner, fixed-storage harmonic processing at 32 kHz, before room and dry scaling.
/// Setup/destruction belong off the callback. Input must include any future rack fades.
public final class HarmonicGlue {
    public static let latencyFrames = Int(LL_GLUE_LATENCY)
    private let handle: OpaquePointer

    /// The complete rack length is known at setup, even when rendering only a prefix.
    public init(inputFrames: UInt64, focus: HarmonicFocus) throws {
        guard inputFrames <= (UInt64(1) << 52) - UInt64(Self.latencyFrames) else {
            throw HarmonicGlueError.invalidConfiguration
        }
        guard let handle = ll_glue_create(inputFrames, focus.rawValue) else {
            throw HarmonicGlueError.allocationFailed
        }
        self.handle = handle
    }

    deinit { ll_glue_destroy(handle) }

    /// Equal-length, disjoint preallocated buffers. The first 399 output frames are neutral.
    /// Invalid input clears output without advancing the processor. No concurrent calls.
    public func process(
        _ input: UnsafeBufferPointer<RhythmBusFrame>,
        into output: UnsafeMutableBufferPointer<HarmonicGlueFrame>
    ) -> Bool {
        guard input.count == output.count, input.count <= UInt32.max else {
            output.update(repeating: HarmonicGlueFrame())
            return false
        }
        return ll_glue_process(handle, input.baseAddress, output.baseAddress, UInt32(input.count))
    }

    /// Valid only after all declared input arrives. Returns nil on failure, or the frames written.
    /// Nonempty streams drain exactly 399 additional frames; unused output capacity is cleared.
    public func drain(into output: UnsafeMutableBufferPointer<HarmonicGlueFrame>) -> Int? {
        guard output.count <= UInt32.max else {
            output.update(repeating: HarmonicGlueFrame())
            return nil
        }
        var written: UInt32 = 0
        guard ll_glue_drain(handle, output.baseAddress, UInt32(output.count), &written) else {
            return nil
        }
        return Int(written)
    }

    /// Clears all detector/delay state, retaining the declared length and focus.
    public func reset() { ll_glue_reset(handle) }
}
