// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct SongPlan: Codable, Equatable, Sendable {
    public struct Chord: Codable, Equatable, Sendable {
        public internal(set) var name: String
        public internal(set) var root: Int
        public internal(set) var voices, tops, pcs: [Int]
    }

    public internal(set) var id: UInt64
    public internal(set) var family, mode, focus: String
    public internal(set) var key, shift, bars, drumCell, bassCell: Int
    public internal(set) var controls: Controls
    public internal(set) var energy, tempo: Double
    public internal(set) var chords: [Chord]
    public internal(set) var melody, melodyTimes: [[Int]]
    public internal(set) var takeSeed: UInt64
    public internal(set) var phraseArc: [Double]

    /// Exact canonical text; no randomized hashing or floating-point formatting.
    public var signature: String {
        let phrases = zip(melody, melodyTimes).map { notes, times in
            zip(notes, times).map { note, beat in "\((note % 12 - key % 12 + 24) % 12)@\(beat)" }
                .joined(separator: ",")
        }.joined(separator: ";")
        return "ll-song-v1|" + chords.map(\.name).joined(separator: ",") + "|" + phrases
    }

    static func times(for count: Int) -> [Int] {
        switch count {
        case 1: [0]
        case 2: [0, 2]
        case 3: [0, 2, 3]
        default: [0, 1, 2, 3]
        }
    }

    static func transpose(_ note: Int, by shift: Int, into range: ClosedRange<Int>) -> Int {
        var value = note + shift
        while value < range.lowerBound { value += 12 }
        while value > range.upperBound { value -= 12 }
        return value
    }

    static func chord(_ name: String, shift: Int, grammar: Grammar) throws -> Chord {
        guard let source = grammar.chords[name] else { throw PlanningError.invalidCatalog }
        return Chord(
            name: name, root: transpose(source.root, by: shift, into: 31...45),
            voices: source.voices.map { transpose($0, by: shift, into: 50...66) }.sorted(),
            tops: Set(source.tops.map { transpose($0, by: shift, into: 55...69) }).sorted(),
            pcs: Set(([source.root] + source.voices + source.tops).map { ($0 + shift) % 12 })
                .sorted())
    }

    func validate(using grammar: Grammar) throws {
        guard let entry = grammar.families.first(where: { $0.id == family }), mode == entry.mode,
            grammar.keys.contains(key), shift == (key - entry.baseKey + 6) % 12 - 6,
            try controls.normalized() == controls, energy.isFinite, (0...1).contains(energy),
            abs(energy - controls.energy) <= 0.06 * controls.variation + 1e-12,
            tempo.isFinite, (60...100).contains(tempo),
            abs(tempo * 100 - (tempo * 100).rounded(.toNearestOrEven)) < 1e-8,
            grammar.forms.contains(bars), ["guitar", "piano"].contains(focus),
            (0..<6).contains(drumCell), (0..<4).contains(bassCell), takeSeed < 1 << 31,
            grammar.phraseArcs.contains(phraseArc), melody.count == 8, melodyTimes.count == 8,
            try chords
                == entry.progression.map({ try Self.chord($0, shift: shift, grammar: grammar) })
        else { throw PlanningError.invalidCheckpoint }
        for bar in 0..<8 {
            let count = Self.noteCount(energy: energy, bar: bar)
            guard melody[bar].count == count, melodyTimes[bar] == Self.times(for: count),
                melody[bar].allSatisfy({
                    (55...69).contains($0) && chords[bar].pcs.contains($0 % 12)
                })
            else { throw PlanningError.invalidCheckpoint }
        }
    }

    static func noteCount(energy: Double, bar: Int) -> Int {
        if energy < 0.22 && [3, 7].contains(bar) { return 1 }
        return 2 + (energy > 0.38 && bar.isMultiple(of: 2) ? 1 : 0)
            + (energy > 0.78 && bar % 4 == 2 ? 1 : 0)
    }

    static func validSignature(_ value: String, grammar: Grammar) -> Bool {
        guard value.utf8.count <= 512 else { return false }
        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ll-song-v1" else { return false }
        let progression = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(
            String.init)
        guard grammar.families.contains(where: { $0.progression == progression }) else {
            return false
        }
        let bars = parts[2].split(separator: ";", omittingEmptySubsequences: false)
        guard bars.count == 8 else { return false }
        return bars.allSatisfy { bar in
            let notes = bar.split(separator: ",", omittingEmptySubsequences: false)
            guard (1...4).contains(notes.count) else { return false }
            return zip(notes, times(for: notes.count)).allSatisfy { note, time in
                let fields = note.split(separator: "@", omittingEmptySubsequences: false)
                guard fields.count == 2, let pitch = Int(fields[0]), (0..<12).contains(pitch)
                else { return false }
                return fields[0] == String(pitch) && fields[1] == String(time)
            }
        }
    }
}
