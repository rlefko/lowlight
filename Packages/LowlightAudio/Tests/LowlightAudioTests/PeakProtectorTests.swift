// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

private let peakRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct PeakProtectorTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Record: Decodable {
                let frame: Int
                let values: [Double]
            }
            let id, mode, file: String
            let frames, inputFrames: Int
            let complete: Bool
            let inputGain: Double
            let inputEvents: [Record]?
            let inputFile, expectedFile: String?
            let probes: [Record]
            let channelPeak, channelRms: [Double]
        }
        let latencyFrames: Int
        let cases: [Case]
    }
    private let fixtures = peakRoot.appendingPathComponent("tests/fixtures/peak-v9")

    @Test func independentPeakCasesMatchAcrossBuffersAndDrain() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(
            manifest.cases.count == 14 && manifest.latencyFrames == PeakProtector.latencyFrames)
        for item in manifest.cases {
            try #require(item.mode == "song" || item.mode == "session")
            let input = try inputs(item)
            let protector = try PeakProtector(mode: item.mode == "song" ? .song : .session)
            let actual = try render(protector, input: input, item: item, partitions: [512])
            protector.reset()
            #expect(
                actual
                    == (try render(
                        protector, input: input, item: item,
                        partitions: [1, 17, 159, 160, 161, 256, 1023])))
            try verify(actual, item: item)
            try export(actual, name: item.file)
        }
    }

    @Test func bridgeValidatesLengthsAndEndOfInput() throws {
        let protector = try PeakProtector(mode: .session)
        let input: [Float] = [1, -0.5]
        var odd = [Float](repeating: .nan, count: 3)
        #expect(odd.withUnsafeMutableBufferPointer { protector.drain(into: $0) } == nil)
        #expect(odd.allSatisfy { $0 == 0 })
        #expect(
            !odd.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { protector.process($0, into: destination) }
            })
        var output = [Float](repeating: .nan, count: 2)
        #expect(
            output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { protector.process($0, into: destination) }
            })
        #expect(output == [0, 0])
        #expect(protector.drain(into: UnsafeMutableBufferPointer(start: nil, count: 0)) == 0)
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { protector.process($0, into: destination) }
            })
        var tail = [Float](repeating: .nan, count: 2 * (PeakProtector.latencyFrames + 3))
        #expect(tail.withUnsafeMutableBufferPointer { protector.drain(into: $0) } == 160)
        #expect(tail.prefix(318).allSatisfy { $0 == 0 } && tail.suffix(6).allSatisfy { $0 == 0 })
        #expect(tail[318] > 0 && tail[318] < 1 && tail[319] == -0.5 * tail[318])
        #expect(tail.withUnsafeMutableBufferPointer { protector.drain(into: $0) } == 0)
        #expect(tail.allSatisfy { $0 == 0 })
        protector.reset()
        #expect(tail.withUnsafeMutableBufferPointer { protector.drain(into: $0) } == 0)
        #expect(
            !protector.process(
                UnsafeBufferPointer(start: nil, count: 0),
                into: UnsafeMutableBufferPointer(start: nil, count: 0)))
        protector.reset()
        #expect(
            protector.process(
                UnsafeBufferPointer(start: nil, count: 0),
                into: UnsafeMutableBufferPointer(start: nil, count: 0)))
    }

    private func inputs(_ item: Manifest.Case) throws -> [Float] {
        var result: [Float]
        if let file = item.inputFile {
            result = try floats(fixtures.appendingPathComponent(file))
        } else {
            let events = try #require(item.inputEvents)
            result = [Float](repeating: 0, count: item.inputFrames * 2)
            for event in events {
                try #require(
                    (0..<item.inputFrames).contains(event.frame) && event.values.count == 2)
                result[event.frame * 2] = Float(event.values[0])
                result[event.frame * 2 + 1] = Float(event.values[1])
            }
        }
        try #require(result.count == item.inputFrames * 2)
        return result.map { $0 * Float(item.inputGain) }
    }

    private func render(
        _ protector: PeakProtector, input: [Float], item: Manifest.Case,
        partitions: [Int]
    ) throws -> [Float] {
        let latency = PeakProtector.latencyFrames
        try #require(item.inputFrames == item.frames + (item.complete ? 0 : latency))
        let outputFrames = item.frames + latency
        var output = [Float](repeating: .nan, count: outputFrames * 2)
        try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                var position = 0
                var block = 0
                while position < item.inputFrames {
                    let end =
                        position
                        + min(partitions[block % partitions.count], item.inputFrames - position)
                    try #require(
                        protector.process(
                            UnsafeBufferPointer(rebasing: source[(position * 2)..<(end * 2)]),
                            into: UnsafeMutableBufferPointer(
                                rebasing: destination[(position * 2)..<(end * 2)])))
                    position = end
                    block += 1
                }
                if item.complete {
                    while position < outputFrames {
                        let end =
                            position
                            + min(partitions[block % partitions.count], outputFrames - position)
                        try #require(
                            protector.drain(
                                into: UnsafeMutableBufferPointer(
                                    rebasing: destination[(position * 2)..<(end * 2)])) == end
                                - position)
                        position = end
                        block += 1
                    }
                }
            }
        }
        #expect(output.prefix(latency * 2).allSatisfy { $0 == 0 })
        return Array(output.dropFirst(latency * 2))
    }

    private func verify(_ samples: [Float], item: Manifest.Case) throws {
        try #require(samples.count == item.frames * 2 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 2 && item.channelRms.count == 2)
        for channel in 0..<2 {
            var peak = 0.0
            var squared = 0.0
            for frame in 0..<item.frames {
                let value = Double(samples[frame * 2 + channel])
                peak = max(peak, abs(value))
                squared += value * value
            }
            #expect(abs(peak - item.channelPeak[channel]) <= 2e-6)
            #expect(abs(sqrt(squared / Double(item.frames)) - item.channelRms[channel]) <= 2e-7)
            for probe in item.probes {
                try #require((0..<item.frames).contains(probe.frame) && probe.values.count == 2)
                #expect(
                    abs(Double(samples[probe.frame * 2 + channel]) - probe.values[channel]) <= 2e-6)
            }
        }
        if let file = item.expectedFile {
            let expected = try floats(fixtures.appendingPathComponent(file))
            try #require(expected.count == samples.count)
            var squared = 0.0
            var maximum = 0.0
            for index in samples.indices {
                let error = Double(samples[index]) - Double(expected[index])
                maximum = max(maximum, abs(error))
                squared += error * error
            }
            #expect(maximum <= 2e-6 && sqrt(squared / Double(samples.count)) <= 2e-7)
        }
    }

    private func floats(_ path: URL) throws -> [Float] {
        let data = try Data(contentsOf: path)
        try #require(data.count.isMultiple(of: 4))
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(
                    bitPattern: UInt32(
                        littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("peak")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        try #require(
            directory.path.hasPrefix(peakRoot.path + "/.build/")
                && destination.path.hasPrefix(directory.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
