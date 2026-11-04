// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct SessionPlanningTests {
    private let low = Controls(
        energy: 0.58, mood: 0.35, warmth: 0.86, space: 0.42, texture: 0.08,
        variation: 0.60, tempo: 60)
    private var high: Controls {
        var value = low
        value.tempo = 100
        return value
    }
    private struct Step {
        let schedule: SongSchedule
        let beats: [Double]
        let frames: [Int64]
        let checkpoint: Data
    }

    @Test func completeTransactionsMatchCanonicalPlanningAcrossCallerModes() throws {
        let (initial, steps) = try PreparationMode.perform { try reference() }
        // Frozen with the pre-owner planner, independently of the implementation under test.
        #expect(steps[0].frames == [0, 256_000, 512_000, 548_000, 4_096_000, 4_608_000])
        #expect(
            steps[2].frames == [7_168_000, 7_388_940, 7_560_314, 7_581_914, 9_096_314, 9_403_514])
        for rounding in UInt32(0)..<4 {
            for flush in 0..<ll_test_flush_modes() {
                for flags in [false, true] {
                    func scoped<Value>(_ body: () throws -> Value) throws -> Value {
                        try PreparationModeTests().environment(rounding, flush, flags, body)
                    }
                    var planning = try scoped { try SessionPlanning(controls: low) }
                    #expect(planning.current == nil && planning.positionFrame == nil)
                    #expect(try scoped { try planning.checkpoint() } == initial)
                    planning = try scoped { try SessionPlanning.restore(initial) }
                    for (index, step) in steps.enumerated() {
                        if index == 1 { try scoped { try planning.setControls(high) } }
                        if index == 3 { try scoped { try planning.setControls(low) } }
                        let next = try PreparationModeTests().environment(
                            (rounding + UInt32(index) + 1) % 4, flush, flags
                        ) { try planning.next() }
                        #expect(next == step.schedule)
                        let frames = try step.beats.map { beat in
                            try scoped { try planning.frame(at: beat) }
                        }
                        #expect(frames == step.frames)
                        try scoped { try planning.setPosition(frame: step.frames[3]) }
                        let checkpoint = try scoped { try planning.checkpoint() }
                        #expect(checkpoint == step.checkpoint)
                        #expect(planning.current == step.schedule)
                        #expect(planning.positionFrame == step.frames[3])
                        if index == 2 {
                            planning = try scoped { try SessionPlanning.restore(checkpoint) }
                            #expect(planning.current == step.schedule)
                            #expect(planning.positionFrame == step.frames[3])
                        }
                    }
                }
            }
        }
    }

    @Test func invalidOperationsRestoreCallerAndPreserveIntent() throws {
        func scoped<Value>(_ body: () throws -> Value) throws -> Value {
            try PreparationModeTests().environment(2, ll_test_flush_modes() - 1, true, body)
        }
        #expect(throws: PlanningError.invalidControls) {
            try scoped { _ = try SessionPlanning(controls: Controls(energy: .nan)) }
        }
        let planning = try SessionPlanning(controls: low)
        let initial = try planning.checkpoint()
        #expect(throws: TimelineError.invalidTime) {
            try scoped { try planning.setPosition(frame: 0) }
        }
        #expect(throws: TimelineError.invalidTime) {
            try scoped { _ = try planning.frame(at: 0) }
        }
        #expect(try planning.checkpoint() == initial && planning.current == nil)
        let schedule = try planning.next()
        let end = try planning.frame(at: Double(schedule.song.bars * 4))
        try planning.setPosition(frame: end)
        let before = try planning.checkpoint()
        for frame in [-1, end + 1, Int64.max] {
            #expect(throws: TimelineError.invalidTime) {
                try scoped { try planning.setPosition(frame: frame) }
            }
        }
        for beat in [-1, Double(bitPattern: 0x8000_0000_0000_0001), .nan, .infinity, 1e300] {
            #expect(throws: TimelineError.invalidTime) {
                try scoped { _ = try planning.frame(at: beat) }
            }
        }
        #expect(throws: PlanningError.invalidControls) {
            try scoped { try planning.setControls(Controls(tempo: .infinity)) }
        }
        #expect(try planning.checkpoint() == before)
        #expect(planning.current == schedule && planning.positionFrame == end)
        var object = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        object["version"] = -1
        let invalidVersion = try JSONSerialization.data(withJSONObject: object)
        for data in [Data("{".utf8), Data(repeating: 32, count: 131_073), invalidVersion] {
            #expect(throws: (any Error).self) {
                try scoped { _ = try SessionPlanning.restore(data) }
            }
        }
        #expect(try planning.checkpoint() == before)
    }

    @Test func failedAdvancePreservesTheWholeCheckpoint() throws {
        let data = try PreparationMode.perform { try nearEndCheckpoint() }
        let planning = try SessionPlanning.restore(data)
        let before = try planning.checkpoint()
        let current = planning.current
        let position = planning.positionFrame
        #expect(throws: TimelineError.invalidTime) {
            try PreparationModeTests().environment(3, ll_test_flush_modes() - 1, false) {
                _ = try planning.next()
            }
        }
        #expect(try planning.checkpoint() == before)
        #expect(planning.current == current && planning.positionFrame == position)
    }

    @Test func seededPairRejectsItsFiniteWindowBeforeSampleDecoding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: temporary.appendingPathComponent(name))
        }
        let missing = try TonalSamplePreparer(bankURL: temporary)
        #expect(throws: PreparedSongPairError.invalidPair) {
            try PreparationModeTests().environment(1, ll_test_flush_modes() - 1, true) {
                _ = try PreparedSongPair(controls: low, frameCount: 1, preparer: missing)
            }
        }
    }

    @inline(never)
    private func reference() throws -> (Data, [Step]) {
        var timeline = try SessionTimeline(controls: low)
        let initial = try timeline.checkpoint()
        var steps: [Step] = []
        for index in 0..<6 {
            if index == 1 { try timeline.setControls(high) }
            if index == 3 { try timeline.setControls(low) }
            let schedule = try timeline.next()
            let beats = [
                0, 8, 16, 17.125, Double(schedule.song.bars * 4 - 16),
                Double(schedule.song.bars * 4),
            ]
            let frames = try beats.map { try schedule.frame(at: $0) }
            try timeline.setPosition(frame: frames[3])
            steps.append(
                Step(
                    schedule: schedule, beats: beats, frames: frames,
                    checkpoint: try timeline.checkpoint()))
        }
        return (initial, steps)
    }

    @inline(never)
    private func nearEndCheckpoint() throws -> Data {
        var timeline = try SessionTimeline(controls: low)
        var planner = try SongPlanner(controls: low)
        let first = try planner.next()
        let second = try planner.next()
        _ = try timeline.next()
        _ = try timeline.next()
        let start = Double(MusicalTime.maximumFrame) / 32_000 - Double(second.bars * 4) - 1
        let arrival = try SongTransition(from: first, to: second, startSeconds: start)
        let current = try SongSchedule(song: second, successor: planner.pending, incoming: arrival)
        var object = try #require(
            JSONSerialization.jsonObject(with: timeline.checkpoint()) as? [String: Any])
        object["current"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
        object["positionFrame"] = try current.frame(at: 0)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
