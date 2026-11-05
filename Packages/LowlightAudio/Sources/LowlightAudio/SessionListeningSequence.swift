// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

/// Worker-only metadata follows admitted racks, independently of the ahead-of-render planner.
final class SessionListeningSequence {
    struct Record: Equatable {
        let schedule: SongSchedule
        let checkpoint: Data
        let planningAnchor: Data?
        let canonicalOrigin: UInt64
        var handoff: UInt64
        var placement: UInt64
        var pivot: UInt64?
        var advance: UInt64 = 0

        func canonicalFrame(at position: UInt64) -> UInt64 {
            let local = position - placement
            return canonicalOrigin + local + (pivot.map { local >= $0 } == true ? advance : 0)
        }
    }

    private var planning: SessionPlanning
    private let preparer: TonalSamplePreparer
    private var pending: Record?
    private(set) var records: [Record] = []
    private var offset: Int64
    private(set) var acceptedControlsRevision: UInt64 = 0
    let warmFrames: UInt32
    var pendingPlacement: UInt64 {
        guard let pending else { preconditionFailure("No pending listening song") }
        return pending.placement
    }

    init(
        seed: UInt64, controls: Controls, restart: SessionRestartIntent?,
        preparer: TonalSamplePreparer
    ) throws {
        self.preparer = preparer
        let planning: SessionPlanning
        let schedule: SongSchedule
        let anchor: Data?
        if let restart {
            planning = try SessionPlanning.restore(restart.checkpoint)
            guard let current = planning.current else { throw SessionRestartError.invalidIntent }
            schedule = current
            anchor = restart.planningAnchor
        } else {
            planning = try SessionPlanning(seed: seed, controls: controls)
            anchor = try planning.checkpoint()
            schedule = try planning.next()
        }
        let record = try PreparationMode.perform {
            try Self.record(
                schedule, checkpoint: planning.checkpoint(), anchor: anchor, offset: 0)
        }
        self.planning = planning
        offset = -Int64(record.canonicalOrigin)
        var first = record
        first.placement = 0
        first = Record(
            schedule: first.schedule, checkpoint: first.checkpoint,
            planningAnchor: first.planningAnchor,
            canonicalOrigin: first.canonicalOrigin, handoff: 0, placement: 0)
        pending = first
        if let restart {
            let prefix = restart.canonicalFrame - record.canonicalOrigin
            guard prefix <= UInt32.max else { throw SessionRestartError.invalidIntent }
            warmFrames = UInt32(prefix)
        } else {
            warmFrames = 0
        }
    }

    @inline(never)
    private static func record(
        _ schedule: SongSchedule, checkpoint: Data, anchor: Data?, offset: Int64
    ) throws
        -> Record
    {
        let origin = try schedule.frame(at: 0)
        let handoff = try schedule.incoming?.handoffFrame() ?? origin
        let placed = origin.addingReportingOverflow(offset)
        let placedHandoff = handoff.addingReportingOverflow(offset)
        guard !placed.overflow, !placedHandoff.overflow, placed.partialValue >= 0,
            placedHandoff.partialValue >= placed.partialValue,
            placedHandoff.partialValue <= MusicalTime.maximumFrame
        else { throw PreparedSessionError.invalidSession }
        return Record(
            schedule: schedule, checkpoint: checkpoint, planningAnchor: anchor,
            canonicalOrigin: UInt64(origin),
            handoff: UInt64(placedHandoff.partialValue), placement: UInt64(placed.partialValue))
    }

    func pendingRecord() throws -> Record {
        if pending == nil {
            let anchor = try planning.checkpoint()
            let schedule = try planning.next()
            pending = try PreparationMode.perform {
                try Self.record(
                    schedule, checkpoint: planning.checkpoint(), anchor: anchor, offset: offset)
            }
        }
        guard let pending else { throw PreparedSessionError.invalidSession }
        return pending
    }

