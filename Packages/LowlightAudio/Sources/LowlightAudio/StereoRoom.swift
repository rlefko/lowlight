// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

public enum StereoRoomError: Error { case invalidConfiguration, allocationFailed }

/// Single-owner stereo room and dry/wet balance at 32 kHz, following harmonic glue.
/// Setup/destruction belong off the callback. Controls remain fixed until recreation.
public final class StereoRoom {
    public static let tonalLimit = Float(LL_ROOM_TONAL_LIMIT)
    private let handle: OpaquePointer

    public init(space: Double, warmth: Double) throws {
        guard space.isFinite, warmth.isFinite, (0...1).contains(space), (0...1).contains(warmth)
        else { throw StereoRoomError.invalidConfiguration }
        guard let handle = ll_room_create(space, warmth) else {
            throw StereoRoomError.allocationFailed
        }
        self.handle = handle
    }

    deinit { ll_room_destroy(handle) }

    /// Equal-length, disjoint preallocated buffers; bass, drums, and duck pass through.
    /// No added alignment latency. Continue feeding zeros to render the reverberant tail.
    /// Tonal magnitudes must not exceed `tonalLimit`; other fields must be finite, duck in 0...1.
    /// Invalid input clears output without advancing state. No concurrent calls.
    public func process(
        _ input: UnsafeBufferPointer<HarmonicGlueFrame>,
        into output: UnsafeMutableBufferPointer<HarmonicGlueFrame>
    ) -> Bool {
        guard input.count == output.count, input.count <= UInt32.max else {
            output.update(repeating: HarmonicGlueFrame())
            return false
        }
        return ll_room_process(handle, input.baseAddress, output.baseAddress, UInt32(input.count))
    }

    /// Clears the tail and all filter history, retaining space and warmth.
    public func reset() { ll_room_reset(handle) }
}
