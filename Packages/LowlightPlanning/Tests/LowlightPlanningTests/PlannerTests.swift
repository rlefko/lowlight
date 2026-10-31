// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightPlanning

struct PlannerTests {
    @Test func nativeSequenceMatchesIndependentReferenceAdapter() throws {
        // Frozen Python _draft with a separately implemented SplitMix64 adapter, seed 91031.
        // This is a native-v1 sequence, not a claim of Python random.Random compatibility.
        var planner = try SongPlanner()
        let plans = try (0..<4).map { _ in try planner.next() }
        #expect(plans.map(\.family) == ["M01", "M02", "m08", "m01"])
        #expect(plans.map(\.key) == [10, 10, 10, 3])
        #expect(plans.map(\.tempo) == [76.67, 75.25, 75.55, 75.07])
        #expect(plans.map(\.bars) == [36, 28, 28, 36])
        #expect(plans.map(\.focus) == ["piano", "piano", "guitar", "guitar"])
        #expect(plans.map(\.takeSeed) == [1_727_725_083, 308_749_880, 1_086_943_877, 750_251_057])
        #expect(
            plans[0].melody == [
                [62, 58], [60, 58], [58, 57], [62, 58], [62, 58], [58, 55], [60, 55], [60, 57],
            ])
        #expect(plans[0].melodyTimes == Array(repeating: [0, 2], count: 8))
        #expect(
            plans[0].signature == "ll-song-v1|Cmaj9,Cmaj9,Am9,Am9,Fmaj9,Fmaj9,Dm9,G6|"
                + "4@0,0@2;2@0,0@2;0@0,11@2;4@0,0@2;4@0,0@2;0@0,9@2;2@0,9@2;2@0,11@2")
    }

    @Test func presetsAndControlBoundary() throws {
        let expected: [(Preset, [Double])] = [
            (.focus, [0.35, 0.15, 0.78, 0.44, 0.09, 0.55]),
            (.relax, [0.10, 0.05, 0.88, 0.55, 0.07, 0.35]),
            (.commute, [0.58, 0.35, 0.72, 0.42, 0.08, 0.60]),
            (.workout, [0.88, 0.65, 0.63, 0.35, 0.06, 0.65]),
            (.reflective, [0.27, -0.80, 0.82, 0.50, 0.07, 0.50]),
        ]
        #expect(Preset.allCases.count == 5)
        for (preset, values) in expected {
            let c = try Controls.preset(preset)
            #expect([c.energy, c.mood, c.warmth, c.space, c.texture, c.variation] == values)
            #expect(c.tempo == nil)
        }
        #expect(try Controls.preset(.focus) == Controls())
        #expect(
            try Controls(
                energy: -1, mood: 2, warmth: 2, space: -1, texture: 2, variation: 2, tempo: 101
            ).normalized()
                == Controls(
                    energy: 0, mood: 1, warmth: 1, space: 0, texture: 1, variation: 1, tempo: 100))
        for value in [Double.nan, .infinity, -.infinity] {
            for invalid in [
                Controls(energy: value), Controls(mood: value), Controls(warmth: value),
                Controls(space: value), Controls(texture: value), Controls(variation: value),
                Controls(tempo: value),
            ] {
                #expect(throws: PlanningError.invalidControls) {
                    try SongPlanner(controls: invalid)
                }
            }
        }
    }

    @Test func signaturesRepresentComposition() throws {
        let original = try SongPlanner().pending
        var changed = original
        changed.key = (original.key + 2) % 12
        changed.melody = original.melody.map { $0.map { $0 + 2 } }
        changed.tempo = 90
        changed.focus = "guitar"
        changed.bars = 28
        changed.takeSeed += 1
        #expect(changed.signature == original.signature)
        changed = original
        changed.melody[0][0] += 1
        #expect(changed.signature != original.signature)
        changed = original
        changed.melodyTimes[0][1] = 3
        #expect(changed.signature != original.signature)
        changed = original
        changed.chords[0].name = "Fmaj9"
        #expect(changed.signature != original.signature)
        changed.key = .min
        changed.melody[0][0] = .max
        let decoded = try JSONDecoder().decode(SongPlan.self, from: JSONEncoder().encode(changed))
        #expect(decoded.signature.split(separator: "|").last?.hasPrefix("3@0,") == true)
    }

    @Test func checkpointContinuationPreservesPendingAndUpdatedControls() throws {
        var planner = try SongPlanner(seed: 12345)
        for _ in 0..<75 { _ = try planner.next() }
        let pending = planner.pending
        let updated = try Controls.preset(.workout)
        try planner.setControls(updated)
        let data = try planner.checkpoint()
        #expect(
            data.starts(
                with: Data("{\"algorithmVersion\":1,\"catalogVersion\":1,\"controls\":".utf8)))
        #expect(data == (try planner.checkpoint()))
        var restored = try SongPlanner.restore(data)
        #expect(try restored.checkpoint() == data)
        #expect(restored.pending == pending)
        for index in 0..<200 {
            #expect(try planner.next() == restored.next())
            if index == 0 { #expect(restored.pending.controls == updated) }
        }
        #expect(try planner.checkpoint() == restored.checkpoint())
        let unchanged = try planner.checkpoint()
        #expect(throws: PlanningError.invalidControls) {
            try planner.setControls(Controls(energy: .nan))
        }
        #expect(try planner.checkpoint() == unchanged)
    }

    @Test func malformedCheckpointsAreRejected() throws {
        var planner = try SongPlanner()
        for _ in 0..<70 { _ = try planner.next() }
        let data = try planner.checkpoint()
        var malformedHistory = planner.recentSignatures
        let comma = try #require(malformedHistory[0].range(of: ","))
        malformedHistory[0].replaceSubrange(comma, with: ",,")
        var badMelody = planner.pending.melody
        badMelody[0][0] = 127
        var badTimes = planner.pending.melodyTimes
        badTimes[0][0] = 1
        var badChords = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(planner.pending.chords))
                as? [[String: Any]])
        badChords[0]["root"] = 127
        let mutations: [([String], Any)] = [
            (["algorithmVersion"], 99), (["catalogVersion"], 99), (["rng"], "fffffffffffffffG"),
            (["index"], 0), (["controls", "energy"], 2), (["pending", "family"], "unknown"),
            (["pending", "melody"], []), (["pending", "tempo"], 12),
            (["pending", "melody"], badMelody), (["pending", "melodyTimes"], badTimes),
            (["pending", "chords"], badChords), (["pending", "energy"], 2),
            (["pending", "takeSeed"], 2_147_483_648),
            (["history", "families"], Array(repeating: "M00", count: 5)),
            (["history", "families"], ["M00", "M00"]),
            (["history", "signatures"], Array(repeating: planner.pending.signature, count: 65)),
            (["history", "signatures"], ["invalid"]),
            (["history", "signatures"], malformedHistory),
            (["history", "lastFallback"], ["attempts": 129, "relaxedSignatures": 1, "planID": 0]),
        ]
        for (path, value) in mutations {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            try replace(&object, path: path[...], value: value)
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try SongPlanner.restore(invalid) }
        }
        #expect(throws: (any Error).self) { try SongPlanner.restore(data.dropLast()) }
        #expect(throws: PlanningError.invalidCheckpoint) {
            try SongPlanner.restore(data + Data(repeating: 32, count: 65_536))
        }
    }

    @Test func longPlanningPreservesNoveltyAndMusicalBounds() throws {
        let grammar = try Grammar.bundled()
        #expect(grammar.keys == [0, 2, 3, 5, 7, 10])
        #expect(grammar.forms == [28, 36, 36, 44])
        #expect(grammar.families.count == 26 && grammar.contours.count == 6)
        var planner = try SongPlanner()
        var families: Set<String> = []
        var keys: Set<Int> = []
        var nominalSeconds = 0.0
        for index in 0..<3000 {
            let old = planner.pending
            let priorFamilies = planner.recentFamilies
            let priorSignatures = planner.recentSignatures
            #expect(try planner.next() == old)
            let next = planner.pending
            #expect(
                !priorFamilies.contains(next.family) && !priorSignatures.contains(next.signature))
            #expect(planner.recentFamilies.count <= 4 && planner.recentSignatures.count <= 64)
            #expect(abs(next.tempo - old.tempo) <= 3.000000001)
            #expect(next.id == old.id + 1 && [28, 36, 44].contains(next.bars))
            for (bar, chord) in next.chords.enumerated() {
                #expect(
                    (31...45).contains(chord.root)
                        && chord.voices.allSatisfy { (50...66).contains($0) })
                #expect(chord.tops.allSatisfy { (55...69).contains($0) })
                #expect(
                    next.melody[bar].allSatisfy {
                        (55...69).contains($0) && chord.pcs.contains($0 % 12)
                    })
                #expect([[0], [0, 2], [0, 2, 3], [0, 1, 2, 3]].contains(next.melodyTimes[bar]))
            }
            families.insert(next.family)
            keys.insert(next.key)
            nominalSeconds += Double(next.bars * 4 - 16) * 60 / next.tempo
            if index.isMultiple(of: 100) { #expect(try planner.checkpoint().count < 40_000) }
        }
        #expect(families.count == 26 && keys == Set(grammar.keys))
        #expect(nominalSeconds > 86_400 && planner.lastFallback == nil)
        #expect(planner.recentFamilies.count == 4 && planner.recentSignatures.count == 64)
    }

    @Test func energyAtFixedTempoAndZeroVariation() throws {
        let sparse = try SongPlanner(controls: Controls(energy: 0.1, variation: 0, tempo: 80))
            .pending
        var dense = try SongPlanner(controls: Controls(energy: 0.9, variation: 0, tempo: 80))
        #expect(sparse.tempo == 80 && dense.pending.tempo == 80)
        #expect(sparse.melody.flatMap { $0 }.count == 14)
        #expect(dense.pending.melody.flatMap { $0 }.count == 22)
        let plans = try (0..<80).map { _ in try dense.next() }
        #expect(Set(plans.map(\.signature)).count > 64)
        #expect(Set(plans.map(\.key)).count == 1)
        #expect(plans.allSatisfy { $0.energy == 0.9 && $0.tempo == 80 })
    }

    @Test func moodBiasWorksAtBothEnergyExtremes() throws {
        for energy in [0.1, 0.9] {
            for mood in [-1.0, 1.0] {
                var planner = try SongPlanner(
                    seed: 901,
                    controls: Controls(energy: energy, mood: mood, variation: 0, tempo: 80))
                var minor = 0
                for _ in 0..<256 { if try planner.next().mode == "minor" { minor += 1 } }
                // Broad bounds distinguish the authored 96%/4% bias from an unbiased draw.
                #expect(mood < 0 ? minor > 224 : minor < 32)
                #expect(planner.pending.energy == energy && planner.pending.tempo == 80)
            }
        }
    }

    @Test func exhaustedSearchRelaxesOnlyOldestSignaturePrefix() throws {
        var planner = try SongPlanner()
        let plans = try (0..<8).map { _ in try planner.next() }
        var candidate = plans[1]
        candidate.id = 8
        let families = plans.suffix(4).map(\.family)
        var history = NoveltyHistory(families: families, signatures: plans.map(\.signature))
        var repeated = history
        var calls = 0
        let selected = try history.select { excluded in
            calls += 1
            #expect(excluded == families && !excluded.contains(candidate.family))
            return candidate
        }
        #expect(try repeated.select { _ in candidate } == selected)
        #expect(history == repeated && calls == 128)
        #expect(history.signatures == plans.dropFirst(2).map(\.signature) + [candidate.signature])
        #expect(history.families == Array((families + [candidate.family]).suffix(4)))
        #expect(
            history.lastFallback
                == FallbackDiagnostic(attempts: 128, relaxedSignatures: 2, planID: 8))
    }

    private func replace(_ object: inout [String: Any], path: ArraySlice<String>, value: Any) throws
    {
        let key = try #require(path.first)
        if path.count == 1 {
            object[key] = value
            return
        }
        var child = try #require(object[key] as? [String: Any])
        try replace(&child, path: path.dropFirst(), value: value)
        object[key] = child
    }
}
