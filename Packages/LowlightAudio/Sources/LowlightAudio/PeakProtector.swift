// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum PeakProtectionMode: UInt8 { case song, session }
public enum PeakProtectorError: Error { case allocationFailed }

/// Single-owner linked peak protection at 32 kHz. Setup/destruction run off the callback.
/// This preserves the accepted gain smoother; it is not a brickwall or true-peak limiter.
public final class PeakProtector {
    public static let latencyFrames = Int(LL_PEAK_LATENCY)
    public static let inputLimit = Float(LL_PEAK_INPUT_LIMIT)
    private let handle: OpaquePointer

    /// Song mode targets -5 dBFS; session mode targets -2.2 dBFS after all rack sums.
    public init(mode: PeakProtectionMode) throws {
        guard let handle = ll_peak_create(mode.rawValue) else {
            throw PeakProtectorError.allocationFailed
        }
        self.handle = handle
    }

    deinit { ll_peak_destroy(handle) }

    /// Equal-length, disjoint, preallocated interleaved stereo buffers.
    /// Initial output contains 160 silent frames. Finite magnitudes must not exceed `inputLimit`.
    /// Invalid input clears output without advancing state. No concurrent calls.
    public func process(
        _ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>
    ) -> Bool {
        guard input.count == output.count, input.count.isMultiple(of: 2),
            input.count / 2 <= UInt32.max
        else {
            output.update(repeating: 0)
            return false
        }
        return ll_peak_process(
            handle, input.baseAddress, output.baseAddress, UInt32(input.count / 2))
    }

    /// The first valid call ends input, even with zero capacity. Further process calls fail until reset.
    /// Returns stereo frames written, or nil on failure; unused capacity is cleared.
    /// A nonempty stream drains exactly 160 additional frames; an empty stream drains none.
    public func drain(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
        guard output.count.isMultiple(of: 2), output.count / 2 <= UInt32.max else {
            output.update(repeating: 0)
            return nil
        }
        var written: UInt32 = 0
        guard ll_peak_drain(handle, output.baseAddress, UInt32(output.count / 2), &written) else {
            return nil
        }
        return Int(written)
    }

    /// Reopens input and clears pending samples and gain history, retaining the mode.
    public func reset() { ll_peak_reset(handle) }
}
