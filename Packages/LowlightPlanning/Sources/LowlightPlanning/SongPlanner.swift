// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct FallbackDiagnostic: Codable, Equatable, Sendable {
    let attempts, relaxedSignatures: Int
    let planID: UInt64
}

struct NoveltyHistory: Codable, Equatable, Sendable {
    var families: [String] = []
    var signatures: [String] = []
    var lastFallback: FallbackDiagnostic?

    mutating func select(draft: ([String]) throws -> SongPlan) throws -> SongPlan {
        // The fixed catalog retains at least eight candidates in either mode.
        var candidate = try draft(families)
        var attempts = 1
        while signatures.contains(candidate.signature) && attempts < 128 {
            candidate = try draft(families)
            attempts += 1
        }
        if let lastMatch = signatures.lastIndex(of: candidate.signature) {
            signatures.removeFirst(lastMatch + 1)
            lastFallback = FallbackDiagnostic(
                attempts: attempts, relaxedSignatures: lastMatch + 1, planID: candidate.id)
        }
        families = Array((families + [candidate.family]).suffix(4))
        signatures = Array((signatures + [candidate.signature]).suffix(64))
        return candidate
    }
}

public struct SongPlanner {
    public static let algorithmVersion = 1
    private struct Checkpoint: Codable {
        var algorithmVersion = SongPlanner.algorithmVersion
        var catalogVersion = Grammar.version
        var rng: SeededGenerator
        var controls: Controls
        var index: UInt64
        var pending: SongPlan
        var history: NoveltyHistory
    }

    private let grammar: Grammar
    private var state: Checkpoint
    public var pending: SongPlan { state.pending }
    var recentFamilies: [String] { state.history.families }
    var recentSignatures: [String] { state.history.signatures }
    var lastFallback: FallbackDiagnostic? { state.history.lastFallback }

    public init(seed: UInt64 = 91_031, controls: Controls = Controls()) throws {
        let grammar = try Grammar.bundled()
        let controls = try controls.normalized()
        var rng = SeededGenerator(seed: seed)
        var history = NoveltyHistory()
        let pending = try Self.prepare(
            id: 0, controls: controls, previous: nil, grammar: grammar, rng: &rng, history: &history
        )
        self.grammar = grammar
        state = Checkpoint(
            rng: rng, controls: controls, index: 1, pending: pending, history: history)
    }

    private init(grammar: Grammar, state: Checkpoint) {
        self.grammar = grammar
        self.state = state
    }

    public mutating func setControls(_ controls: Controls) throws {
        state.controls = try controls.normalized()
    }

    public mutating func next() throws -> SongPlan {
        let result = state.pending
        var updated = state
        updated.pending = try Self.prepare(
            id: state.index, controls: state.controls, previous: result, grammar: grammar,
            rng: &updated.rng, history: &updated.history)
        updated.index &+= 1
        state = updated
        return result
    }

