// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightPlanning

struct EventOracle: Decodable {
    struct Chain: Decodable {
        struct Case: Decodable {
            let index: Int
            let events: [NoteEvent]
            let pivot: SongPlan.Chord
            let bridgeFrames: [Int64]
        }
        let plans: [SongPlan]
        let cases: [Case]

        func schedules() throws -> [SongSchedule] {
            var result: [SongSchedule] = []
            for (song, successor) in zip(plans, plans.dropFirst()) {
                result.append(
                    try SongSchedule(
                        song: song, successor: successor, incoming: result.last?.outgoing))
            }
            return result
        }
    }
    let schemaVersion: Int
    let chains: [Chain]

    static func data(_ path: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("tests/fixtures/" + path))
    }

    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: data("planning-v1/events.json"))
    }
}

struct EventTests {
    @Test func nativeScoresMatchIndependentFrozenPythonEventsInOrder() throws {
        // These tolerances were fixed before implementation: one absolute frame,
        // 1e-12 for scalar metadata. Expected data is never generated from Swift.
        let oracle = try EventOracle.load()
        #expect(oracle.schemaVersion == 1 && EventPlanner.algorithmVersion == 1)
        #expect(NoteEvent.formatVersion == 1)
        var coverage: [NoteEvent] = []
        for chain in oracle.chains {
            let schedules = try chain.schedules()
            for item in chain.cases {
                let schedule = schedules[item.index]
                let actual = try EventPlanner.events(for: schedule)
                #expect(actual.count == item.events.count)
                #expect(actual == (try EventPlanner.events(for: schedule)))
                for (got, wanted) in zip(actual, item.events) {
                    #expect(got.instrument == wanted.instrument && got.role == wanted.role)
                    #expect(got.articulation == wanted.articulation && got.note == wanted.note)
                    #expect(got.roundRobin == wanted.roundRobin)
                    #expect(abs(got.beat - wanted.beat) <= 1e-12)
                    #expect(abs(got.velocity - wanted.velocity) <= 1e-12)
                    #expect(abs(got.pan - wanted.pan) <= 1e-12)
                    #expect(abs(got.startFrame - wanted.startFrame) <= 1)
                    #expect(abs(got.gateEndFrame - wanted.gateEndFrame) <= 1)
                    #expect(abs(got.releaseEndFrame - wanted.releaseEndFrame) <= 1)
                }
                #expect(schedule.outgoing.pivot == item.pivot)
                for (quarter, frame) in item.bridgeFrames.enumerated() {
                    let beat = Double(schedule.song.bars * 4 - 16) + Double(quarter) / 4
                    #expect(abs(try schedule.frame(at: beat) - frame) <= 1)
                }
                #expect(
                    try JSONDecoder().decode([NoteEvent].self, from: JSONEncoder().encode(actual))
                        == actual)
                coverage += actual
            }
        }
        #expect(coverage.count == 2_322)
        #expect(Set(coverage.map(\.instrument)) == Set(NoteEvent.Instrument.allCases))
        #expect(
            Set(coverage.map(\.role.rawValue))
                == Set(["chord", "support", "melody", "answer", "bass", "drum", "ghost"]))
        #expect(Set(coverage.map(\.articulation.rawValue)) == Set(["normal", "soft", "connected"]))
    }

    @Test func reviewedV9ScoreImportsWithoutNativePlanValidationOrRandomDraws() throws {
        let data = try EventOracle.data("v9/events.json")
        let imported = try NoteEvent.importReference(data)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(imported.count == 621 && raw.count == imported.count)
        #expect(imported == (try NoteEvent.importReference(data)))
        for (event, source) in zip(imported, raw) {
            let time = try #require(source["time"] as? Double)
            let duration = try #require(source["duration"] as? Double)
            let release = try #require(source["release"] as? Double)
            #expect(event.startFrame == Int64((time * 32_000).rounded(.toNearestOrEven)))
            #expect(
                event.gateEndFrame == Int64(((time + duration) * 32_000).rounded(.toNearestOrEven)))
            #expect(
                event.releaseEndFrame
                    == Int64(((time + duration + release) * 32_000).rounded(.toNearestOrEven)))
            #expect(event.instrument.rawValue == source["instrument"] as? String)
            #expect(event.role.rawValue == source["role"] as? String)
            #expect(event.articulation.rawValue == source["articulation"] as? String)
            #expect(event.note == source["note"] as? Int)
            #expect(event.roundRobin == source["round_robin"] as? Int)
            #expect(abs(event.beat - (try #require(source["beat"] as? Double))) <= 1e-12)
            #expect(abs(event.velocity - (try #require(source["velocity"] as? Double))) <= 1e-12)
            #expect(abs(event.pan - (try #require(source["pan"] as? Double))) <= 1e-12)
        }
        // Stable ties retain the source's kick-before-hat emission order.
        #expect(imported[0].startFrame == 0 && imported[1].startFrame == 0)
        #expect(imported[0].instrument == .kick && imported[1].instrument == .hat)
        #expect(imported[0].gateEndFrame == 9_846 && imported[0].releaseEndFrame == 17_846)
    }

    @Test func dampingBoundariesAndBoundedHarmonicIntervals() throws {
        for chain in try EventOracle.load().chains {
            for schedule in try chain.schedules() {
                let events = try EventPlanner.events(for: schedule)
                #expect(events.count <= NoteEvent.capacity)
                #expect(
                    zip(events, events.dropFirst()).allSatisfy { $0.startFrame <= $1.startFrame })
                var previous: [String: NoteEvent] = [:]
                var points: [(Int64, Int)] = []
                for event in events where [.guitar, .piano, .bass].contains(event.instrument) {
                    try event.validate()
                    let key =
                        event.instrument.rawValue
                        + (event.instrument == .bass ? "" : "\(event.note)")
                    if let prior = previous[key] {
                        #expect(prior.releaseEndFrame <= event.startFrame + 1)
                    }
                    previous[key] = event
                    points += [(event.startFrame, 1), (event.releaseEndFrame, -1)]
                    if event.instrument != .bass {
                        for bar in (Int(event.beat / 4) + 1)..<schedule.song.bars {
                            let boundary = try schedule.frame(at: Double(bar * 4))
                            if boundary >= event.releaseEndFrame { break }
                            let chord =
                                bar < 4 && schedule.incoming != nil
                                ? schedule.incoming?.pivot
                                : bar >= schedule.song.bars - 4
                                    ? schedule.outgoing.pivot : schedule.song.chords[bar % 8]
                            #expect(try #require(chord).pcs.contains(event.note % 12))
                        }
                    }
                }
                var active = 0
                var maximum = 0
                for (_, change) in points.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
                    active += change
                    maximum = max(maximum, active)
                }
                // Event envelopes only; sampled percussion and effect tails need DSP validation.
                #expect(maximum <= 16 && active == 0)
                let rhythm = events.filter { ![.guitar, .piano].contains($0.instrument) }
                #expect(rhythm.allSatisfy { $0.beat < Double(schedule.song.bars * 4 - 8) })
                if schedule.incoming != nil { #expect(rhythm.allSatisfy { $0.beat >= 8 }) }
            }
        }
    }

    @Test func invalidImportedMetadataTimingAndCapacityAreRejected() throws {
        let raw = try #require(
            JSONSerialization.jsonObject(with: EventOracle.data("v9/events.json"))
                as? [[String: Any]])
        let mutations: [(String, Any)] = [
            ("instrument", "unknown"), ("role", "melody"), ("articulation", "unknown"),
            ("note", 128), ("round_robin", 11), ("beat", -1), ("beat", 176),
            ("velocity", -0.01), ("velocity", 1.01), ("pan", 1.01),
            ("time", -1), ("time", 1e300), ("local_time", -1), ("local_time", 1),
            ("duration", 0), ("duration", 17), ("release", -1), ("release", 6),
        ]
        for (key, value) in mutations {
            var bad = raw[0]
            bad[key] = value
            #expect(throws: (any Error).self) {
                try NoteEvent.importReference(JSONSerialization.data(withJSONObject: [bad]))
            }
        }
        for bad in [[], Array(raw.prefix(4).reversed()), Array(repeating: raw[0], count: 2_049)] {
            #expect(throws: (any Error).self) {
                try NoteEvent.importReference(JSONSerialization.data(withJSONObject: bad))
            }
        }
        var shifted = raw[3]
        shifted["time"] = 1.0
        #expect(throws: EventError.invalidReference) {
            try NoteEvent.importReference(
                JSONSerialization.data(withJSONObject: [raw[0], shifted]))
        }
        for literal in ["NaN", "Infinity", "-Infinity"] {
            let bad = try JSONSerialization.data(withJSONObject: [raw[0]])
            let text = try #require(String(data: bad, encoding: .utf8))
                .replacingOccurrences(of: "\"time\":0", with: "\"time\":" + literal)
            #expect(throws: (any Error).self) { try NoteEvent.importReference(Data(text.utf8)) }
        }
        #expect(throws: EventError.invalidReference) {
            try NoteEvent.importReference(Data(repeating: 32, count: 2_097_153))
        }
    }

    @Test func nativeEncodingCarriesVersionAndRejectsInvalidEndpoints() throws {
        let event = try #require(EventOracle.load().chains.first?.cases.first?.events.first)
        let encoded = try JSONEncoder().encode(event)
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(original["formatVersion"] as? Int == 1)
        var legacy = original
        legacy.removeValue(forKey: "formatVersion")
        #expect(
            try JSONDecoder().decode(
                NoteEvent.self, from: JSONSerialization.data(withJSONObject: legacy)) == event)
        for (key, value) in [
            ("formatVersion", 2 as Any), ("formatVersion", NSNull()), ("formatVersion", "1"),
            ("startFrame", -1), ("gateEndFrame", 0), ("releaseEndFrame", 0),
            ("releaseEndFrame", Int64.max), ("gateEndFrame", 999_999),
            ("releaseEndFrame", 999_999), ("velocity", "NaN"),
        ] {
            var bad = original
            bad[key] = value
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(
                    NoteEvent.self, from: JSONSerialization.data(withJSONObject: bad))
            }
        }
    }
}