    @inline(never)
    func prepare(_ pool: SongPreparationPool, cancellation: PreparationCancellation?) throws
        -> (PreparedSong, UInt64)
    {
        let pending = try pendingRecord()
        let next = try pending.schedule.outgoing.ramp.frame(at: 0)
        let placed = next.addingReportingOverflow(offset)
        guard !placed.overflow, placed.partialValue > Int64(pending.placement),
            placed.partialValue <= MusicalTime.maximumFrame
        else { throw PreparedSessionError.invalidSession }
        return (
            try pool.prepare(
                schedule: pending.schedule, preparer: preparer, cancellation: cancellation),
            UInt64(placed.partialValue)
        )
    }

    func accepted() {
        guard records.count < 2, let pending else {
            preconditionFailure("Listening admission requires a pending song and a free record")
        }
        records.append(pending)
        self.pending = nil
    }

    func retired() {
        precondition(records.count == 2)
        records.removeFirst()
    }

    func record(for id: UInt64) -> Record? { records.first { $0.schedule.song.id == id } }

    /// Pure speculative planning from the same pre-successor basis for every revision.
    /// The canonical cursor/history and admitted records change only after native adoption.
    /// A legacy restart or an already committed transition waits for the next selected song.
    func planControls(_ request: SessionControlsRequest, selectionID: UInt64) throws
        -> SessionControlsPlan?
    {
        guard request.revision > acceptedControlsRevision, records.count == 2, pending == nil,
            records[0].schedule.song.id == selectionID, records[0].pivot == nil,
            let originalAnchor = records[0].planningAnchor
        else { return nil }
        let candidate = try SessionPlanning.restore(originalAnchor)
        try candidate.setControls(request.controls)
        let anchor = try candidate.checkpoint()
        let currentSchedule = try candidate.next()
        let currentCheckpoint = try candidate.checkpoint()
        let successorSchedule = try candidate.next()
        let successorCheckpoint = try candidate.checkpoint()
        return try PreparationMode.perform {
            guard currentSchedule.song == records[0].schedule.song,
                currentSchedule.incoming == records[0].schedule.incoming
            else { throw SessionControlsError.stalePlan }
            var current = try Self.record(
                currentSchedule, checkpoint: currentCheckpoint, anchor: anchor, offset: offset)
            current.handoff = records[0].handoff
            let successor = try Self.record(
                successorSchedule, checkpoint: successorCheckpoint, anchor: currentCheckpoint,
                offset: offset)
            let next = try successorSchedule.outgoing.ramp.frame(at: 0)
            let following = next.addingReportingOverflow(offset)
            guard !following.overflow, current.placement == records[0].placement,
                following.partialValue > Int64(successor.placement),
                following.partialValue <= MusicalTime.maximumFrame
            else { throw PreparedSessionError.invalidSession }
            return SessionControlsPlan(
                request: request, current: current, successor: successor,
                followingOrigin: UInt64(following.partialValue), planning: candidate,
                original: records, offset: offset)
        }
    }

    /// Call only after the matching native transaction has been adopted. A publication
    /// attempt, canceled preview, or stale acknowledgment cannot advance canonical history.
    func acceptControls(
        _ plan: SessionControlsPlan, expectedRevision: UInt64, boundary: UInt32, delta: UInt32
    ) throws {
        guard plan.request.revision == expectedRevision,
            expectedRevision > acceptedControlsRevision, records == plan.original,
            pending == nil, offset == plan.offset
        else { throw SessionControlsError.stalePlan }
        let naturalBoundary = plan.successor.placement - plan.current.placement
        let shifted = offset.subtractingReportingOverflow(Int64(delta))
        guard UInt64(boundary) + UInt64(delta) == naturalBoundary,
            boundary >= 3520, plan.followingOrigin >= delta, !shifted.overflow,
            plan.successor.placement >= delta, plan.successor.handoff >= delta
        else { throw SessionControlsError.stalePlan }
        var current = plan.current
        current.pivot = UInt64(boundary)
        current.advance = UInt64(delta)
        var successor = plan.successor
        successor.placement -= UInt64(delta)
        successor.handoff -= UInt64(delta)
        records = [current, successor]
        planning = plan.planning
        offset = shifted.partialValue
        acceptedControlsRevision = expectedRevision
    }

