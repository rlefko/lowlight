// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let placementRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct ReferencePlacementTests {
    @Test func laterReferenceNotesMatchLocalizedLegacyAudioAcrossReset() throws {
        let data = try Data(
            contentsOf: placementRoot.appendingPathComponent(
                "tests/fixtures/reference-placement-v9/events.json"))
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        // These original guitar/piano notes both differ by one frame under absolute rounding.
        let selected = [raw[3], raw[4]]
        let selectedData = try JSONSerialization.data(withJSONObject: selected)
        let origin: Int64 = 3_150_769
        let placed = try NoteEvent.importReference(selectedData, placingAt: origin)
        let legacy = try NoteEvent.importReference(selectedData)
        #expect(placed.map(\.startFrame) != legacy.map(\.startFrame))
        let localized = selected.map { record in
            var record = record
            record["time"] = record["local_time"]
            return record
        }
        // The established zero-origin importer supplies the independent audio path.
        let zeroEvents = try NoteEvent.importReference(
            JSONSerialization.data(withJSONObject: localized))
        let preparer = try TonalSamplePreparer(
            bankURL: placementRoot.appendingPathComponent("Lowlight/SoundBank"))
        func fades(_ origin: Int64) -> SongRackFades {
            SongRackFades(
                tonalInStartFrame: Double(origin), tonalInEndFrame: Double(origin + 64_000),
                tonalOutStartFrame: Double(origin + 64_000),
                tonalOutEndFrame: Double(origin + 96_000), rhythmOutFrame: Double(origin + 80_000))
        }
        let expected = try TonalVoiceMixer(
            preparer: preparer, events: zeroEvents, warmth: 0.78, busEnergy: 0.35,
            rackFades: fades(0))
        let actual = try TonalVoiceMixer(
            preparer: preparer, events: placed, warmth: 0.78, busEnergy: 0.35,
            rackFades: fades(origin), frameOrigin: UInt64(origin))
        #expect(actual.position == UInt64(origin))
        #expect(actual.preparedBytes == expected.preparedBytes)
        let reference = try render(expected, partitions: [512])
        let output = try render(actual, partitions: [1, 17, 257, 1023])
        #expect(output == reference)
        #expect(
            output.enumerated().contains {
                $0.offset % 9 < 4 && Float(bitPattern: $0.element) != 0
            })
        #expect(actual.position == UInt64(origin + 32_000))
        #expect(actual.stolenVoices == 0 && actual.droppedEvents == 0)
        actual.reset()
        #expect(actual.position == UInt64(origin) && actual.activeVoices == 0)
        #expect(try render(actual, partitions: [63, 511]) == reference)
    }

    private func render(_ mixer: TonalVoiceMixer, partitions: [Int]) throws -> [UInt32] {
        var result: [UInt32] = []
        var buffer = [RhythmBusFrame](
            repeating: RhythmBusFrame(), count: try #require(partitions.max()))
        var position = 0
        var block = 0
        while position < 32_000 {
            let count = min(partitions[block % partitions.count], 32_000 - position)
            try #require(
                buffer.withUnsafeMutableBufferPointer {
                    mixer.renderBuses(into: UnsafeMutableBufferPointer(rebasing: $0[..<count]))
                })
            for frame in buffer.prefix(count) {
                let values = [
                    frame.guitar.0, frame.guitar.1, frame.piano.0, frame.piano.1,
                    frame.bass.0, frame.bass.1, frame.drums.0, frame.drums.1, frame.duck,
                ]
                result.append(contentsOf: values.map(\.bitPattern))
            }
            position += count
            block += 1
        }
        #expect(result.allSatisfy { Float(bitPattern: $0).isFinite })
        return result
    }
}
