// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Darwin
import Foundation
import Testing

@testable import LowlightAudio

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let bank = repository.appendingPathComponent("Lowlight/SoundBank")
private let fixtures = repository.appendingPathComponent("tests/fixtures/tonal-v9")

private struct Oracle: Decodable {
    let cases: [Case]
    struct Case: Decodable {
        let id, windowFile: String
        let instrument: TonalInstrument
        let note, roundRobin, frames, channels: Int
        let warmth: Double
        let windows: [Window]
    }
    struct Window: Decodable { let startFrame, frames: Int }
}

@Suite(.serialized)
struct TonalPreparationTests {
    @Test func frozenReferenceWindowsAndFullCandidates() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let oracle = try decoder.decode(
            Oracle.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        let preparer = try TonalSamplePreparer(bankURL: bank)
        var timings: [String: Double] = [:]
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let startingPeak = usage.ru_maxrss
        for item in oracle.cases {
            let start = DispatchTime.now().uptimeNanoseconds
            let sample = try preparer.prepare(
                instrument: item.instrument, note: item.note, roundRobin: item.roundRobin,
                warmth: item.warmth)
            timings[item.id] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            #expect(sample.frames == item.frames && sample.channels == item.channels, "\(item.id)")
            let expected = try AVAudioFile(
                forReading: fixtures.appendingPathComponent(item.windowFile),
                commonFormat: .pcmFormatFloat32, interleaved: true)
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: expected.processingFormat,
                    frameCapacity: AVAudioFrameCount(expected.length)))
            try expected.read(into: buffer)
            let pcm = try #require(buffer.floatChannelData?[0])
            var offset = 0
            var maximum = 0.0
            var squared = 0.0
            for window in item.windows {
                for index
                    in (window.startFrame * item.channels)..<((window.startFrame + window.frames)
                    * item.channels)
                {
                    let error = Double(sample.samples[index]) - Double(pcm[offset])
                    maximum = max(maximum, abs(error))
                    squared += error * error
                    offset += 1
                }
            }
            #expect(
                maximum <= 1e-5 && sqrt(squared / Double(offset)) <= 1e-6,
                "\(item.id): max \(maximum), RMS \(sqrt(squared / Double(offset)))")
            if let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] {
                let directory = URL(fileURLWithPath: output).resolvingSymlinksInPath()
                    .standardizedFileURL
                guard directory.path.hasPrefix(repository.path + "/.build/") else {
                    throw SamplePreparationError.invalidRequest
                }
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let words = sample.samples.map { $0.bitPattern.littleEndian }
                try words.withUnsafeBytes {
                    try Data($0).write(
                        to: directory.appendingPathComponent(item.id + ".f32"), options: .atomic)
                }
                getrusage(RUSAGE_SELF, &usage)
                let report: [String: Any] = [
                    "preparation_seconds": timings, "test_process_peak_rss_bytes": usage.ru_maxrss,
                    "starting_peak_rss_bytes": startingPeak,
                    "measurement": "macOS test process, not app/device memory",
                ]
                try JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
                )
                .write(to: directory.appendingPathComponent("profile.json"), options: .atomic)
            }
        }
    }

    @Test func invalidRequestsAndWarmthQuantization() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        for (note, robin, warmth) in [
            (49, 0, 0.78), (70, 0, 0.78), (60, -1, 0.78), (60, 11, 0.78), (60, 0, .nan),
            (60, 0, .infinity),
        ] {
            #expect(throws: SamplePreparationError.self) {
                try preparer.prepare(
                    instrument: .guitar, note: note, roundRobin: robin, warmth: warmth)
            }
        }
        // Independently evaluated Python round(x, 2), including exact/binary decimal ties.
        for (input, expected) in [
            (0.005, 0.01), (0.015, 0.01), (0.125, 0.12), (0.785, 0.79), (0.995, 0.99), (-1, 0),
            (2, 1),
        ] {
            #expect(TonalSamplePreparer.quantizedWarmth(input) == expected)
        }
    }

    @Test func roundRobinAndClampedControlsRemainDeterministic() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let first = try preparer.prepare(instrument: .guitar, note: 57, roundRobin: 0, warmth: 0)
        let wrapped = try preparer.prepare(instrument: .guitar, note: 57, roundRobin: 4, warmth: -3)
        let second = try preparer.prepare(instrument: .guitar, note: 57, roundRobin: 1, warmth: 0)
        #expect(first.samples == wrapped.samples)
        #expect(first.samples != second.samples)
        let finite = first.samples.allSatisfy(\.isFinite)
        #expect(finite)
    }

    @Test func malformedMetadataIsRejectedBeforeDecoding() throws {
        let remote = try #require(URL(string: "https://example.invalid/SoundBank"))
        #expect(throws: SamplePreparationError.self) { try TonalSamplePreparer(bankURL: remote) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(
            at: bank.appendingPathComponent("sample_manifest.json"),
            to: temporary.appendingPathComponent("sample_manifest.json"))
        let data = try Data(
            contentsOf: bank.appendingPathComponent("electric_guitar_manifest.json"))
        for (field, value) in [
            ("frames", 192001 as Any), ("channels", 3), ("sample_rate", 44100),
            ("asset", "assets/../../outside.flac"),
        ] {
            var manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var entries = try #require(manifest["entries"] as? [[String: Any]])
            entries[0][field] = value
            manifest["entries"] = entries
            try JSONSerialization.data(withJSONObject: manifest).write(
                to: temporary.appendingPathComponent("electric_guitar_manifest.json"))
            #expect(throws: SamplePreparationError.self) {
                try TonalSamplePreparer(bankURL: temporary)
            }
        }
        try Data(repeating: 32, count: 262_145).write(
            to: temporary.appendingPathComponent("electric_guitar_manifest.json"))
        #expect(throws: SamplePreparationError.self) { try TonalSamplePreparer(bankURL: temporary) }
    }
}
