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
    /// Legacy extent reading: zero denotes explicit continuous mode. Prefer finiteFrameCount.
    public let frameCount: UInt64
    public var finiteFrameCount: UInt64? { frameCount == 0 ? nil : frameCount }
    private let pool: SongPreparationPool
    private let prepare:
        (SongPreparationPool, PreparationCancellation?) throws -> (PreparedSong, UInt64)
    private let accepted: () -> Void
    private let preparation: SessionPreparation
    private let sequence: SessionListeningSequence?
    private var endpointIssued = false
    private var first: PreparedSong?
    private var second: PreparedSong?
    private let handle: OpaquePointer
    private var retiredSteals = 0
    private var retiredDrops = 0
    private var nextTarget: UInt64?
    private var nextRequested = false
    private var nextPublished = false
    private var nextTransitioning = false

    /// The finite endpoint must follow the second song's onset. Recreate to rewind.
    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32,
        preparation: SessionPreparation = .serialized, preparer: TonalSamplePreparer,
        cancellation: PreparationCancellation? = nil
    ) throws {
        try cancellation?.check()
        let planning = try SessionPlanning(seed: seed, controls: controls)
        var pending: SongSchedule?
        try self.init(
            frameCount: frameCount, preparation: preparation, cancellation: cancellation,
            accepted: { pending = nil },
            prepare: { pool, cancellation in
                if pending == nil { pending = try planning.next() }
                guard let schedule = pending else { throw PreparedSessionError.invalidSession }
                return try Self.prepareSong(
                    schedule, frameCount: frameCount, preparer: preparer, pool: pool,
                    cancellation: cancellation)
            })
    }

    /// Continuous listening has no finite exit fade. Restoring warms at most the selected
    /// song prefix off-callback and then applies an entry fade; it does not restore prior tails.
    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(),
        restart: SessionRestartIntent? = nil,
        preparer: TonalSamplePreparer, cancellation: PreparationCancellation? = nil
    ) throws {
        try cancellation?.check()
        let sequence = try SessionListeningSequence(
            seed: seed, controls: controls, restart: restart, preparer: preparer)
        try self.init(sequence: sequence, cancellation: cancellation)
        if restart != nil {
            var scratch = [Float](repeating: 0, count: 512)
            while position < sequence.warmFrames {
                try cancellation?.check()
                let count = min(256, Int(UInt64(sequence.warmFrames) - position))
                let written = scratch.withUnsafeMutableBufferPointer {
                    renderFrames(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
                }
                guard written == count else { throw PreparedSessionError.preparationFailed }
            }
            try cancellation?.check()
            ll_song_pair_restart_fade(handle)
        }
    }

    private init(sequence: SessionListeningSequence, cancellation: PreparationCancellation?) throws
    {
        let pool = SongPreparationPool()
        let prepared = try PreparationMode.perform {
            try cancellation?.check()
            let first = try sequence.prepare(pool, cancellation: cancellation)
            try cancellation?.check()
            sequence.accepted()
            let second = try sequence.prepare(pool, cancellation: cancellation)
            try cancellation?.check()
            guard
                let handle = ll_song_pair_create_transport(
                    first.0.borrowedHandle, second.0.borrowedHandle, first.1, 0, second.1)
            else { throw PreparedSessionError.invalidSession }
            sequence.accepted()
            return (first.0, second.0, handle)
        }
        frameCount = 0
        self.pool = pool
        self.sequence = sequence
        preparation = .concurrent
        prepare = { try sequence.prepare($0, cancellation: $1) }
        accepted = { sequence.accepted() }
        first = prepared.0
        second = prepared.1
        handle = prepared.2
    }

    @inline(never)
    private static func prepareSong(
        _ schedule: SongSchedule, frameCount: UInt32, preparer: TonalSamplePreparer,
        pool: SongPreparationPool, cancellation: PreparationCancellation?
    ) throws -> (PreparedSong, UInt32) {
        let origin = try schedule.frame(at: 0)
        let next = try schedule.outgoing.ramp.frame(at: 0)
        guard origin >= 0, origin < Int64(frameCount), next > origin else {
            throw PreparedSessionError.invalidSession
        }
        return (
            try pool.prepare(schedule: schedule, preparer: preparer, cancellation: cancellation),
            UInt32(min(Int64(frameCount), next))
        )
    }

    // Short-source test seam. The public initializer never exposes child owners.
    init(
        frameCount: UInt32,
        preparation: SessionPreparation = .serialized,
        cancellation: PreparationCancellation? = nil,
        accepted: @escaping () -> Void = {},
        prepare:
            @escaping (SongPreparationPool, PreparationCancellation?) throws -> (
                PreparedSong, UInt32
            )
    ) throws {
        let pool = SongPreparationPool()
        let prepared = try PreparationMode.perform {
            try cancellation?.check()
            let first = try prepare(pool, cancellation)
            try cancellation?.check()
            accepted()
            let second = try prepare(pool, cancellation)
            try cancellation?.check()
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
        self.frameCount = UInt64(frameCount)
        sequence = nil
        self.pool = pool
        self.prepare = { pool, cancellation in
            let result = try prepare(pool, cancellation)
            return (result.0, UInt64(result.1))
        }
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

        // Called only after the worker has joined and the render consumer is quiescent.
        func captureAfterWorkerStopped() throws -> SessionListeningSnapshot? {
            try owner.receiveNextResult()
            return try owner.captureListeningSnapshot()
        }

        public var frameCount: UInt64 { owner.frameCount }
        public var finiteFrameCount: UInt64? { owner.finiteFrameCount }
        public var isFinished: Bool { owner.isFinished }
        public var position: UInt64 { owner.position }
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
    /// Cancellation observed before publication throws and releases the candidate. Retry
    /// with a new token; a request racing the final check may arrive after admission.
    public func prepareNext(cancellation: PreparationCancellation? = nil) throws {
        try cancellation?.check()
        try receiveNextResult()
        guard !nextPublished else { throw PreparedSessionError.notWaiting }
        guard needsPreparation else { throw PreparedSessionError.notWaiting }
        try retireFirst()
        try PreparationMode.perform {
            let candidate = try prepare(pool, cancellation)
            try cancellation?.check()
            // Retain before release-publication: the consumer may adopt immediately.
            second = candidate.0
            let admitted: Bool
            if let sequence {
                admitted = ll_song_pair_publish_transport(
                    handle, candidate.0.borrowedHandle, sequence.pendingPlacement, candidate.1)
            } else {
                admitted =
                    preparation == .concurrent
                    ? ll_song_pair_publish(handle, candidate.0.borrowedHandle, UInt32(candidate.1))
                    : ll_song_pair_append(handle, candidate.0.borrowedHandle, UInt32(candidate.1))
            }
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
        sequence?.retired()
    }

    func captureListeningSnapshot() throws -> SessionListeningSnapshot? {
        let frame = listeningPosition
        let selection = sequence?.selectionID(at: frame)
        let state: SessionNextState =
            nextTarget != nil && nextTarget == selection
            ? (nextTransitioning ? .transitioning : .queued) : .none
        return try sequence?.capture(at: frame, nextState: state)
    }

    // Worker-only commands. A single target is retained through its transition; repeated
    // presses do not skip multiple songs or replace the canonical pending plan.
    @discardableResult
    func requestNext(selectionID: UInt64) -> Bool {
        guard sequence != nil, listeningSelectionID == selectionID else { return false }
        if let nextTarget { return nextTarget == selectionID }
        nextTarget = selectionID
        return true
    }

    var canCaptureListeningSnapshot: Bool { !nextPublished }
    var hasNextWork: Bool { nextTarget != nil && !nextTransitioning && !nextPublished }
    var canPrepareSuccessor: Bool { !nextPublished }

    /// Acknowledgments are consumed before ordinary retirement, while both offered owners
    /// remain pinned. A late proposal is retried at a newly offered physical cursor.
    func receiveNextResult() throws {
        var result = LLSongNextResult()
        if ll_song_pair_next_result(handle, &result) {
            if result.status == 1 {
                try sequence?.advanced(
                    targetOrigin: result.target_origin, boundary: result.boundary_frames,
                    delta: result.advanced_frames)
            } else if nextPublished {
                first?.discardRejectedAdvance()
            }
            nextRequested = false
            nextPublished = false
            // A missed deadline may still have a later feasible phrase. Retry from a new
            // physical-input offer; only accepted/naturally satisfied results transition.
            nextTransitioning = result.status != 2
            if result.status == 2, nextTarget != listeningSelectionID { nextTarget = nil }
        }
        if nextTransitioning, nextTarget != listeningSelectionID {
            nextTarget = nil
            nextTransitioning = false
        }
    }

    @discardableResult
    func prepareAdvance(cancellation: PreparationCancellation) throws -> Bool {
        try cancellation.check()
        guard let sequence, let target = nextTarget, !nextTransitioning, !nextPublished,
            let record = sequence.record(for: target)
        else { return false }
        if !nextRequested {
            guard ll_song_pair_request_next(handle, record.placement) else {
                throw PreparedSessionError.preparationFailed
            }
            nextRequested = true
        }
        var offer = LLSongNextOffer()
        guard ll_song_pair_claim_next(handle, &offer) else { return false }
        do {
            guard let first, first.borrowedHandle == offer.first else {
                throw PreparedSessionError.preparationFailed
            }
            guard
                let (boundary, mask) = try sequence.advanceBoundary(
                    for: target, after: offer.source_input_frames, before: offer.outro_start_frames)
            else {
                guard ll_song_pair_abandon_next(handle) else {
                    throw PreparedSessionError.preparationFailed
                }
                nextRequested = false
                nextTransitioning = true
                return true
            }
            let advance = try first.makeAdvance(
                offer: offer, boundaryFrames: boundary, pivotPitchClasses: mask,
                cancellation: cancellation)
            try first.publishAdvance(advance, to: handle, cancellation: cancellation)
            nextPublished = true
            return true
        } catch {
            _ = ll_song_pair_abandon_next(handle)
            nextRequested = false
            throw error
        }
    }

    private var listeningPosition: UInt64 { ll_song_pair_listening_position64(handle) }

    var listeningNextState: SessionNextState {
        nextTarget != nil && nextTarget == listeningSelectionID
            ? (nextTransitioning ? .transitioning : .queued) : .none
    }

    var listeningSelectionID: UInt64? { sequence?.selectionID(at: listeningPosition) }

    public var needsPreparation: Bool { ll_song_pair_needs_preparation(handle) }
    public var position: UInt64 { ll_song_pair_position64(handle) }
    public var isFinished: Bool { ll_song_pair_finished(handle) }
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
