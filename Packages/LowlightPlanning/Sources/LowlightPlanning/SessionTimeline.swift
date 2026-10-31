// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A bounded planning cursor, not a playback engine or restored effect/overlap state.
public struct SessionTimeline {
    public static let version = 1
    private var planner: SongPlanner
    public private(set) var current: SongSchedule?
    public private(set) var positionFrame: Int64?

    private struct Checkpoint: Codable {
        var version = SessionTimeline.version
        let planner: Data
        let current: SongSchedule?
        let positionFrame: Int64?
    }

    public init(seed: UInt64 = 91_031, controls: Controls = Controls()) throws {
        planner = try SongPlanner(seed: seed, controls: controls)
    }

    public mutating func next() throws -> SongSchedule {
        var updated = planner
        let song = try updated.next()
        let schedule = try SongSchedule(
            song: song, successor: updated.pending, incoming: current?.outgoing)
        let position = max(positionFrame ?? 0, try schedule.frame(at: 0))
        planner = updated
        current = schedule
        positionFrame = position
        return schedule
    }

    public mutating func setControls(_ controls: Controls) throws {
        try planner.setControls(controls)
    }

    public mutating func setPosition(frame: Int64) throws {
        guard let current,
            frame >= (try current.frame(at: 0)),
            frame <= (try current.frame(at: Double(current.song.bars * 4)))
        else { throw TimelineError.invalidTime }
        positionFrame = frame
    }

    public func checkpoint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Checkpoint(
                planner: planner.checkpoint(), current: current, positionFrame: positionFrame))
    }

    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= 131_072 else { throw TimelineError.invalidCheckpoint }
        let state: Checkpoint
        do { state = try JSONDecoder().decode(Checkpoint.self, from: data) } catch {
            throw TimelineError.invalidCheckpoint
        }
        guard state.version == version else { throw TimelineError.unsupportedVersion }
        let planner = try SongPlanner.restore(state.planner)
        if let current = state.current {
            try current.validate()
            let expected = try SongSchedule(
                song: current.song, successor: planner.pending, incoming: current.incoming)
            guard expected == current,
                planner.recentFamilies.dropLast().last == current.song.family,
                let position = state.positionFrame,
                position >= (try current.frame(at: 0)),
                position <= (try current.frame(at: Double(current.song.bars * 4)))
            else { throw TimelineError.invalidCheckpoint }
        } else {
            guard planner.pending.id == 0, state.positionFrame == nil else {
                throw TimelineError.invalidCheckpoint
            }
        }
        return Self(planner: planner, current: state.current, positionFrame: state.positionFrame)
    }

    private init(planner: SongPlanner, current: SongSchedule?, positionFrame: Int64?) {
        self.planner = planner
        self.current = current
        self.positionFrame = positionFrame
    }
}
