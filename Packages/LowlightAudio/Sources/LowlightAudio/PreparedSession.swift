// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum PreparedSessionError: Error { case invalidSession, notWaiting, preparationFailed }

/// Single-pass finite session with at most two racks and one continuous session protector.
/// Serialize every call. Construction, prepareNext(), and destruction must run off the
/// audio callback. This owner pauses for preparation; it does not provide asynchronous playback.
public final class PreparedSession {
    public let frameCount: UInt32
    private let pool: SongPreparationPool
    private let prepare: (SongPreparationPool) throws -> (PreparedSong, UInt32)
    private let accepted: () -> Void
    private var first: PreparedSong?
    private var second: PreparedSong?
    private let handle: OpaquePointer
    private var retiredSteals = 0
    private var retiredDrops = 0

    /// The finite endpoint must follow the second song's onset. Recreate to rewind.
    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32,
        preparer: TonalSamplePreparer
    ) throws {
        let planning = try SessionPlanning(seed: seed, controls: controls)
        var pending: SongSchedule?
        try self.init(
            frameCount: frameCount, accepted: { pending = nil },
            prepare: { pool in
                if pending == nil { pending = try planning.next() }
                guard let schedule = pending else { throw PreparedSessionError.invalidSession }
                return try Self.prepareSong(
                    schedule, frameCount: frameCount, preparer: preparer, pool: pool)
            })
    }

    @inline(never)
    private static func prepareSong(
        _ schedule: SongSchedule, frameCount: UInt32, preparer: TonalSamplePreparer,
        pool: SongPreparationPool
    ) throws -> (PreparedSong, UInt32) {
        let origin = try schedule.frame(at: 0)
        let next = try schedule.outgoing.ramp.frame(at: 0)
        guard origin >= 0, origin < Int64(frameCount), next > origin else {
            throw PreparedSessionError.invalidSession
        }
        return (
            try pool.prepare(schedule: schedule, preparer: preparer),
            UInt32(min(Int64(frameCount), next))
        )
    }

    // Short-source test seam. The public initializer never exposes child owners.
    init(
        frameCount: UInt32,
        accepted: @escaping () -> Void = {},
        prepare: @escaping (SongPreparationPool) throws -> (PreparedSong, UInt32)
    ) throws {
        let pool = SongPreparationPool()
        let prepared = try PreparationMode.perform {
            let first = try prepare(pool)
            accepted()
            let second = try prepare(pool)
            guard
                let handle = ll_song_pair_create_rolling(
                    first.0.borrowedHandle, second.0.borrowedHandle, frameCount, second.1)
            else { throw PreparedSessionError.invalidSession }
            accepted()
            return (first.0, second.0, handle)
        }
        self.frameCount = frameCount
        self.pool = pool
        self.prepare = prepare
        self.accepted = accepted
        first = prepared.0
        second = prepared.1
        handle = prepared.2
    }

    deinit { withExtendedLifetime((first, second, pool)) { ll_song_pair_destroy(handle) } }

    /// Returns logical frames, possibly short at a preparation boundary. Zero means waiting,
    /// empty capacity, or EOF (position == frameCount). Nil means invalid input or a fault.
    /// The unused output is zeroed; no rack ownership changes occur here.
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

    /// Detaches and destroys the finished rack before preparing its successor. On failure,
    /// the survivor and protector stay paused; retry prepares the same pending schedule.
    public func prepareNext() throws {
        guard needsPreparation else { throw PreparedSessionError.notWaiting }
        try retireFirst()
        try PreparationMode.perform {
            let candidate = try prepare(pool)
            guard ll_song_pair_append(handle, candidate.0.borrowedHandle, candidate.1) else {
                throw PreparedSessionError.preparationFailed
            }
            second = candidate.0
            accepted()
        }
    }

    @inline(never)
    private func retireFirst() throws {
        guard second != nil else { return }
        guard ll_song_pair_retire_first(handle) else {
            throw PreparedSessionError.preparationFailed
        }
        retiredSteals += first?.stolenVoices ?? 0
        retiredDrops += first?.droppedEvents ?? 0
        first = second
        second = nil
    }

    public var needsPreparation: Bool { ll_song_pair_needs_preparation(handle) }
    public var position: UInt32 { ll_song_pair_position(handle) }
    public var isFaulted: Bool { ll_song_pair_faulted(handle) }
    public var preparedPCMBytes: Int { pool.preparedPCMBytes }
    public var reservedPCMBytes: Int { pool.reservedPCMBytes }
    public var requiredVoiceSlots: Int { pool.reservedVoiceSlots }
    public var stolenVoices: Int {
        retiredSteals + (first?.stolenVoices ?? 0) + (second?.stolenVoices ?? 0)
    }
    public var droppedEvents: Int {
        retiredDrops + (first?.droppedEvents ?? 0) + (second?.droppedEvents ?? 0)
    }
}
