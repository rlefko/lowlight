// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct SongTransition: Codable, Equatable, Sendable {
    public let fromID, toID: UInt64
    public let fromKey, toKey: Int
    public let fromMode, toMode: String
    public let pivot: SongPlan.Chord
    public let ramp: TempoRamp

    public init(from: SongPlan, to: SongPlan, startSeconds: Double) throws {
        let grammar = try Grammar.bundled()
        try from.validate(using: grammar)
        try to.validate(using: grammar)
        fromID = from.id
        toID = to.id
        fromKey = from.key
        toKey = to.key
        fromMode = from.mode
        toMode = to.mode
        pivot = try Self.makePivot(
            fromKey: fromKey, fromMode: fromMode, toKey: toKey, toMode: toMode)
        ramp = try TempoRamp(
            startSeconds: startSeconds, fromTempo: from.tempo, toTempo: to.tempo)
        try validate()
    }

    func validate() throws {
        guard fromID < .max, toID == fromID + 1,
            try pivot
                == Self.makePivot(
                    fromKey: fromKey, fromMode: fromMode, toKey: toKey, toMode: toMode)
        else { throw TimelineError.invalidSchedule }
        try ramp.validate()
    }

    public func handoffFrame() throws -> Int64 { try ramp.frame(at: 8) }

    private static func makePivot(
        fromKey: Int, fromMode: String, toKey: Int, toMode: String
    ) throws -> SongPlan.Chord {
        guard [0, 2, 3, 5, 7, 10].contains(fromKey), [0, 2, 3, 5, 7, 10].contains(toKey),
            ["major", "minor"].contains(fromMode), ["major", "minor"].contains(toMode)
        else { throw TimelineError.invalidSchedule }
        func scale(_ key: Int, _ mode: String) -> Set<Int> {
            let intervals = mode == "major" ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
            return Set(intervals.map { (key + $0) % 12 })
        }
        func distance(_ a: Int, _ b: Int) -> Int { min((a - b + 12) % 12, (b - a + 12) % 12) }
        let common = scale(fromKey, fromMode).intersection(scale(toKey, toMode))
        var selected: (rank: (Int, Int, Int), tones: [Int])?
        for root in common.sorted() {
            var tones = [root]
            for interval in [7, 4, 3, 9, 2, 5] {
                let pitch = (root + interval) % 12
                if common.contains(pitch) && tones.allSatisfy({ distance(pitch, $0) >= 2 }) {
                    tones.append(pitch)
                }
                if tones.count == 4 { break }
            }
            let score =
                tones.count * 3 + (tones.contains((root + 7) % 12) ? 2 : 0)
                + (root == toKey ? 1 : 0)
            let rank = (score, -distance(root, fromKey), -root)
            if selected == nil || rank > (selected?.rank ?? (0, 0, 0)) {
                selected = (rank, tones)
            }
        }
        guard let tones = selected?.tones, let chosenRoot = tones.first else {
            throw TimelineError.invalidSchedule
        }
        let root = SongPlan.transpose(36 + chosenRoot, by: 0, into: 31...45)
        var voices = tones.map { SongPlan.transpose(48 + $0, by: 0, into: 50...66) }.sorted()
        while voices.count < 3 { voices.append(voices[0] + 12 <= 67 ? voices[0] + 12 : voices[0]) }
        voices = Set(voices).sorted()
        let tops = voices.filter { (55...69).contains($0) }
        return SongPlan.Chord(
            name: "shared pivot", root: root, voices: voices,
            tops: tops.isEmpty ? [voices.last ?? root] : tops, pcs: tones.sorted())
    }
}
