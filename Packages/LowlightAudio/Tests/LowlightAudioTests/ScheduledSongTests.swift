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
        let pool = SongPreparationPool()
        let actual = try pool.prepare(schedule: schedule, preparer: preparer)
        #expect(pool.reservedRacks == 1 && pool.reservedVoiceSlots == actual.requiredVoiceSlots)
        #expect(pool.preparedPCMBytes == actual.preparedBytes)
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

    @Test func nativeScheduleAdmissionPreservesPCMCapacity() throws {
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
        let preparer = try bank()
        let song = try PreparedSong(schedule: schedule, preparer: preparer)
        #expect(song.preparedBytes == 24_689_592 && song.position == 0)
        #expect(song.layout == (try SongRenderLayout(schedule: schedule)))
        #expect(song.measurement.integratedLUFS != nil && song.measurement.gatedBlocks > 0)
        var buffer = [Float](repeating: .nan, count: 2048)
        var prefix: [UInt32] = []
        var total = 0
        var finite = true
        while true {
            let count = try #require(
                buffer.withUnsafeMutableBufferPointer { song.render(into: $0) })
            if total == 0 { prefix = Array(buffer.prefix(1024)).map(\.bitPattern) }
            finite = finite && buffer.allSatisfy(\.isFinite)
            total += count
            if count == 0 { break }
        }
        #expect(total == Int(song.layout.inputFrames) && finite && !song.isFaulted)
        #expect(song.stolenVoices == 0 && song.droppedEvents == 0)
        #expect(buffer.allSatisfy { $0 == 0 } && prefix.contains { $0 & 0x7fff_ffff != 0 })
        song.reset()
        var replay: [UInt32] = []
        for count in [1, 159, 160, 192] {
            #expect(
                buffer.withUnsafeMutableBufferPointer {
                    song.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
                } == count)
            replay += buffer.prefix(count * 2).map(\.bitPattern)
        }
        #expect(replay == prefix && song.position == 512)

        var dense = try SessionTimeline(controls: Controls(energy: 1, variation: 1, tempo: 60))
        for _ in 0..<4 { _ = try dense.next() }
        let tooLarge = try dense.next()
        #expect(try EventPlanner.events(for: tooLarge).count == 700)
        // 77 normalized keys fit the registry, but their 33,970,508 PCM bytes exceed 32 MiB.
        do {
            _ = try PreparedSong(schedule: tooLarge, preparer: preparer)
            Issue.record("A native score bypassed the unchanged 32 MiB PCM limit")
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
