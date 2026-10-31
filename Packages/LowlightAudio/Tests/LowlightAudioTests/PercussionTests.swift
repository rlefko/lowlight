// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let percussionRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct PercussionTests {
    private struct Manifest: Decodable {
        struct Body: Decodable {
            let instrument, file: String
            let note, roundRobin, frames: Int
            let velocity, peak, rms: Double
        }
        struct Clip: Decodable {
            let id, eventsFile, fixtureFile: String
            let frames, tailSilenceStartFrame, preparedBytes: Int
        }
        let bodies: [Body]
        let clips: [Clip]
    }
    private let fixtures = percussionRoot.appendingPathComponent("tests/fixtures/percussion-v9")
    private let bank = percussionRoot.appendingPathComponent("Lowlight/SoundBank")

    private func manifest() throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    }

    @Test func everyPreparedHitMatchesReference() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let cases = try manifest().bodies
        #expect(cases.count == 12)
        for item in cases {
            let instrument = try #require(TonalInstrument(rawValue: item.instrument))
            let sample = try preparer.prepare(
                instrument: instrument, note: item.note, roundRobin: item.roundRobin, warmth: 0.78,
                velocity: item.velocity)
            #expect(
                sample.channels == 1 && sample.frames == item.frames
                    && sample.samples.allSatisfy(\.isFinite))
            let peak = sample.samples.reduce(0.0) { max($0, abs(Double($1))) }
            let rms = sqrt(
                sample.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(sample.frames))
            #expect(abs(peak - item.peak) <= 1e-5 && abs(rms - item.rms) <= 1e-6)
            try export(sample.samples, name: item.file)
        }
        let low = try preparer.prepare(
            instrument: .hat, note: 0, roundRobin: 0, warmth: 0, velocity: 0.719999999)
        let high = try preparer.prepare(
            instrument: .hat, note: 0, roundRobin: 0, warmth: 1, velocity: 0.72)
        #expect(Float(0.719999999) == Float(0.72) && low.samples != high.samples)
        for velocity in [-1.0, 1.01, .nan, .infinity] {
            #expect(throws: SamplePreparationError.self) {
                try preparer.prepare(
                    instrument: .hat, note: 0, roundRobin: 0, warmth: 0.78, velocity: velocity)
            }
        }
        for (instrument, note) in [(TonalInstrument.kick, 1), (.snare, 0), (.hat, 1), (.shaker, 1)]
        {
            #expect(throws: SamplePreparationError.self) {
                try preparer.prepare(
                    instrument: instrument, note: note, roundRobin: 0, warmth: 0.78)
            }
        }
    }

    @Test func originalClipsAndOneShotControlsMatchAcrossBuffers() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        for clip in try manifest().clips {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(clip.eventsFile))
            let events = try NoteEvent.importReference(data)
            let mixer = try TonalVoiceMixer(preparer: preparer, events: events, warmth: 0.78)
            #expect(mixer.preparedBytes == clip.preparedBytes)
            let actual = try render(mixer, frames: clip.frames, partitions: [512])
            mixer.reset()
            #expect(
                actual
                    == (try render(
                        mixer, frames: clip.frames, partitions: [1, 17, 64, 127, 256, 1023])))
            #expect(
                mixer.position == clip.frames && mixer.activeVoices == 0 && mixer.stolenVoices == 0
                    && mixer.droppedEvents == 0)
            #expect(
                actual.allSatisfy(\.isFinite)
                    && actual[(clip.tailSilenceStartFrame * 2)...].allSatisfy { $0 == 0 })
            let file = try AVAudioFile(
                forReading: fixtures.appendingPathComponent(clip.fixtureFile),
                commonFormat: .pcmFormatFloat32, interleaved: true)
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(clip.frames))
            )
            try file.read(into: buffer)
            try #require(
                buffer.frameLength == clip.frames && file.processingFormat.channelCount == 2)
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
                "\(clip.id): max \(maximum), RMS \(sqrt(squared / Double(actual.count)))")
            if clip.id == "percussion-controls" {
                var changed = try #require(
                    JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                for index in changed.indices {
                    changed[index]["duration"] = index.isMultiple(of: 2) ? 16 : 1.0 / 32_000
                    changed[index]["release"] = index.isMultiple(of: 2) ? 5 : 0
                    changed[index]["articulation"] = "normal"
                }
                let alternate = try NoteEvent.importReference(
                    JSONSerialization.data(withJSONObject: changed))
                let repeated = try TonalVoiceMixer(preparer: preparer, events: alternate, warmth: 1)
                #expect(actual == (try render(repeated, frames: clip.frames, partitions: [257])))
            }
            try export(actual, name: clip.id + ".f32")
        }
    }

    @Test func malformedPercussionMetadataIsRejectedBeforeDecoding() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        try manager.copyItem(
            at: bank.appendingPathComponent("electric_guitar_manifest.json"),
            to: directory.appendingPathComponent("electric_guitar_manifest.json"))
        let data = try Data(contentsOf: bank.appendingPathComponent("sample_manifest.json"))
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let index = try #require(original.firstIndex { $0["instrument"] as? String == "hat" })
        let duplicate = try #require(original[index + 1]["asset"] as? String)
        for (field, value) in [
            ("frames", 38401 as Any), ("channels", 2), ("root_midi", 60), ("sample_rate", 44100),
            ("asset", "assets/hat/../../outside_HitC_v1_.flac"),
            ("asset", "assets/hat/invalid_HitC_v3_.flac"), ("asset", duplicate),
            ("instrument", "missing"),
        ] {
            var modified = original
            modified[index][field] = value
            try JSONSerialization.data(withJSONObject: modified).write(
                to: directory.appendingPathComponent("sample_manifest.json"))
            #expect(throws: SamplePreparationError.self) {
                try TonalSamplePreparer(bankURL: directory)
            }
        }
    }

    private func render(_ mixer: TonalVoiceMixer, frames: Int, partitions: [Int]) throws -> [Float]
    {
        var output = [Float](repeating: .nan, count: frames * 2)
        try output.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            var block = 0
            while frame < frames {
                let count = min(partitions[block % partitions.count], frames - frame)
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
        let directory = URL(fileURLWithPath: output).appendingPathComponent("percussion")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(percussionRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw VoiceMixerError.invalidScore }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
