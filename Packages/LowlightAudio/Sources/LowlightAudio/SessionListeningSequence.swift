// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

/// Worker-only metadata follows admitted racks, independently of the ahead-of-render planner.
final class SessionListeningSequence {
    struct Record {
        let schedule: SongSchedule
        let checkpoint: Data
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

    private let planning: SessionPlanning
    private let preparer: TonalSamplePreparer
    private var pending: Record?
    private(set) var records: [Record] = []
    private var offset: Int64
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
        if let restart {
            planning = try SessionPlanning.restore(restart.checkpoint)
            guard let current = planning.current else { throw SessionRestartError.invalidIntent }
            schedule = current
        } else {
            planning = try SessionPlanning(seed: seed, controls: controls)
            schedule = try planning.next()
        }
        let record = try PreparationMode.perform {
            try Self.record(schedule, checkpoint: planning.checkpoint(), offset: 0)
        }
        self.planning = planning
        offset = -Int64(record.canonicalOrigin)
        var first = record
        first.placement = 0
        first = Record(
            schedule: first.schedule, checkpoint: first.checkpoint,
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
    private static func record(_ schedule: SongSchedule, checkpoint: Data, offset: Int64) throws
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
            schedule: schedule, checkpoint: checkpoint, canonicalOrigin: UInt64(origin),
            handoff: UInt64(placedHandoff.partialValue), placement: UInt64(placed.partialValue))
    }

    func pendingRecord() throws -> Record {
        if pending == nil {
            let schedule = try planning.next()
            pending = try PreparationMode.perform {
                try Self.record(schedule, checkpoint: planning.checkpoint(), offset: offset)
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
            checkpoint: selected.checkpoint, canonicalFrame: canonical)
        return SessionListeningSnapshot(
            currentSong: selected.schedule.song,
            nextSong: index + 1 < records.count ? records[index + 1].schedule.song : nil,
            canonicalFrame: canonical, transportFrame: position, nextState: nextState,
            restart: restart)
    }
}