    public func checkpoint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state)
    }

    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw PlanningError.invalidCheckpoint }
        let state: Checkpoint
        do { state = try JSONDecoder().decode(Checkpoint.self, from: data) } catch {
            throw PlanningError.invalidCheckpoint
        }
        guard state.algorithmVersion == algorithmVersion, state.catalogVersion == Grammar.version
        else { throw PlanningError.unsupportedVersion }
        let grammar = try Grammar.bundled()
        try state.pending.validate(using: grammar)
        let history = state.history
        guard try state.controls.normalized() == state.controls,
            state.index == state.pending.id &+ 1,
            (1...4).contains(history.families.count), (1...64).contains(history.signatures.count),
            Set(history.families).count == history.families.count,
            Set(history.signatures).count == history.signatures.count,
            history.families.allSatisfy({ id in grammar.families.contains { $0.id == id } }),
            history.signatures.allSatisfy({ SongPlan.validSignature($0, grammar: grammar) }),
            history.families.last == state.pending.family,
            history.signatures.last == state.pending.signature
        else { throw PlanningError.invalidCheckpoint }
        if let diagnostic = history.lastFallback {
            guard diagnostic.attempts == 128, (1...64).contains(diagnostic.relaxedSignatures),
                diagnostic.planID <= state.pending.id
            else { throw PlanningError.invalidCheckpoint }
        }
        return Self(grammar: grammar, state: state)
    }

    private static func prepare(
        id: UInt64, controls: Controls, previous: SongPlan?, grammar: Grammar,
        rng: inout SeededGenerator, history: inout NoveltyHistory
    ) throws -> SongPlan {
        var plan = try history.select { excluded in
            try draft(
                id: id, controls: controls, previous: previous, grammar: grammar,
                rng: &rng, excluded: excluded)
        }
        plan.takeSeed = UInt64(rng.index(1 << 31))
        plan.drumCell = rng.index(6)
        plan.bassCell = rng.index(4)
        plan.phraseArc = grammar.phraseArcs[rng.index(grammar.phraseArcs.count)]
        return plan
    }

    private static func draft(
        id: UInt64, controls: Controls, previous: SongPlan?, grammar: Grammar,
        rng: inout SeededGenerator, excluded: [String]
    ) throws -> SongPlan {
        let minor = rng.unit() < 0.5 - 0.46 * controls.mood
        let pool = grammar.families.filter {
            ($0.mode == "minor") == minor && !excluded.contains($0.id)
        }
        guard !pool.isEmpty else { throw PlanningError.invalidCatalog }
        let family = pool[rng.index(pool.count)]
        let key: Int
        if let previous {
            let related = [0, 5, 7, 3, 9].map { (previous.key + $0) % 12 }
            let choices = grammar.keys.filter(related.contains)
            key =
                rng.unit() < 0.45 * controls.variation
                ? choices[rng.index(choices.count)] : previous.key
        } else {
            key = grammar.keys[rng.index(grammar.keys.count)]
        }
        let shift = (key - family.baseKey + 6) % 12 - 6
        let energy = min(
            1, max(0, controls.energy + (rng.unit() * 0.12 - 0.06) * controls.variation))
        var tempo = controls.tempo ?? 64 + 34 * energy
        if let previous, previous.controls.energy == controls.energy,
            previous.controls.tempo == controls.tempo
        {
            tempo = min(previous.tempo + 3, max(previous.tempo - 3, tempo))
        }
        tempo = (tempo * 100).rounded(.toNearestOrEven) / 100
        let focus: String
        if let previous, rng.unit() > 0.40 {
            focus = previous.focus
        } else {
            focus = ["guitar", "piano"][rng.index(2)]
        }
        let bars = grammar.forms[rng.index(grammar.forms.count)]
        let contour = grammar.contours[rng.index(grammar.contours.count)]
        let register = 59 + rng.index(4)
        let chords = try family.progression.map {
            try SongPlan.chord($0, shift: shift, grammar: grammar)
        }
        var melody: [[Int]] = []
        var times: [[Int]] = []
        var previousNote = 61
        for (bar, chord) in chords.enumerated() {
            let target = register + contour[bar]
            let candidates = chord.pcs.flatMap { pc in (55...69).filter { $0 % 12 == pc } }
            // Keep pitch-class order and the first tie, as in the accepted planner.
            guard
                let anchor = candidates.min(by: {
                    Double(abs($0 - target)) + 0.28 * Double(abs($0 - previousNote))
                        < Double(abs($1 - target)) + 0.28 * Double(abs($1 - previousNote))
                })
            else { throw PlanningError.invalidCatalog }
            let lower = candidates.filter { (anchor - 5..<anchor).contains($0) }.sorted(by: >)
            let answer = lower.isEmpty ? anchor : lower[rng.index(min(2, lower.count))]
            let ending = lower.last ?? anchor
            let count = SongPlan.noteCount(energy: energy, bar: bar)
            let notes = Array([anchor, answer, ending, answer].prefix(count))
            melody.append(notes)
            times.append(SongPlan.times(for: count))
            previousNote = notes.last ?? anchor
        }
        return SongPlan(
            id: id, family: family.id, mode: family.mode, focus: focus,
            key: key, shift: shift, bars: bars, drumCell: 0, bassCell: 0,
            controls: controls, energy: energy, tempo: tempo, chords: chords,
            melody: melody, melodyTimes: times, takeSeed: 0, phraseArc: [])
    }
}
