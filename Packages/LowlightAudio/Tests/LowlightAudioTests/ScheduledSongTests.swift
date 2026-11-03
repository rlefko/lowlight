// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let scheduledRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized)
struct ScheduledSongTests {
    @Test func firstNativeScheduleMatchesExplicitPreparation() throws {
        var timeline = try SessionTimeline()
        let schedule = try timeline.next()
        let preparer = try bank()
        #expect(schedule.song.energy != schedule.song.controls.energy)
        #expect(schedule.song.focus == "piano")
        #expect(try EventPlanner.events(for: schedule).count == 603)
        let expected = try explicit(schedule, preparer)
        let actual = try PreparedSong(schedule: schedule, preparer: preparer)
        #expect(actual.layout.frameOrigin == 0 && actual.preparedBytes == 25_485_636)
        try compare(actual, expected)
    }

    @Test func incomingNativeScheduleRestoresHostileCallerAndMatchesExplicitPreparation() throws {
        let controls = Controls(
            energy: 0.1, warmth: 0.41, space: 0.81, texture: 0.03, variation: 0.55, tempo: 60)
        var planner = try SongPlanner(controls: controls)
        _ = try planner.next()
        var updated = controls
        updated.tempo = 100
        try planner.setControls(updated)
        let predecessor = try planner.next()
        let song = try planner.next()
        let arrival = try SongTransition(
            from: predecessor, to: song, startSeconds: 86_400.123456)
        let schedule = try SongSchedule(
            song: song, successor: planner.pending, incoming: arrival)
        let preparer = try bank()
        #expect(song.focus == "guitar" && song.energy != song.controls.energy)
        #expect(arrival.ramp.fromTempo == 60 && arrival.ramp.toTempo == 100)
        #expect(try EventPlanner.events(for: schedule).count == 369)
        let expected = try explicit(schedule, preparer)
        let actual = try PreparationModeTests().environment(2, ll_test_flush_modes() - 1, true) {
            try PreparedSong(schedule: schedule, preparer: preparer)
        }
        #expect(actual.layout.frameOrigin == UInt64(try schedule.frame(at: 0)))
        #expect(actual.layout.frameOrigin > 0 && actual.layout.inputFrames == 2_395_514)
        try compare(actual, expected)
    }

    @Test func invalidScheduleRejectsBeforeDecodingAndRestoresCaller() throws {
        var timeline = try SessionTimeline()
        let schedule = try timeline.next()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: scheduledRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: temporary.appendingPathComponent(name))
        }
        let missingPCM = try TonalSamplePreparer(bankURL: temporary)
        let data = try JSONEncoder().encode(schedule)
        for (key, value) in [("focus", "invalid" as Any), ("takeSeed", UInt64(1 << 31) as Any)] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var song = try #require(object["song"] as? [String: Any])
            song[key] = value
            object["song"] = song
            let invalid = try JSONDecoder().decode(
                SongSchedule.self, from: JSONSerialization.data(withJSONObject: object))
            do {
                _ = try PreparationModeTests().environment(3, ll_test_flush_modes() - 1, true) {
                    try PreparedSong(schedule: invalid, preparer: missingPCM)
                }
                Issue.record("An invalid schedule reached sample preparation")
            } catch PlanningError.invalidCheckpoint {}
        }
        var planner = try SongPlanner(controls: Controls(variation: 0, tempo: 100))
        let predecessor = try planner.next()
        let next = try planner.next()
        let arrival = try SongTransition(
            from: predecessor, to: next,
            startSeconds: Double(MusicalTime.maximumFrame) / 32_000 - 69)
        let overflowing = try SongSchedule(
            song: next, successor: planner.pending, incoming: arrival)
        try overflowing.validate()  // The form fits; its required five-second tail does not.
        do {
            _ = try PreparationModeTests().environment(1, ll_test_flush_modes() - 1, false) {
                try PreparedSong(schedule: overflowing, preparer: missingPCM)
            }
            Issue.record("An out-of-range finite layout reached sample preparation")
        } catch SongRenderLayoutError.invalidLayout {}
    }

    @Test func nativeSchedulePreservesSampleCapacityFailure() throws {
        struct Oracle: Decodable {
            struct Chain: Decodable { let plans: [SongPlan] }
            let chains: [Chain]
        }
        let oracle = try JSONDecoder().decode(
            Oracle.self,
            from: Data(
                contentsOf: scheduledRoot.appendingPathComponent(
                    "tests/fixtures/planning-v1/events.json")))
        let plans = oracle.chains[1].plans
        let first = try SongSchedule(song: plans[0], successor: plans[1])
        let schedule = try SongSchedule(
            song: plans[1], successor: plans[2], incoming: first.outgoing)
        #expect(try EventPlanner.events(for: schedule).count == 856)
        do {
            _ = try PreparedSong(schedule: schedule, preparer: bank())
            Issue.record("A 73-key native score bypassed the unchanged 64-sample limit")
        } catch VoiceMixerError.capacityExceeded {}
    }

    private func bank() throws -> TonalSamplePreparer {
        try TonalSamplePreparer(bankURL: scheduledRoot.appendingPathComponent("Lowlight/SoundBank"))
    }

    /// The existing public primitives supply every input independently of the new adapter.
    private func explicit(_ schedule: SongSchedule, _ preparer: TonalSamplePreparer) throws
        -> PreparedSong
    {
        let song = schedule.song
        return try PreparedSong(
            layout: SongRenderLayout(schedule: schedule), preparer: preparer,
            events: EventPlanner.events(for: schedule), takeSeed: UInt32(song.takeSeed),
            focus: song.focus == "guitar" ? .guitar : .piano,
            warmth: song.controls.warmth, energy: song.energy, space: song.controls.space,
            texture: song.controls.texture, rackFades: SongRackFades(schedule: schedule))
    }

    private func compare(_ actual: PreparedSong, _ expected: PreparedSong) throws {
        #expect(actual.layout == expected.layout && actual.position == 0 && !actual.isFaulted)
        #expect(actual.measurement == expected.measurement)
        #expect(actual.gainDecibels.bitPattern == expected.gainDecibels.bitPattern)
        #expect(actual.linearMultiplier.bitPattern == expected.linearMultiplier.bitPattern)
        #expect(actual.preparedBytes == expected.preparedBytes)
        var lhs = [Float](repeating: .nan, count: 2048)
        var rhs = lhs
        var total = 0
        var equal = true
        while true {
            let count = try #require(lhs.withUnsafeMutableBufferPointer { actual.render(into: $0) })
            let other = try #require(
                rhs.withUnsafeMutableBufferPointer { expected.render(into: $0) })
            equal = equal && count == other && lhs.map(\.bitPattern) == rhs.map(\.bitPattern)
            total += count
            if count == 0 { break }
        }
        #expect(equal && total == Int(actual.layout.inputFrames))
        #expect(actual.stolenVoices == 0 && actual.droppedEvents == 0 && !actual.isFaulted)
        actual.reset()
        expected.reset()
        #expect(actual.position == 0 && actual.measurement == expected.measurement)
        for count in [1, 159, 160, 161, 511] {
            let actualCount = lhs.withUnsafeMutableBufferPointer {
                actual.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
            }
            let expectedCount = rhs.withUnsafeMutableBufferPointer {
                expected.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
            }
            #expect(actualCount == count && expectedCount == count)
            #expect(
                Array(lhs.prefix(count * 2)).map(\.bitPattern)
                    == Array(rhs.prefix(count * 2)).map(\.bitPattern))
        }
    }
}
