// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let voiceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct VoiceMixerTests {
    @Test func emptyAndInvalidScores() throws {
        let preparer = try TonalSamplePreparer(
            bankURL: voiceRoot.appendingPathComponent("Lowlight/SoundBank"))
        let mixer = try TonalVoiceMixer(preparer: preparer, events: [], warmth: 0.78)
        var output = [Float](repeating: .nan, count: 514)
        #expect(output.withUnsafeMutableBufferPointer { mixer.render(into: $0) })
        let silent = output.allSatisfy { $0 == 0 }
        #expect(silent && mixer.position == 257 && mixer.preparedBytes == 0)
        output.removeLast()
        #expect(!output.withUnsafeMutableBufferPointer { mixer.render(into: $0) })
        #expect(mixer.position == 257)
        #expect(throws: VoiceMixerError.self) {
            try TonalVoiceMixer(preparer: preparer, events: [], warmth: .nan)
        }
        let fixture = voiceRoot.appendingPathComponent("tests/fixtures/voices-v9/events.json")
        let events = try NoteEvent.importReference(Data(contentsOf: fixture))
        #expect(throws: VoiceMixerError.self) {
            try TonalVoiceMixer(preparer: preparer, events: events.reversed(), warmth: 0.78)
        }
        #expect(throws: VoiceMixerError.self) {
            try TonalVoiceMixer(
                preparer: preparer, events: Array(repeating: events[0], count: 2049), warmth: 0.78)
        }
    }

    @Test func acceptedVoicesMatchReferenceAcrossBufferSizes() throws {
        let fixtures = voiceRoot.appendingPathComponent("tests/fixtures/voices-v9")
        let events = try NoteEvent.importReference(
            Data(contentsOf: fixtures.appendingPathComponent("events.json")))
        let preparer = try TonalSamplePreparer(
            bankURL: voiceRoot.appendingPathComponent("Lowlight/SoundBank"))
        let mixer = try TonalVoiceMixer(preparer: preparer, events: events, warmth: 0.78)
        #expect(mixer.preparedBytes <= 15_741_256)
        let actual = try render(mixer, partitions: [512])
        mixer.reset()
        let partitioned = try render(mixer, partitions: [1, 17, 64, 127, 256, 1023])
        #expect(actual == partitioned)
        #expect(mixer.position == 384_000 && mixer.activeVoices == 0)
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        let silent = actual[(375010 * 2)...].allSatisfy { $0 == 0 }
        #expect(silent)
        let file = try AVAudioFile(
            forReading: fixtures.appendingPathComponent("voice-prefix.flac"),
            commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 384_000))
        try file.read(into: buffer)
        try #require(buffer.frameLength == 384_000 && file.processingFormat.channelCount == 2)
        let expected = try #require(buffer.floatChannelData?[0])
        var maximum = 0.0
        var squared = 0.0
        for index in actual.indices {
            let error = Double(actual[index]) - Double(expected[index])
            maximum = max(maximum, abs(error))
            squared += error * error
        }
        #expect(
            maximum <= 1e-5 && sqrt(squared / Double(actual.count)) <= 1e-6,
            "max \(maximum), RMS \(sqrt(squared / Double(actual.count)))")
        if let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] {
            let directory = URL(fileURLWithPath: output).appendingPathComponent("voices")
                .resolvingSymlinksInPath().standardizedFileURL
            guard directory.path.hasPrefix(voiceRoot.path + "/.build/") else {
                throw VoiceMixerError.invalidScore
            }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let words = actual.map { $0.bitPattern.littleEndian }
            try words.withUnsafeBytes {
                try Data($0).write(
                    to: directory.appendingPathComponent("voice-prefix.f32"), options: .atomic)
            }
        }
    }

    private func render(_ mixer: TonalVoiceMixer, partitions: [Int]) throws -> [Float] {
        var output = [Float](repeating: .nan, count: 384_000 * 2)
        try output.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            var block = 0
            while frame < 384_000 {
                let count = min(partitions[block % partitions.count], 384_000 - frame)
                try #require(
                    mixer.render(
                        into: UnsafeMutableBufferPointer(
                            rebasing: buffer[(frame * 2)..<((frame + count) * 2)])))
                frame += count
                block += 1
            }
        }
        return output
    }
}
