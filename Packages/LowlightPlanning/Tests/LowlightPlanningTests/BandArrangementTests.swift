// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightPlanning

struct BandArrangementTests {
    @Test func ensemblesTradePlacesAndScoresSurviveRestore() throws {
        for seed: UInt64 in [91_031, 17, 509] {
            var timeline = try SessionTimeline(seed: seed, edition: .evolving)
            var bands: [SongEnsemble] = []
            for _ in 0..<6 {
                let saved = try timeline.checkpoint()
                var restored = try SessionTimeline.restore(saved)
                #expect(try restored.checkpoint() == saved)
                let schedule = try timeline.next()
                let ensemble = try #require(schedule.song.ensemble)
                #expect(try restored.next() == schedule)
                #expect(ensemble != bands.last)
                bands.append(ensemble)
                let events = try EventPlanner.events(for: schedule)
                #expect(!events.isEmpty && events.count <= NoteEvent.capacity)
                #expect(
                    zip(events, events.dropFirst()).allSatisfy { $0.startFrame <= $1.startFrame })
                #expect(events.contains { $0.color != nil && $0.role == .melody })
                #expect(events.contains { $0.color == nil && $0.role == .answer })
                let allowed: Set<BandColor> =
                    switch ensemble {
                    case .pocket: [.electricPiano]
                    case .mallets: [.vibraphone]
                    case .reed: [.tenor, .electricPiano]
                    }
                #expect(Set(events.compactMap(\.color)) == allowed)
                let outgoing = try schedule.outgoing.handoffFrame()
                let incoming = try schedule.incoming?.handoffFrame() ?? 0
                #expect(
                    events.filter { !$0.instrument.harmonic }.allSatisfy {
                        $0.startFrame >= incoming && $0.startFrame < outgoing
                    })
            }
            #expect(Set(bands[0..<3]) == Set(SongEnsemble.allCases))
            #expect(Set(bands[3..<6]) == Set(SongEnsemble.allCases))
        }
    }

    @Test func hookReturnsWithAnAnswerAndContrast() throws {
        var timeline = try SessionTimeline(seed: 17, edition: .evolving)
        let schedule = try timeline.next()
        let events = try EventPlanner.events(for: schedule)
        struct Gesture: Equatable {
            let tick, note: Int
            let role: NoteEvent.Role
        }
        func phrase(_ bar: Int) -> [Gesture] {
            events.filter {
                Int($0.beat / 4) == bar && ($0.role == .melody || $0.role == .answer)
            }.map {
                Gesture(
                    tick: Int((($0.beat - Double(4 * bar)) * 4).rounded()), note: $0.note,
                    role: $0.role)
            }
        }
        let returnBar = schedule.song.bars - 12
        #expect(!phrase(4).isEmpty)
        #expect(phrase(4) == phrase(returnBar))
        #expect(phrase(11) != phrase(returnBar + 7))
        let rhythms = (0..<schedule.song.bars).map { phrase($0).map(\.tick) }
        #expect(Set(rhythms.filter { !$0.isEmpty }).count >= 5)
        #expect(rhythms.contains([]))
        #expect(rhythms.contains { $0.contains { !$0.isMultiple(of: 4) } })

        let attacks = events.filter { $0.role == .melody || $0.role == .answer }
        #expect(zip(attacks, attacks.dropFirst()).contains { $0.note < $1.note })
        #expect(zip(attacks, attacks.dropFirst()).contains { $0.note > $1.note })
        #expect(
            try JSONDecoder().decode([NoteEvent].self, from: JSONEncoder().encode(events)) == events
        )
    }

    @Test func legacyUpgradeKeepsCurrentMusicAndPromotesFirstFutureHandoff() throws {
        var original = try SessionTimeline(seed: 91_031)
        let current = try original.next()
        let saved = try original.checkpoint()
        var upgraded = try SessionTimeline.restore(saved)
        let oldSuccessor = try original.next()
        upgraded.useEvolvingSuccessors()
        let promotedState = try upgraded.checkpoint()
        upgraded.useEvolvingSuccessors()
        #expect(try upgraded.checkpoint() == promotedState)
        #expect(upgraded.current == current)
        #expect(current.song.ensemble == nil)
        var replay = try SessionTimeline.restore(promotedState)
        let next = try upgraded.next()
        #expect(try replay.next() == next)
        #expect(next.song.ensemble != nil)
        #expect(next.incoming == oldSuccessor.incoming)
        #expect(next.song.id == oldSuccessor.song.id && next.song.tempo == oldSuccessor.song.tempo)
        #expect(
            next.song.key == oldSuccessor.song.key && next.song.chords == oldSuccessor.song.chords)
        #expect(next.song.melodyTimes != oldSuccessor.song.melodyTimes)
    }

    @Test func aQuietGuideToneCarriesTheBreakdownThroughTheSecondBar() throws {
        var timeline = try SessionTimeline(
            seed: 17, controls: Controls(tempo: 60), edition: .evolving)
        var forms: Set<Int> = []
        for _ in 0..<16 {
            let schedule = try timeline.next()
            let form = schedule.song.bars
            guard form >= 36 else { continue }
            forms.insert(form)
            let first = form == 44 ? 20 : 12
            let score = try EventPlanner.events(for: schedule)
            let bar = score.filter { Int($0.beat / 4) == first + 1 }
            let pedal = try #require(bar.first)
            #expect(bar.count == 1 && pedal.role == .support && pedal.velocity <= 0.23)
            #expect(pedal.beat == Double((first + 1) * 4))
            #expect(pedal.gateEndFrame >= (try schedule.frame(at: pedal.beat + 3.5)))
            let chord = schedule.song.chords[(first + 5) % 8]
            let shared = score.filter {
                Int($0.beat / 4) == first && $0.role == .chord && chord.pcs.contains($0.note % 12)
            }
            #expect(chord.pcs.contains(pedal.note % 12))
            #expect(shared.isEmpty || shared.contains { $0.note == pedal.note })
        }
        #expect(forms == [36, 44])
    }

    @Test func corruptMotifTimingOrEditionIsRejected() throws {
        let data = try SongPlanner(edition: .evolving).checkpoint()
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for ticks in [[4, 4], [-1], [16], [0, 2, 4, 6, 8]] {
            var record = original
            var pending = try #require(record["pending"] as? [String: Any])
            var times = try #require(pending["melodyTimes"] as? [[Int]])
            times[0] = ticks
            pending["melodyTimes"] = times
            record["pending"] = pending
            #expect(throws: PlanningError.invalidCheckpoint) {
                try SongPlanner.restore(JSONSerialization.data(withJSONObject: record))
            }
        }
        var mismatched = original
        mismatched["algorithmVersion"] = 1
        #expect(throws: PlanningError.invalidCheckpoint) {
            try SongPlanner.restore(JSONSerialization.data(withJSONObject: mismatched))
        }
    }
}
