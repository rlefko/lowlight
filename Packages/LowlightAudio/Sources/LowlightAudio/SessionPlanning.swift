// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

/// A single-owner planning cursor with a stable numeric environment.
/// Serialize every call off the audio callback. Checkpoints retain musical intent,
/// not playback or effect state. Returned schedules are immutable snapshots; direct
/// calls to their planning methods remain outside this owner's numeric scope.
public final class SessionPlanning {
    private var timeline: SessionTimeline

    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(),
        edition: CompositionEdition = .classic
    ) throws {
        let timeline = try PreparationMode.perform {
            try Self.makeTimeline(seed: seed, controls: controls, edition: edition)
        }
        self.init(timeline: timeline)
    }

    private init(timeline: SessionTimeline) { self.timeline = timeline }

    public var current: SongSchedule? { timeline.current }
    public var positionFrame: Int64? { timeline.positionFrame }

    public func next() throws -> SongSchedule { try transaction { try $0.next() } }

    func useEvolvingSuccessors() throws {
        try transaction { $0.useEvolvingSuccessors() }
    }

    public func setControls(_ controls: Controls) throws {
        try transaction { try $0.setControls(controls) }
    }

    public func setPosition(frame: Int64) throws {
        try transaction { try $0.setPosition(frame: frame) }
    }

    /// Evaluates the current schedule's shared clock, including its existing bounds.
    public func frame(at beat: Double) throws -> Int64 {
        try transaction {
            guard let current = $0.current else { throw TimelineError.invalidTime }
            return try current.frame(at: beat)
        }
    }

    public func checkpoint() throws -> Data { try transaction { try $0.checkpoint() } }

    public static func restore(_ data: Data) throws -> SessionPlanning {
        let timeline = try PreparationMode.perform { try restoreTimeline(data) }
        return SessionPlanning(timeline: timeline)
    }

    @inline(never)
    private static func makeTimeline(seed: UInt64, controls: Controls, edition: CompositionEdition)
        throws -> SessionTimeline
    {
        try SessionTimeline(seed: seed, controls: controls, edition: edition)
    }

    @inline(never)
    private static func restoreTimeline(_ data: Data) throws -> SessionTimeline {
        try SessionTimeline.restore(data)
    }

    private func transaction<Value>(
        _ operation: (inout SessionTimeline) throws -> Value
    ) throws -> Value {
        let (updated, result) = try PreparationMode.perform {
            try Self.update(timeline, operation)
        }
        timeline = updated
        return result
    }

    @inline(never)
    private static func update<Value>(
        _ timeline: SessionTimeline, _ operation: (inout SessionTimeline) throws -> Value
    ) throws -> (SessionTimeline, Value) {
        var updated = timeline
        let result = try operation(&updated)
        return (updated, result)
    }
}
