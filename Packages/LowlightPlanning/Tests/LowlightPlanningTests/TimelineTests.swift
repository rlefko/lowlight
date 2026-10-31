// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightPlanning

struct TimelineTests {
    @Test func everyKeyAndModePairSharesEveryBridgeBeatAndMicrostep() throws {
        let grammar = try Grammar.bundled()
        var planner = try SongPlanner()
        let bases = try (0..<4).map { _ in try planner.next() }
        let major = try #require(bases.first { $0.mode == "major" })
        let minor = try #require(bases.first { $0.mode == "minor" })
        let variants = try [major, minor].flatMap { base in
            try grammar.keys.map { try transposed(base, key: $0, grammar: grammar) }
        }
        #expect(variants.count == 12)
        for from in variants {
            for to in variants {
                for tempos in [(60.0, 100.0), (100.0, 60.0)] {
                    for origin in [0.0, 86_400.123456] {
                        let pair = try schedules(from: from, to: to, tempos: tempos, origin: origin)
                        let overlap = Double(pair.0.song.bars * 4 - 16)
                        #expect(pair.0.outgoing == pair.1.incoming)
                        let pivot = pair.0.outgoing.pivot
                        let common = scale(from).intersection(scale(to))
                        #expect(Set(pivot.pcs).isSubset(of: common))
                        #expect(pivot.pcs.contains(pivot.root % 12))
                        for (index, pitch) in pivot.pcs.enumerated() {
                            for other in pivot.pcs.dropFirst(index + 1) {
                                #expect(
                                    min((pitch - other + 12) % 12, (other - pitch + 12) % 12) >= 2)
                            }
                        }
                        for quarter in 0...64 {
                            for offset in [0.0, 0.000001] {
                                let beat = min(16, Double(quarter) / 4 + offset)
                                let outgoing = try pair.0.frame(at: overlap + beat)
                                let incoming = try pair.1.frame(at: beat)
                                if offset == 0 {
                                    #expect(outgoing == incoming)
                                } else {
                                    // Adding/subtracting the overlap offset can lose Double ulps.
                                    #expect(abs(outgoing - incoming) <= 1)
                                }
                                let slope = (tempos.1 - tempos.0) / 16
                                let expected =
                                    pair.0.outgoing.ramp.startSeconds
                                    + 60 * log((tempos.0 + slope * beat) / tempos.0) / slope
                                #expect(
                                    abs(
                                        outgoing
                                            - Int64((expected * 32_000).rounded(.toNearestOrEven)))
                                        <= 1)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func fadesAreTimeLinearAndRhythmHasOneOwnerIncludingCutoff() throws {
        let chain = try EventOracle.load().chains[1]
        let schedules = try chain.schedules()
        for (outgoing, incoming) in zip(schedules, schedules.dropFirst()) {
            let transition = outgoing.outgoing
            let start = try transition.ramp.frame(at: 0)
            let end = try transition.ramp.frame(at: 16)
            let handoff = try transition.handoffFrame()
            #expect(try outgoing.tonalGain(atFrame: start) == 1)
            #expect(try incoming.tonalGain(atFrame: start) == 0)
            #expect(try outgoing.tonalGain(atFrame: end) == 0)
            #expect(try incoming.tonalGain(atFrame: end) == 1)
            for step in 0...64 {
                let frame = start + (end - start) * Int64(step) / 64
                let progress = Double(frame - start) / Double(end - start)
                #expect(abs(try incoming.tonalGain(atFrame: frame) - progress) <= 1e-12)
                #expect(
                    abs(
                        try outgoing.tonalGain(atFrame: frame) + incoming.tonalGain(atFrame: frame)
                            - 1) <= 1e-12)
                #expect(
                    try outgoing.rhythmGain(atFrame: frame) * incoming.rhythmGain(atFrame: frame)
                        == 0)
            }
            // A ramp's beat midpoint is not its elapsed-time midpoint.
            #expect(abs(try incoming.tonalGain(atFrame: handoff) - 0.5) > 0.05)
            #expect(try outgoing.rhythmGain(atFrame: handoff - 2_400) == 1)
            #expect(try outgoing.rhythmGain(atFrame: handoff - 1_200) == 0.5)
            #expect(try outgoing.rhythmGain(atFrame: handoff) == 0)
            #expect(try incoming.rhythmGain(atFrame: handoff - 1) == 0)
            #expect(try incoming.rhythmGain(atFrame: handoff) == 1)

            // Cross-song bass is monophonic after applying the outgoing rack cutoff.
            let oldBass = try EventPlanner.events(for: outgoing).filter { $0.instrument == .bass }
            let newBass = try EventPlanner.events(for: incoming).filter { $0.instrument == .bass }
            let oldEnd = oldBass.map { min($0.releaseEndFrame, handoff) }.max() ?? 0
            #expect(oldEnd <= (newBass.first?.startFrame ?? .max))
        }
    }

    @Test func checkpointPreservesPlanningContinuationAndExplicitFrameIntent() throws {
        var timeline = try SessionTimeline(seed: 12345)
        #expect(timeline.current == nil && timeline.positionFrame == nil)
        var pristine = try SessionTimeline.restore(timeline.checkpoint())
        #expect(try pristine.checkpoint() == timeline.checkpoint())
        #expect(throws: TimelineError.invalidTime) { try pristine.setPosition(frame: 0) }
        for _ in 0..<20 { _ = try timeline.next() }
        let current = try #require(timeline.current)
        let position = try current.frame(at: Double(current.song.bars * 4 - 5))
        try timeline.setPosition(frame: position)
        try timeline.setControls(Controls(energy: 0.9, mood: -0.8, tempo: 100))
        let checkpoint = try timeline.checkpoint()
        var restored = try SessionTimeline.restore(checkpoint)
        #expect(try restored.checkpoint() == checkpoint)
        #expect(restored.positionFrame == position && restored.current == current)
        for index in 0..<60 {
            let wanted = try timeline.next()
            let got = try restored.next()
            #expect(got == wanted && restored.positionFrame == timeline.positionFrame)
            #expect(restored.positionFrame == max(position, try got.frame(at: 0)))
            if index == 0 {
                #expect(restored.positionFrame == position)
                #expect(try EventPlanner.events(for: got) == EventPlanner.events(for: wanted))
            }
        }
        #expect(try restored.checkpoint() == timeline.checkpoint())
        let latest = try #require(restored.current)
        let start = try latest.frame(at: 0)
        let end = try latest.frame(at: Double(latest.song.bars * 4))
        for frame in [start, end] {
            try restored.setPosition(frame: frame)
            #expect(restored.positionFrame == frame)
        }
        for frame in [-1, start - 1, end + 1, Int64.max] {
            #expect(throws: TimelineError.invalidTime) { try restored.setPosition(frame: frame) }
        }
        #expect(restored.positionFrame == end)
        let unchanged = try restored.checkpoint()
        #expect(throws: PlanningError.invalidControls) {
            try restored.setControls(Controls(energy: .nan))
        }
        #expect(try restored.checkpoint() == unchanged)
    }

    @Test func longTimelineDoesNotAccumulateOverlapDriftAndStateStaysBounded() throws {
        var timeline = try SessionTimeline(seed: 91_031)
        var previous: SongSchedule?
        for index in 0..<1_100 {
            let schedule = try timeline.next()
            if let previous {
                #expect(schedule.incoming == previous.outgoing)
                #expect(
                    try schedule.frame(at: 0)
                        == previous.frame(at: Double(previous.song.bars * 4 - 16)))
                #expect(
                    try schedule.frame(at: 16) == previous.frame(at: Double(previous.song.bars * 4))
                )
            }
            if index.isMultiple(of: 100) {
                let data = try timeline.checkpoint()
                #expect(data.count < 65_536)
                timeline = try SessionTimeline.restore(data)
            }
            previous = schedule
        }
        #expect(try #require(timeline.positionFrame) > 86_400 * 32_000)
    }

