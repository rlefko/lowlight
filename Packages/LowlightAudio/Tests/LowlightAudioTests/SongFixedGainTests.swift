// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

private let gainRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongFixedGainTests {
    private struct Scalars: Codable {
        let measuredLufs, gainDb, linearGain: Double
    }
    private struct Manifest: Decodable {
        struct Case: Decodable {
            let id, file, scalarFile, expectedFile: String
            let frames: Int
            let measuredLufs: Double
            let exactPcm: Bool
            let inputSamples: [[Float]]?
            let inputFixture, inputFile: String?
            let expectedScalars: Scalars
        }
        let cases: [Case]
    }
    private let fixtures = gainRoot.appendingPathComponent("tests/fixtures/gain-v9")

    @Test func originalFixedGainMatchesEverySampleAndPartition() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(manifest.cases.count == 10)
        for item in manifest.cases {
            let input: [Float]
            if let path = item.inputFixture {
                input = try read(gainRoot.appendingPathComponent("tests/fixtures/" + path))
            } else if let path = item.inputFile {
                input = try read(fixtures.appendingPathComponent(path))
            } else {
                input = try #require(item.inputSamples).flatMap { $0 }
            }
            try #require(input.count == item.frames * 2)
            let gain = try SongFixedGain(measurement: measurement(item.measuredLufs))
            #expect(abs(gain.decibels - item.expectedScalars.gainDb) <= 1e-12)
            #expect(abs(gain.linearMultiplier / item.expectedScalars.linearGain - 1) <= 2e-15)
            let output = try apply(gain, input: input, partitions: [512])
            #expect(
                output.map(\.bitPattern)
                    == (try apply(
                        gain, input: input,
                        partitions: [1, 17, 127, 1023])).map(\.bitPattern))
            let expected = try read(fixtures.appendingPathComponent(item.expectedFile))
            try #require(expected.count == output.count && output.allSatisfy(\.isFinite))
            if item.exactPcm {
                #expect(output.map(\.bitPattern) == expected.map(\.bitPattern))
            } else {
                let errors = zip(output, expected).map { Double($0) - Double($1) }
                #expect(errors.map { abs($0) }.max() ?? 0 <= 6e-8)
                #expect(sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)) <= 1e-8)
            }
            try export(output, gain: gain, item: item)
        }
    }

    @Test func unmeasurableAndInvalidInputsFailWithoutChangingPreparedGain() throws {
        for loudness: Double? in [nil, .nan, .infinity, -.infinity, -70.0001, 1e308] {
            #expect(throws: SongFixedGainError.self) {
                try SongFixedGain(measurement: measurement(loudness))
            }
        }
        let gain = try SongFixedGain(measurement: measurement(-30.318919941908316))
        let input: [Float] = [0.1, -0.1, 2, -2]
        let expected = try apply(gain, input: input, partitions: [2])
        #expect(expected[0].bitPattern == 0x3e9e_9172)
        #expect(expected[2] > 1 && expected[3] < -1)
        var output = [Float](repeating: 1, count: 3)
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { gain.process($0, into: destination) }
            })
        #expect(output == [0, 0, 0])
        for value: Float in [.nan, .infinity, -.infinity, SongFixedGain.inputLimit.nextUp] {
            var invalid = input
            invalid[3] = value
            output = [Float](repeating: 1, count: input.count)
            #expect(
                !output.withUnsafeMutableBufferPointer { destination in
                    invalid.withUnsafeBufferPointer { gain.process($0, into: destination) }
                })
            #expect(output.allSatisfy { $0 == 0 })
        }
        #expect(try apply(gain, input: input, partitions: [1]) == expected)
        #expect(
            gain.process(
                UnsafeBufferPointer(start: nil, count: 0),
                into: UnsafeMutableBufferPointer(start: nil, count: 0)))
    }

    @Test func measuredBodyReachesTargetBeforeLinkedSongProtection() throws {
        let body: [Float] = (0..<32_000).flatMap { frame in
            frame / 16 % 2 == 0 ? [0.015625, -0.0078125] : [-0.015625, 0.0078125]
        }
        let meter = try SongLoudnessMeter(bodyFrames: 32_000)
        #expect(body.withUnsafeBufferPointer { meter.process($0) })
        let gain = try SongFixedGain(measurement: meter.finish())
        let normalized = try apply(gain, input: body, partitions: [127])
        meter.reset()
        #expect(normalized.withUnsafeBufferPointer { meter.process($0) })
        #expect(abs(try #require(meter.finish().integratedLUFS) - SongFixedGain.targetLUFS) <= 1e-5)
        // Outside-body transients use the same gain and reach the existing protector.
        let input: [Float] = [2, -1] + body + [4, -2] + [Float](repeating: 0, count: 640)
        let boosted = try apply(gain, input: input, partitions: [17, 256])
        let protector = try PeakProtector(mode: .song)
        let output = try protect(protector, input: boosted)
        protector.reset()
        #expect(output == (try protect(protector, input: boosted)))
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite)
        #expect(output.map { abs($0) }.max() ?? 0 < boosted.map { abs($0) }.max() ?? 0)
        #expect(
            stride(from: 0, to: output.count, by: 2).allSatisfy {
                output[$0 + 1] == -0.5 * output[$0]
            })
    }

    private func measurement(_ loudness: Double?) -> SongLoudnessMeasurement {
        SongLoudnessMeasurement(
            integratedLUFS: loudness, totalBlocks: 1,
            absoluteBlocks: loudness == nil ? 0 : 1, gatedBlocks: loudness == nil ? 0 : 1)
    }

    private func apply(_ gain: SongFixedGain, input: [Float], partitions: [Int]) throws -> [Float] {
        var output = [Float](repeating: .nan, count: input.count)
        try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                var frame = 0
                var block = 0
                while frame < input.count / 2 {
                    let end = min(frame + partitions[block % partitions.count], input.count / 2)
                    try #require(
                        gain.process(
                            UnsafeBufferPointer(rebasing: source[frame * 2..<end * 2]),
                            into: UnsafeMutableBufferPointer(
                                rebasing: destination[frame * 2..<end * 2])))
                    frame = end
                    block += 1
                }
            }
        }
        return output
    }

    private func protect(_ protector: PeakProtector, input: [Float]) throws -> [Float] {
        let latency = PeakProtector.latencyFrames * 2
        var output = [Float](repeating: .nan, count: input.count + latency)
        try output.withUnsafeMutableBufferPointer { destination in
            try input.withUnsafeBufferPointer { source in
                try #require(
                    protector.process(
                        source,
                        into: UnsafeMutableBufferPointer(rebasing: destination[..<input.count])))
            }
            try #require(
                protector.drain(
                    into: UnsafeMutableBufferPointer(
                        rebasing: destination[input.count...])) == PeakProtector.latencyFrames)
        }
        #expect(output.prefix(latency).allSatisfy { $0 == 0 })
        return Array(output.dropFirst(latency))
    }

    private func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        try #require(data.count.isMultiple(of: 4))
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map {
                Float(
                    bitPattern: UInt32(
                        littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
            }
        }
    }

    private func export(_ samples: [Float], gain: SongFixedGain, item: Manifest.Case) throws {
        guard let path = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("gain")
            .resolvingSymlinksInPath().standardizedFileURL
        try #require(directory.path.hasPrefix(gainRoot.path + "/.build/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let scalars = try encoder.encode(
            Scalars(
                measuredLufs: item.measuredLufs,
                gainDb: gain.decibels, linearGain: gain.linearMultiplier))
        let words = samples.map { $0.bitPattern.littleEndian }
        let data = words.withUnsafeBytes { Data($0) }
        for (file, bytes) in [(item.file, data), (item.scalarFile, scalars)] {
            let destination = directory.appendingPathComponent(file).resolvingSymlinksInPath()
                .standardizedFileURL
            try #require(destination.path.hasPrefix(directory.path + "/"))
            try bytes.write(to: destination, options: .atomic)
        }
    }
}
