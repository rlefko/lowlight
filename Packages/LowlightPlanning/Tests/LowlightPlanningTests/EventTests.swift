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
    private struct ReferenceTiming: Decodable {
        struct Frames: Decodable {
            let startFrame, gateEndFrame, releaseEndFrame: Int64
            func matches(_ event: NoteEvent) -> Bool {
                event.startFrame == startFrame && event.gateEndFrame == gateEndFrame
                    && event.releaseEndFrame == releaseEndFrame
            }
        }
        struct Probe: Decodable {
            let id: String
            let rejected: Bool
            let expected: Frames?
        }
        let schemaVersion, sampleRate, frameTolerance: Int
        let events: [Frames]
        let probes: [Probe]

        static func load() throws -> Self {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(
                Self.self, from: EventOracle.data("reference-timing-v9/manifest.json"))
        }
    }

    private struct ReferencePlacement: Decodable {
        struct Case: Decodable {
            let id, eventsFile: String
            let frameOrigin: Int64
            let expected: [ReferenceTiming.Frames]
        }
        struct Probe: Decodable {
            let id: String
            let frameOrigin: Int64
            let rejected: Bool
            let expected: [ReferenceTiming.Frames]?
        }
        let schemaVersion, sampleRate, frameTolerance: Int
        let maximumFrame: Int64
        let cases: [Case]
        let probes: [Probe]
        let absoluteOnsetDifferenceIndices: [Int]
    }

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
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let encoded = try encoder.encode(actual)
                let decoded = try JSONDecoder().decode([NoteEvent].self, from: encoded)
                #expect(decoded == actual)
                #expect(try encoder.encode(decoded) == encoded)
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
        let timing = try ReferenceTiming.load()
        #expect(
            timing.schemaVersion == 1 && timing.sampleRate == 32_000 && timing.frameTolerance == 0)
        try #require(imported.count == 621 && raw.count == imported.count)
        try #require(timing.events.count == imported.count)
        #expect(imported == (try NoteEvent.importReference(data)))
        for (index, event) in imported.enumerated() {
            let source = raw[index]
            #expect(timing.events[index].matches(event))
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

    @Test func referenceVoiceTimingPreservesHalfFramesAndRejectsInvalidSpans() throws {
        let timing = try ReferenceTiming.load()
        let manifest = try #require(
            JSONSerialization.jsonObject(
                with: EventOracle.data("reference-timing-v9/manifest.json")) as? [String: Any])
        let raw = try #require(manifest["probes"] as? [[String: Any]])
        try #require(timing.probes.count == 15 && raw.count == timing.probes.count)
        for (probe, source) in zip(timing.probes, raw) {
            #expect(probe.id == source["id"] as? String)
            let event = try #require(source["event"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: [event])
            if probe.rejected {
                #expect(throws: EventError.invalidEvent) { try NoteEvent.importReference(data) }
            } else {
                let imported = try #require(NoteEvent.importReference(data).first)
                #expect(try #require(probe.expected).matches(imported))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let encoded = try encoder.encode(imported)
                let decoded = try JSONDecoder().decode(NoteEvent.self, from: encoded)
                #expect(decoded == imported)
                #expect(try encoder.encode(decoded) == encoded)
            }
        }
        for instrument in ["guitar", "piano", "bass"] {
            var event = try #require(
                raw.compactMap { $0["event"] as? [String: Any] }
                    .first { $0["instrument"] as? String == instrument })
            event["time"] = 0
            event["local_time"] = 0
            event["duration"] = 16
            event["release"] = 5
            let maximum = try #require(
                NoteEvent.importReference(JSONSerialization.data(withJSONObject: [event])).first)
            #expect(maximum.gateEndFrame == 512_000 && maximum.releaseEndFrame == 672_000)
            for (key, value) in [
                ("duration", Double(16).nextUp), ("release", Double(5).nextUp),
                ("time", Double(MusicalTime.maximumFrame) / MusicalTime.sampleRate),
            ] {
                var invalid = event
                invalid[key] = value
                #expect(throws: (any Error).self) {
                    try NoteEvent.importReference(JSONSerialization.data(withJSONObject: [invalid]))
                }
            }
        }
    }

    @Test func referenceLocalPlacementMatchesFrozenOriginalAndPreservesEncoding() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let oracle = try decoder.decode(
            ReferencePlacement.self,
            from: EventOracle.data("reference-placement-v9/manifest.json"))
        #expect(oracle.schemaVersion == 1 && oracle.sampleRate == 32_000)
        #expect(oracle.frameTolerance == 0 && oracle.maximumFrame == MusicalTime.maximumFrame)
        try #require(oracle.cases.count == 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for item in oracle.cases {
            let data = try EventOracle.data("reference-placement-v9/" + item.eventsFile)
            let placed = try NoteEvent.importReference(data, placingAt: item.frameOrigin)
            let local = try NoteEvent.importReference(data, placingAt: 0)
            let absolute = try NoteEvent.importReference(data)
            try #require(placed.count == 738 && placed.count == item.expected.count)
            #expect(placed == (try NoteEvent.importReference(data, placingAt: item.frameOrigin)))
            for (index, event) in placed.enumerated() {
                #expect(item.expected[index].matches(event))
                #expect(event.startFrame == local[index].startFrame + item.frameOrigin)
                #expect(event.gateEndFrame == local[index].gateEndFrame + item.frameOrigin)
                #expect(event.releaseEndFrame == local[index].releaseEndFrame + item.frameOrigin)
                #expect(
                    event.instrument == absolute[index].instrument
                        && event.role == absolute[index].role)
                #expect(
                    event.articulation == absolute[index].articulation
                        && event.note == absolute[index].note)
                #expect(
                    event.roundRobin == absolute[index].roundRobin
                        && event.beat == absolute[index].beat)
                #expect(
                    event.velocity == absolute[index].velocity && event.pan == absolute[index].pan)
            }
            let differences = placed.indices.filter {
                placed[$0].startFrame != absolute[$0].startFrame
            }
            #expect(differences == oracle.absoluteOnsetDifferenceIndices && !differences.isEmpty)
            let encoded = try encoder.encode(placed)
            let decoded = try JSONDecoder().decode([NoteEvent].self, from: encoded)
            let reencoded = try encoder.encode(decoded)
            #expect(decoded == placed && reencoded == encoded)
        }
        let first = try EventOracle.data("v9/events.json")
        #expect(
            try NoteEvent.importReference(first, placingAt: 0) == NoteEvent.importReference(first))
        #expect(NoteEvent.formatVersion == 1 && EventPlanner.algorithmVersion == 1)
    }

    @Test func referenceLocalPlacementValidatesBoundsOrderAndSourceClocks() throws {
        let data = try EventOracle.data("reference-placement-v9/manifest.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let oracle = try decoder.decode(ReferencePlacement.self, from: data)
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawProbes = try #require(manifest["probes"] as? [[String: Any]])
        try #require(rawProbes.count == 15 && oracle.probes.count == rawProbes.count)
        for (probe, raw) in zip(oracle.probes, rawProbes) {
            #expect(probe.id == raw["id"] as? String)
            let events = try #require(raw["events"] as? [[String: Any]])
            let data = try JSONSerialization.data(withJSONObject: events)
            if probe.rejected {
                #expect(throws: (any Error).self) {
                    try NoteEvent.importReference(data, placingAt: probe.frameOrigin)
                }
            } else {
                let placed = try NoteEvent.importReference(data, placingAt: probe.frameOrigin)
                let expected = try #require(probe.expected)
                try #require(placed.count == expected.count)
                #expect(zip(expected, placed).allSatisfy { $0.matches($1) })
            }
        }
        let raw = try #require(
            JSONSerialization.jsonObject(with: EventOracle.data("v9/events.json"))
                as? [[String: Any]])
        let one = try JSONSerialization.data(withJSONObject: [raw[0]])
        for origin in [
            Int64.min, -1, MusicalTime.maximumFrame, MusicalTime.maximumFrame + 1, Int64.max,
        ] {
            #expect(throws: (any Error).self) {
                try NoteEvent.importReference(one, placingAt: origin)
            }
        }
        var shifted = raw[3]
        shifted["time"] = 1.0
        for events in [
            [], [raw[3], raw[0]], [raw[0], shifted], Array(repeating: raw[0], count: 2049),
        ] {
            #expect(throws: (any Error).self) {
                try NoteEvent.importReference(
                    JSONSerialization.data(withJSONObject: events), placingAt: 37)
            }
        }
        for (key, value) in [
            ("time", -1.0), ("local_time", -1.0), ("duration", 0.0), ("release", 6.0),
            ("velocity", 1.1),
        ] {
            var invalid = raw[0]
            invalid[key] = value
            #expect(throws: (any Error).self) {
                try NoteEvent.importReference(
                    JSONSerialization.data(withJSONObject: [invalid]), placingAt: 37)
            }
        }
        #expect(throws: EventError.invalidReference) {
            try NoteEvent.importReference(Data(repeating: 32, count: 2_097_153), placingAt: 37)
        }
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