    @Test func invalidTimesFramesSchedulesAndCheckpointsAreRejected() throws {
        for value in [Double.nan, .infinity, -.infinity, -1, 1e300] {
            #expect(throws: TimelineError.invalidTime) { try MusicalTime.frame(value) }
            #expect(throws: TimelineError.invalidTime) {
                try TempoRamp(startSeconds: value, fromTempo: 60, toTempo: 100)
            }
        }
        #expect(try MusicalTime.frame(0.5 / 32_000) == 0)
        #expect(try MusicalTime.frame(1.5 / 32_000) == 2)
        #expect(try MusicalTime.frame(86_400) == 2_764_800_000)
        #expect(
            try MusicalTime.frame(Double(MusicalTime.maximumFrame) / 32_000)
                == MusicalTime.maximumFrame)
        for tempo in [Double.nan, .infinity, 59, 101] {
            #expect(throws: TimelineError.invalidTime) {
                try TempoRamp(startSeconds: 0, fromTempo: tempo, toTempo: 80)
            }
            #expect(throws: TimelineError.invalidTime) {
                try TempoRamp(startSeconds: 0, fromTempo: 80, toTempo: tempo)
            }
        }
        let constant = try TempoRamp(startSeconds: 123, fromTempo: 80, toTempo: 80)
        #expect(try constant.seconds(at: 16) == 135)
        for beat in [Double.nan, .infinity, -1, 16.001] {
            #expect(throws: TimelineError.invalidTime) { try constant.frame(at: beat) }
        }
        var timeline = try SessionTimeline()
        let first = try timeline.next()
        let data = try timeline.checkpoint()
        for key in ["version", "positionFrame"] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[key] = -1
            #expect(throws: (any Error).self) {
                try SessionTimeline.restore(JSONSerialization.data(withJSONObject: object))
            }
        }
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["current"] = NSNull()
        #expect(throws: TimelineError.invalidCheckpoint) {
            try SessionTimeline.restore(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: (any Error).self) { try SessionTimeline.restore(data.dropLast()) }
        #expect(throws: TimelineError.invalidCheckpoint) {
            try SessionTimeline.restore(Data(repeating: 32, count: 131_073))
        }
        for beat in [Double.nan, .infinity, -1, 1e300] {
            #expect(throws: TimelineError.invalidTime) { try first.frame(at: beat) }
        }
        for frame in [-1, Int64.max] {
            #expect(throws: TimelineError.invalidTime) { try first.tonalGain(atFrame: frame) }
            #expect(throws: TimelineError.invalidTime) { try first.rhythmGain(atFrame: frame) }
        }
        var invalid = first.song
        invalid.id = 9
        #expect(throws: (any Error).self) { try SongSchedule(song: invalid, successor: first.song) }
    }

    @Test func decodedScheduleClockCorruptionFailsWithoutOverflow() throws {
        let schedule = try EventOracle.load().chains[1].schedules()[1]
        let original = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule)) as? [String: Any])
        for (key, value) in [("bars", Int.max as Any), ("tempo", 59), ("tempo", 1e300)] {
            var object = original
            var song = try #require(object["song"] as? [String: Any])
            song[key] = value
            object["song"] = song
            let bad = try JSONDecoder().decode(
                SongSchedule.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) { try bad.validate() }
            #expect(throws: TimelineError.invalidSchedule) { try bad.frame(at: 0) }
            #expect(throws: (any Error).self) { try EventPlanner.events(for: bad) }
        }
        var object = original
        var incoming = try #require(object["incoming"] as? [String: Any])
        incoming["toID"] = 999
        object["incoming"] = incoming
        let bad = try JSONDecoder().decode(
            SongSchedule.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: TimelineError.invalidSchedule) { try bad.validate() }
        #expect(throws: TimelineError.invalidSchedule) { try EventPlanner.events(for: bad) }
    }

    private func transposed(_ source: SongPlan, key: Int, grammar: Grammar) throws -> SongPlan {
        var result = source
        let family = try #require(grammar.families.first { $0.id == source.family })
        result.key = key
        result.shift = (key - family.baseKey + 6) % 12 - 6
        result.chords = try family.progression.map {
            try SongPlan.chord($0, shift: result.shift, grammar: grammar)
        }
        result.melody = source.melody.map {
            $0.map { SongPlan.transpose($0, by: key - source.key, into: 55...69) }
        }
        return result
    }

    private func scale(_ plan: SongPlan) -> Set<Int> {
        let intervals = plan.mode == "major" ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        return Set(intervals.map { (plan.key + $0) % 12 })
    }

    private func schedules(from: SongPlan, to: SongPlan, tempos: (Double, Double), origin: Double)
        throws -> (SongSchedule, SongSchedule)
    {
        var old = from
        old.id = 1
        old.tempo = tempos.0
        var new = to
        new.id = 2
        new.tempo = tempos.1
        var predecessor = old
        predecessor.id = 0
        var successor = new
        successor.id = 3
        let arrival = try SongTransition(from: predecessor, to: old, startSeconds: origin)
        let outgoing = try SongSchedule(song: old, successor: new, incoming: arrival)
        let incoming = try SongSchedule(
            song: new, successor: successor, incoming: outgoing.outgoing)
        return (outgoing, incoming)
    }
}
