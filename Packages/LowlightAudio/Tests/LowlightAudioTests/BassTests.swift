// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let bassRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct BassTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            let note, roundRobin, frames: Int
            let file: String
            let peak, rms: Double
        }
        let cases: [Case]
    }

    @Test func everyBassBodyMatchesReferenceMetrics() throws {
        let preparer = try TonalSamplePreparer(
            bankURL: bassRoot.appendingPathComponent("Lowlight/SoundBank"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self,
            from: Data(
                contentsOf: bassRoot.appendingPathComponent("tests/fixtures/bass-v9/manifest.json"))
        )
        #expect(manifest.cases.count == 54)
        for item in manifest.cases {
            let sample = try preparer.prepare(
                instrument: .bass, note: item.note, roundRobin: item.roundRobin, warmth: 0.78)
            #expect(
                sample.channels == 1 && sample.frames == item.frames
                    && sample.samples.allSatisfy(\.isFinite))
            let peak = sample.samples.reduce(0.0) { max($0, abs(Double($1))) }
            let rms = sqrt(
                sample.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(sample.frames))
            #expect(abs(peak - item.peak) <= 1e-5 && abs(rms - item.rms) <= 1e-6)
            try export(sample.samples, name: item.file)
        }
        let first = try preparer.prepare(instrument: .bass, note: 31, roundRobin: 0, warmth: 0)
        let wrapped = try preparer.prepare(instrument: .bass, note: 31, roundRobin: 10, warmth: 1)
        #expect(first.samples == wrapped.samples)
        for (note, rr, warmth) in [
            (30, 0, 0.78), (58, 0, 0.78), (31, -1, 0.78), (31, 11, 0.78), (31, 0, Double.nan),
        ] {
            #expect(throws: SamplePreparationError.self) {
                try preparer.prepare(instrument: .bass, note: note, roundRobin: rr, warmth: warmth)
            }
        }
    }

    @Test func malformedBassMetadataIsRejectedBeforeDecoding() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let bank = bassRoot.appendingPathComponent("Lowlight/SoundBank")
        try manager.copyItem(
            at: bank.appendingPathComponent("electric_guitar_manifest.json"),
            to: directory.appendingPathComponent("electric_guitar_manifest.json"))
        let data = try Data(contentsOf: bank.appendingPathComponent("sample_manifest.json"))
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let index = try #require(original.firstIndex { $0["instrument"] as? String == "bass" })
        let duplicate = try #require(original[index + 1]["asset"] as? String)
        for (field, value) in [
            ("frames", 80001 as Any), ("channels", 2), ("root_midi", 35),
            ("asset", duplicate),
        ] {
            var manifest = original
            manifest[index][field] = value
            try JSONSerialization.data(withJSONObject: manifest).write(
                to: directory.appendingPathComponent("sample_manifest.json"))
            #expect(throws: SamplePreparationError.self) {
                try TonalSamplePreparer(bankURL: directory)
            }
        }
    }

    @Test func acceptedBassMatchesReferenceAcrossBufferSizes() throws {
        let fixtures = bassRoot.appendingPathComponent("tests/fixtures/bass-v9")
        let events = try NoteEvent.importReference(
            Data(contentsOf: fixtures.appendingPathComponent("events.json")))
        let preparer = try TonalSamplePreparer(
            bankURL: bassRoot.appendingPathComponent("Lowlight/SoundBank"))
        let mixer = try TonalVoiceMixer(preparer: preparer, events: events, warmth: 0.78)
        #expect(events.count == 6 && mixer.preparedBytes == 1_459_884)
        let actual = try render(mixer, partitions: [512])
        mixer.reset()
        #expect(actual == (try render(mixer, partitions: [1, 17, 64, 127, 256, 1023])))
        #expect(mixer.position == 416_000 && mixer.activeVoices == 0)
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        #expect(actual.allSatisfy(\.isFinite) && actual[(385743 * 2)...].allSatisfy { $0 == 0 })
        let centered = stride(from: 0, to: actual.count, by: 2).allSatisfy {
            actual[$0] == actual[$0 + 1]
        }
        #expect(centered)
        let file = try AVAudioFile(
            forReading: fixtures.appendingPathComponent("bass-prefix.flac"),
            commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 416_000))
        try file.read(into: buffer)
        try #require(buffer.frameLength == 416_000 && file.processingFormat.channelCount == 2)
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
        try export(actual, name: "bass-prefix.f32")
    }

    private func render(_ mixer: TonalVoiceMixer, partitions: [Int]) throws -> [Float] {
        var output = [Float](repeating: .nan, count: 416_000 * 2)
        try output.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            var block = 0
            while frame < 416_000 {
                let count = min(partitions[block % partitions.count], 416_000 - frame)
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

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("bass")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(bassRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else {
            throw VoiceMixerError.invalidScore
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes {
            try Data($0).write(to: destination, options: .atomic)
        }
    }
}
