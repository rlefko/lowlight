// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum PreparedSongPairError: Error { case invalidPair, preparationFailed }

/// Finite initial-session overlap, with session fades and peak protection after the sum.
/// Construction analyzes both complete songs off the callback. All calls must be serialized;
/// destroy off the callback. The privately owned racks remain alive through EOF and reset.
public final class PreparedSongPair {
    public let frameCount: UInt32
    private let pool: SongPreparationPool
    private let songs: (PreparedSong, PreparedSong)
    private let handle: OpaquePointer

    /// Plans the initial adjacent schedules before using the existing finite pair path.
    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32,
        preparer: TonalSamplePreparer
    ) throws {
        let planning = try SessionPlanning(seed: seed, controls: controls)
        let first = try planning.next()
        let second = try planning.next()
        try self.init(first: first, second: second, frameCount: frameCount, preparer: preparer)
    }

    /// Accepts two already formed, adjacent schedules starting at session frame zero.
    /// End after the second song starts and no later than the third song would start.
    /// Planning itself remains outside the preparation numeric scope.
    public convenience init(
        first: SongSchedule, second: SongSchedule, frameCount: UInt32,
        preparer: TonalSamplePreparer
    ) throws {
        try self.init(frameCount: frameCount) { pool in
            try Self.makeSongs(
                first: first, second: second, frameCount: frameCount, preparer: preparer, pool: pool
            )
        }
    }

    @inline(never)
    private static func makeSongs(
        first: SongSchedule, second: SongSchedule, frameCount: UInt32,
        preparer: TonalSamplePreparer, pool: SongPreparationPool
    ) throws -> (PreparedSong, PreparedSong) {
        try first.validate()
        try second.validate()
        let firstLayout = try SongRenderLayout(schedule: first)
        let secondLayout = try SongRenderLayout(schedule: second)
        let nextOrigin = try second.outgoing.ramp.frame(at: 0)
        guard first.incoming == nil, firstLayout.frameOrigin == 0,
            first.outgoing == second.incoming,
            secondLayout.frameOrigin < UInt64(frameCount),
            nextOrigin > 0, UInt64(frameCount) <= UInt64(nextOrigin)
        else { throw PreparedSongPairError.invalidPair }
        return (
            try pool.prepare(schedule: first, preparer: preparer),
            try pool.prepare(schedule: second, preparer: preparer)
        )
    }

    // Internal short-source seam; the public initializer never exposes child owners.
    init(
        frameCount: UInt32,
        prepare: (SongPreparationPool) throws -> (PreparedSong, PreparedSong)
    ) throws {
        let pool = SongPreparationPool()
        let prepared = try PreparationMode.perform {
            let songs = try prepare(pool)
            guard
                let handle = ll_song_pair_create(
                    songs.0.borrowedHandle, songs.1.borrowedHandle, frameCount)
            else { throw PreparedSongPairError.preparationFailed }
            return (songs, handle)
        }
        self.frameCount = frameCount
        self.pool = pool
        songs = prepared.0
        handle = prepared.1
    }

    deinit { withExtendedLifetime((songs, pool)) { ll_song_pair_destroy(handle) } }

    /// Returns aligned logical frames, zero at EOF/empty capacity, or nil on failure.
    /// Unused capacity is zeroed. Invalid dimensions preserve progress; a downstream
    /// failure silences the whole call and faults the pair until reset.
    public func render(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
        guard output.count.isMultiple(of: 2), output.count / 2 <= UInt32.max else {
            output.update(repeating: 0)
            return nil
        }
        var written: UInt32 = 0
        guard ll_song_pair_render(handle, output.baseAddress, UInt32(output.count / 2), &written)
        else { return nil }
        return Int(written)
    }

    /// Rewinds both song paths and session peak history without releasing their reservations.
    public func reset() { ll_song_pair_reset(handle) }
    public var position: UInt32 { ll_song_pair_position(handle) }
    public var isFaulted: Bool { ll_song_pair_faulted(handle) }
    public var preparedPCMBytes: Int { pool.preparedPCMBytes }
    public var reservedPCMBytes: Int { pool.reservedPCMBytes }
    public var requiredVoiceSlots: Int { pool.reservedVoiceSlots }
    public var stolenVoices: Int { songs.0.stolenVoices + songs.1.stolenVoices }
    public var droppedEvents: Int { songs.0.droppedEvents + songs.1.droppedEvents }
}
