// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let originRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongOriginTests {
    @Test func nativeScheduleMatchesIntegerTranslationAcrossResetAndPartitions() throws {
        var planner = try SongPlanner(controls: Controls(variation: 0, tempo: 60))
        _ = try planner.next()
        try planner.setControls(Controls(variation: 0, tempo: 100))
        let predecessor = try planner.next()
        let song = try planner.next()
        let arrival = try SongTransition(
            from: predecessor, to: song, startSeconds: 86_400.123456)
        let schedule = try SongSchedule(
            song: song, successor: planner.pending, incoming: arrival)
        let origin = try schedule.frame(at: 0)
        let fades = try SongRackFades(schedule: schedule)
        let events = try EventPlanner.events(for: schedule).filter { $0.beat < 9 }
        let handoff = try arrival.handoffFrame() - origin
        let frames = Int(handoff) + 32_000
        try #require(origin > 0 && !events.isEmpty)
        try #require(events.contains { $0.instrument == .kick })
        #expect(fades.tonalInStartFrame == Double(origin))
        #expect(fades.rhythmInFrame == Double(origin + handoff))
        let shiftedFades = SongRackFades(
            tonalInStartFrame: fades.tonalInStartFrame - Double(origin),
            tonalInEndFrame: fades.tonalInEndFrame - Double(origin),
            tonalOutStartFrame: fades.tonalOutStartFrame - Double(origin),
            tonalOutEndFrame: fades.tonalOutEndFrame - Double(origin),
            rhythmInFrame: fades.rhythmInFrame - Double(origin),
            rhythmOutFrame: fades.rhythmOutFrame - Double(origin))
        let preparer = try TonalSamplePreparer(
            bankURL: originRoot.appendingPathComponent("Lowlight/SoundBank"))
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: events, warmth: 0.78, busEnergy: song.energy,
            rackFades: fades, frameOrigin: UInt64(origin))
        let zero = try TonalVoiceMixer(
            preparer: preparer, events: translate(events, subtracting: origin), warmth: 0.78,
            busEnergy: song.energy, rackFades: shiftedFades)
        #expect(mixer.position == UInt64(origin) && zero.position == 0)
        #expect(mixer.preparedBytes == zero.preparedBytes)
        let expected = try render(zero, frames: frames, partitions: [512])
        let actual = try render(mixer, frames: frames, partitions: [1, 17, 257, 1023])
        #expect(actual == expected)
        #expect(mixer.position == UInt64(origin) + UInt64(frames))
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        let beforeHandoff = actual[..<(Int(handoff) * 9)]
        #expect(
            beforeHandoff.enumerated().allSatisfy {
                $0.offset % 9 < 4 || $0.offset % 9 == 8 || Float(bitPattern: $0.element) == 0
            })
        #expect(actual.enumerated().contains { (6...7).contains($0.offset % 9) && $0.element != 0 })
        #expect(
            actual.enumerated().contains { $0.offset % 9 == 8 && Float(bitPattern: $0.element) < 1 }
        )
        mixer.reset()
        #expect(mixer.position == UInt64(origin) && mixer.activeVoices == 0)
        #expect(actual == (try render(mixer, frames: frames, partitions: [64, 511])))
    }

    @Test func invalidOriginsRejectBeforeSampleDecoding() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Valid metadata without PCM makes any accidental preparation fail with a different error.
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: originRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: temporary.appendingPathComponent(name))
        }
        let preparer = try TonalSamplePreparer(bankURL: temporary)
        let events = try NoteEvent.importReference(
            Data(
                contentsOf: originRoot.appendingPathComponent(
                    "tests/fixtures/voices-v9/events.json")))
        let first = try #require(events.first)
        let later = try #require(events.first { $0.startFrame > first.startFrame })
        for (origin, score) in [
            (UInt64(first.startFrame + 1), [first]),
            (UInt64(first.startFrame + 1), [later, first]),
            (UInt64(1 << 52) + 1, [first]), (UInt64.max, [first]),
        ] {
            do {
                _ = try TonalVoiceMixer(
                    preparer: preparer, events: score, warmth: 0.78, frameOrigin: origin)
                Issue.record("Invalid origin accepted: \(origin)")
            } catch VoiceMixerError.invalidScore {}  // Other errors propagate and fail the test.
        }
        let boundary = try TonalVoiceMixer(
            preparer: preparer, events: [], warmth: 0.78, frameOrigin: 1 << 52)
        #expect(boundary.position == 1 << 52 && boundary.preparedBytes == 0)
        boundary.reset()
        #expect(boundary.position == 1 << 52)
    }

    private func translate(_ events: [NoteEvent], subtracting origin: Int64) throws -> [NoteEvent] {
        var records = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(events)) as? [[String: Any]])
        for index in records.indices {
            for field in ["startFrame", "gateEndFrame", "releaseEndFrame"] {
                let value = try #require(records[index][field] as? NSNumber).int64Value
                records[index][field] = value - origin
            }
        }
        return try JSONDecoder().decode(
            [NoteEvent].self, from: JSONSerialization.data(withJSONObject: records))
    }

    private func render(_ mixer: TonalVoiceMixer, frames: Int, partitions: [Int]) throws -> [UInt32]
    {
        var output = [UInt32]()
        var buffer = [RhythmBusFrame](repeating: RhythmBusFrame(), count: partitions.max() ?? 1)
        var position = 0
        var block = 0
        output.reserveCapacity(frames * 9)
        while position < frames {
            let count = min(partitions[block % partitions.count], frames - position)
            try buffer.withUnsafeMutableBufferPointer {
                try #require(
                    mixer.renderBuses(into: UnsafeMutableBufferPointer(rebasing: $0[..<count])))
            }
            for frame in buffer.prefix(count) {
                output.append(
                    contentsOf: [
                        frame.guitar.0, frame.guitar.1, frame.piano.0, frame.piano.1,
                        frame.bass.0, frame.bass.1, frame.drums.0, frame.drums.1, frame.duck,
                    ].map(\.bitPattern))
            }
            position += count
            block += 1
        }
        return output
    }
}
