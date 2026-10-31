// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct SongSchedule: Codable, Equatable, Sendable {
    public let song: SongPlan
    public let incoming: SongTransition?
    public let outgoing: SongTransition
    public var startSeconds: Double { incoming?.ramp.startSeconds ?? 0 }

    public init(song: SongPlan, successor: SongPlan, incoming: SongTransition? = nil) throws {
        self.song = song
        self.incoming = incoming
        let grammar = try Grammar.bundled()
        try song.validate(using: grammar)
        let bodyStart = try incoming?.ramp.seconds(at: 16) ?? 16 * 60 / song.tempo
        let start = bodyStart + Double(song.bars * 4 - 32) * 60 / song.tempo
        outgoing = try SongTransition(from: song, to: successor, startSeconds: start)
        try validate()
    }

    public func validate() throws {
        try song.validate(using: Grammar.bundled())
        try outgoing.validate()
        guard outgoing.fromID == song.id, outgoing.fromKey == song.key,
            outgoing.fromMode == song.mode
        else { throw TimelineError.invalidSchedule }
        if let incoming {
            try incoming.validate()
            guard incoming.toID == song.id, incoming.toKey == song.key,
                incoming.toMode == song.mode
            else { throw TimelineError.invalidSchedule }
        } else if song.id != 0 {
            throw TimelineError.invalidSchedule
        }
        try validateClock()
    }

    private func validateClock() throws {
        guard [28, 36, 44].contains(song.bars), song.tempo.isFinite,
            (60...100).contains(song.tempo), outgoing.ramp.fromTempo == song.tempo
        else { throw TimelineError.invalidSchedule }
        try outgoing.ramp.validate()
        if let incoming {
            try incoming.ramp.validate()
            guard incoming.ramp.toTempo == song.tempo else { throw TimelineError.invalidSchedule }
        }
        let bodyStart = try incoming?.ramp.seconds(at: 16) ?? 16 * 60 / song.tempo
        let expectedStart = bodyStart + Double(song.bars * 4 - 32) * 60 / song.tempo
        guard outgoing.ramp.startSeconds == expectedStart else {
            throw TimelineError.invalidSchedule
        }
    }

    public func seconds(at beat: Double) throws -> Double {
        try validateClock()
        guard beat.isFinite, beat >= 0 else { throw TimelineError.invalidTime }
        let total = Double(song.bars * 4)
        let result: Double
        if beat >= total {
            result = try outgoing.ramp.seconds(at: 16) + (beat - total) * 60 / outgoing.ramp.toTempo
        } else if beat >= total - 16 {
            result = try outgoing.ramp.seconds(at: beat - (total - 16))
        } else if beat <= 16 {
            result = try incoming?.ramp.seconds(at: beat) ?? beat * 60 / song.tempo
        } else {
            let bodyStart = try incoming?.ramp.seconds(at: 16) ?? 16 * 60 / song.tempo
            result = bodyStart + (beat - 16) * 60 / song.tempo
        }
        _ = try MusicalTime.frame(result)
        return result
    }

    public func frame(at beat: Double) throws -> Int64 { try MusicalTime.frame(seconds(at: beat)) }

    /// Dry harmonic/air gain before compression and room; wet tails remain separate.
    public func tonalGain(atFrame frame: Int64) throws -> Double {
        try validateClock()
        let arrival = try incoming?.ramp.progress(atFrame: frame) ?? 1
        return try arrival * (1 - outgoing.ramp.progress(atFrame: frame))
    }

    /// Includes the 75 ms outgoing one-shot tail cutoff, not only note-on suppression.
    public func rhythmGain(atFrame frame: Int64) throws -> Double {
        try validateClock()
        guard (0...MusicalTime.maximumFrame).contains(frame) else {
            throw TimelineError.invalidTime
        }
        if let incoming, frame < (try incoming.handoffFrame()) { return 0 }
        let end = try outgoing.handoffFrame()
        return min(1, max(0, Double(end - frame) / 2_400))
    }
}