    /// The shared clock chooses the first future eight-bar boundary with damping lead.
    /// No schedule is replanned and the original outgoing ramp is translated intact.
    func advanceBoundary(for id: UInt64, after physicalInput: UInt32, before outro: UInt32)
        throws -> (UInt32, UInt16)?
    {
        guard let record = record(for: id) else { return nil }
        return try PreparationMode.perform {
            try Self.boundary(record, after: physicalInput, before: outro)
        }
    }

    @inline(never)
    private static func boundary(
        _ record: Record, after physicalInput: UInt32, before outro: UInt32
    )
        throws -> (UInt32, UInt16)?
    {
        for beat in stride(from: 32, to: record.schedule.song.bars * 4 - 16, by: 32) {
            let frame = try record.schedule.frame(at: Double(beat))
            let local = UInt64(frame) - record.canonicalOrigin
            if local >= UInt64(physicalInput) + 3520, local < outro {
                let mask = record.schedule.outgoing.pivot.pcs.reduce(UInt16(0)) {
                    $0 | (UInt16(1) << $1)
                }
                return (UInt32(local), mask)
            }
        }
        return nil
    }

    func advanced(targetOrigin: UInt64, boundary: UInt32, delta: UInt32) throws {
        guard records.count == 2, records[0].placement == targetOrigin,
            records[0].pivot == nil, records[1].placement >= delta,
            records[1].handoff >= delta, pending == nil
        else { throw PreparedSessionError.preparationFailed }
        records[0].pivot = UInt64(boundary)
        records[0].advance = UInt64(delta)
        records[1].placement -= UInt64(delta)
        records[1].handoff -= UInt64(delta)
        let shifted = offset.subtractingReportingOverflow(Int64(delta))
        guard !shifted.overflow else { throw PreparedSessionError.preparationFailed }
        offset = shifted.partialValue
    }

    func selectionID(at position: UInt64) -> UInt64? {
        guard let first = records.first, position >= first.placement else { return nil }
        let index = records.count == 2 && position >= records[1].handoff ? 1 : 0
        return records[index].schedule.song.id
    }

    func capture(at position: UInt64, nextState: SessionNextState = .none) throws
        -> SessionListeningSnapshot?
    {
        guard let first = records.first, position >= first.placement else { return nil }
        let index = records.count == 2 && position >= records[1].handoff ? 1 : 0
        let selected = records[index]
        let canonical = selected.canonicalFrame(at: position)
        let restart = try SessionRestartIntent(
            checkpoint: selected.checkpoint, canonicalFrame: canonical,
            planningAnchor: selected.planningAnchor)
        return SessionListeningSnapshot(
            currentSong: selected.schedule.song,
            nextSong: index + 1 < records.count ? records[index + 1].schedule.song : nil,
            canonicalFrame: canonical, transportFrame: position, nextState: nextState,
            restart: restart)
    }
}

/// Worker-only candidate. Retaining this object cannot mutate the admitted sequence, and
/// discarding it leaves the source anchor available for deterministic retry/rollback.
final class SessionControlsPlan {
    let request: SessionControlsRequest
    let current: SessionListeningSequence.Record
    let successor: SessionListeningSequence.Record
    let followingOrigin: UInt64
    fileprivate let planning: SessionPlanning
    fileprivate let original: [SessionListeningSequence.Record]
    fileprivate let offset: Int64

    fileprivate init(
        request: SessionControlsRequest, current: SessionListeningSequence.Record,
        successor: SessionListeningSequence.Record, followingOrigin: UInt64,
        planning: SessionPlanning, original: [SessionListeningSequence.Record], offset: Int64
    ) {
        self.request = request
        self.current = current
        self.successor = successor
        self.followingOrigin = followingOrigin
        self.planning = planning
        self.original = original
        self.offset = offset
    }
}
