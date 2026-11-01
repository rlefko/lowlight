// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

private let loudnessRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongLoudnessTests {
    private struct Result: Codable {
        let inputFrames, blockCount, absoluteGateCount, relativeGateCount: Int
        let measurable: Bool
        let lufs: Double
    }
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Segment: Decodable {
                let start, count: Int
                let holdFrames: Int?
                let pattern: [[Float]]
            }
            let id, file: String
            let inputFrames: Int
            let inputSegments: [Segment]?
            let inputFile: String?
            let expected: Result
        }
        let cases: [Case]
    }
    private let fixtures = loudnessRoot.appendingPathComponent("tests/fixtures/loudness-v9")

    @Test func pinnedOriginalLoudnessMatchesAcrossChunksAndReset() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(!manifest.cases.isEmpty)
        for item in manifest.cases {
            let input = try inputs(item)
            let meter = try SongLoudnessMeter(bodyFrames: UInt32(item.inputFrames))
            let first = try measure(meter, input: input, partitions: [512])
            #expect(first == (try meter.finish()))
            meter.reset()
            #expect(first == (try measure(meter, input: input, partitions: [1, 17, 127, 1023])))
            #expect(first.totalBlocks == item.expected.blockCount)
            #expect(first.absoluteBlocks == item.expected.absoluteGateCount)
            #expect(first.gatedBlocks == item.expected.relativeGateCount)
            #expect((first.integratedLUFS != nil) == item.expected.measurable)
            if item.expected.measurable {
                #expect(abs(try #require(first.integratedLUFS) - item.expected.lufs) <= 1e-5)
            }
            try export(first, item: item)
        }
    }

    @Test func bridgePreservesProgressOnInvalidInputAndIncompleteFinish() throws {
        for count in [
            UInt32(0), SongLoudnessMeter.minimumBodyFrames - 1,
            SongLoudnessMeter.maximumBodyFrames + 1,
        ] {
            #expect(throws: SongLoudnessError.self) { try SongLoudnessMeter(bodyFrames: count) }
        }
        let input = [Float](repeating: 0.125, count: 25_600)
        let meter = try SongLoudnessMeter(bodyFrames: 12_800)
        let baseline = try measure(meter, input: input, partitions: [12_800])
        #expect(![Float]().withUnsafeBufferPointer { meter.process($0) })
        meter.reset()
        #expect([Float]().withUnsafeBufferPointer { meter.process($0) })
        try input.withUnsafeBufferPointer { samples in
            #expect(meter.process(UnsafeBufferPointer(rebasing: samples[..<200])))
            #expect(throws: SongLoudnessError.self) { try meter.finish() }
            #expect(!meter.process(UnsafeBufferPointer(rebasing: samples[..<1])))
            #expect(!meter.process(samples))
            var invalid = Array(samples[200...])
            for value: Float in [.nan, .infinity, -.infinity, SongLoudnessMeter.inputLimit.nextUp] {
                invalid[invalid.count - 1] = value
                #expect(!invalid.withUnsafeBufferPointer { meter.process($0) })
            }
            #expect(meter.process(UnsafeBufferPointer(rebasing: samples[200...])))
        }
        #expect(try meter.finish() == baseline)
        meter.reset()
        let silence = try measure(
            meter, input: [Float](repeating: 0, count: 25_600), partitions: [127])
        #expect(silence.integratedLUFS == nil && silence.gatedBlocks == 0)
    }

    private func inputs(_ item: Manifest.Case) throws -> [Float] {
        if let name = item.inputFile {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
            try #require(data.count == item.inputFrames * 8)
            return data.withUnsafeBytes { bytes in
                (0..<(item.inputFrames * 2)).map {
                    Float(
                        bitPattern: UInt32(
                            littleEndian: bytes.loadUnaligned(
                                fromByteOffset: $0 * 4, as: UInt32.self)))
                }
            }
        }
        var input = [Float](repeating: 0, count: item.inputFrames * 2)
        for segment in item.inputSegments ?? [] {
            try #require(
                segment.start >= 0 && segment.count > 0
                    && segment.start + segment.count <= item.inputFrames
                    && (segment.holdFrames ?? 1) > 0 && !segment.pattern.isEmpty
                    && segment.pattern.allSatisfy { $0.count == 2 })
            for frame in segment.start..<(segment.start + segment.count) {
                let pair = segment.pattern[
                    ((frame - segment.start) / (segment.holdFrames ?? 1)) % segment.pattern.count]
                input[frame * 2] = pair[0]
                input[frame * 2 + 1] = pair[1]
            }
        }
        return input
    }

    private func measure(_ meter: SongLoudnessMeter, input: [Float], partitions: [Int]) throws
        -> SongLoudnessMeasurement
    {
        try input.withUnsafeBufferPointer { source in
            var frame = 0
            var block = 0
            while frame < input.count / 2 {
                let end = min(frame + partitions[block % partitions.count], input.count / 2)
                try #require(
                    meter.process(
                        UnsafeBufferPointer(rebasing: source[(frame * 2)..<(end * 2)])))
                frame = end
                block += 1
            }
        }
        return try meter.finish()
    }

    private func export(_ value: SongLoudnessMeasurement, item: Manifest.Case) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("loudness")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(item.file).resolvingSymlinksInPath()
            .standardizedFileURL
        try #require(
            directory.path.hasPrefix(loudnessRoot.path + "/.build/")
                && destination.path.hasPrefix(directory.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            Result(
                inputFrames: item.inputFrames, blockCount: Int(value.totalBlocks),
                absoluteGateCount: Int(value.absoluteBlocks),
                relativeGateCount: Int(value.gatedBlocks),
                measurable: value.integratedLUFS != nil, lufs: value.integratedLUFS ?? 0
            )
        ).write(to: destination, options: .atomic)
    }
}
