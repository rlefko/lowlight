// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum PreparedSessionError: Error {
    case invalidSession, notWaiting, preparationFailed, renderEndpointUnavailable
}

public enum SessionPreparation: Sendable { case serialized, concurrent }

/// Single-pass finite session with at most two racks and one continuous session protector.
/// One worker owns planning, preparation, and rack lifetimes. With concurrent preparation,
/// issue a render endpoint for one separate consumer; all other calls stay on the worker.
/// Stop and join both roles before final release off the audio callback. No threads start here.
public final class PreparedSession {
    public let frameCount: UInt32
    private let pool: SongPreparationPool
    private let prepare: (SongPreparationPool) throws -> (PreparedSong, UInt32)
    private let accepted: () -> Void
    private let preparation: SessionPreparation
    private var endpointIssued = false
    private var first: PreparedSong?
    private var second: PreparedSong?
    private let handle: OpaquePointer
    private var retiredSteals = 0
    private var retiredDrops = 0

    /// The finite endpoint must follow the second song's onset. Recreate to rewind.
    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32,
        preparation: SessionPreparation = .serialized, preparer: TonalSamplePreparer
    ) throws {
        let planning = try SessionPlanning(seed: seed, controls: controls)
        var pending: SongSchedule?
        try self.init(
            frameCount: frameCount, preparation: preparation, accepted: { pending = nil },
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
        preparation: SessionPreparation = .serialized,
        accepted: @escaping () -> Void = {},
        prepare: @escaping (SongPreparationPool) throws -> (PreparedSong, UInt32)
    ) throws {
        let pool = SongPreparationPool()
        let prepared = try PreparationMode.perform {
            let first = try prepare(pool)
            accepted()
            let second = try prepare(pool)
            let handle =
                preparation == .concurrent
                ? ll_song_pair_create_streaming(
                    first.0.borrowedHandle, second.0.borrowedHandle, frameCount, second.1)
                : ll_song_pair_create_rolling(
                    first.0.borrowedHandle, second.0.borrowedHandle, frameCount, second.1)
            guard let handle
            else { throw PreparedSessionError.invalidSession }
            accepted()
            return (first.0, second.0, handle)
        }
        self.frameCount = frameCount
        self.pool = pool
        self.prepare = prepare
        self.accepted = accepted
        self.preparation = preparation
        first = prepared.0
        second = prepared.1
        handle = prepared.2
    }

    deinit { withExtendedLifetime((first, second, pool)) { ll_song_pair_destroy(handle) } }

    /// Issue exactly one consumer endpoint off the callback, before concurrent rendering.
    public func makeRenderEndpoint() throws -> RenderEndpoint {
        guard preparation == .concurrent, !endpointIssued else {
            throw PreparedSessionError.renderEndpointUnavailable
        }
        endpointIssued = true
        return RenderEndpoint(owner: self)
    }

    /// Only the immutable native handle and atomic status cross roles. The retained owner
    /// keeps every borrowed rack alive; this endpoint never touches mutable Swift fields.
    /// Use one render consumer, and retain both roles until calls have stopped and joined.
    public final class RenderEndpoint: @unchecked Sendable {
        private let owner: PreparedSession
        fileprivate init(owner: PreparedSession) { self.owner = owner }

        /// Continues the survivor during preparation. If its successor is late, returns
        /// short/zero output at that onset without advancing musical time or peak history.
        public func render(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
            owner.renderFrames(into: output)
        }

        public var frameCount: UInt32 { owner.frameCount }
        public var position: UInt32 { owner.position }
        public var isFaulted: Bool { owner.isFaulted }
    }

    /// Returns logical frames, possibly short at a preparation boundary. Zero means waiting,
    /// empty capacity, or EOF (position == frameCount). Nil means invalid input or a fault.
    /// The unused output is zeroed. Concurrent mode requires its dedicated render endpoint.
    public func render(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
        guard preparation == .serialized else {
            output.update(repeating: 0)
            return nil
        }
        return renderFrames(into: output)
    }

    private func renderFrames(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
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
    /// retry prepares the same pending schedule. In concurrent mode the survivor can keep
    /// rendering until that successor's onset. Invoke only on the single preparation worker.
    public func prepareNext() throws {
        guard needsPreparation else { throw PreparedSessionError.notWaiting }
        try retireFirst()
        try PreparationMode.perform {
            let candidate = try prepare(pool)
            // Retain before release-publication: the consumer may adopt immediately.
            second = candidate.0
            let admitted =
                preparation == .concurrent
                ? ll_song_pair_publish(handle, candidate.0.borrowedHandle, candidate.1)
                : ll_song_pair_append(handle, candidate.0.borrowedHandle, candidate.1)
            guard admitted else {
                second = nil
                throw PreparedSessionError.preparationFailed
            }
            accepted()
        }
    }

    @inline(never)
    private func retireFirst() throws {
        guard second != nil else { return }
        let retired: Bool
        if preparation == .concurrent {
            var child: OpaquePointer?
            retired = ll_song_pair_claim_retired(handle, &child) && child == first?.borrowedHandle
        } else {
            retired = ll_song_pair_retire_first(handle)
        }
        guard retired else {
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
    /// Worker-only pool diagnostics. These are not resident-memory measurements.
    public var preparedPCMBytes: Int { pool.preparedPCMBytes }
    public var reservedPCMBytes: Int { pool.reservedPCMBytes }
    public var requiredVoiceSlots: Int { pool.reservedVoiceSlots }
    /// Read voice diagnostics only after rendering is quiescent.
    public var stolenVoices: Int {
        retiredSteals + (first?.stolenVoices ?? 0) + (second?.stolenVoices ?? 0)
    }
    /// Read voice diagnostics only after rendering is quiescent.
    public var droppedEvents: Int {
        retiredDrops + (first?.droppedEvents ?? 0) + (second?.droppedEvents ?? 0)
    }
}
