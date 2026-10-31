// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

private let airRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct QuietAirTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Fades: Decodable {
                let tonalInStartFrame, tonalInEndFrame, tonalOutStartFrame, tonalOutEndFrame: Double
                let rhythmInFrame, rhythmOutFrame: Double
                var descriptor: SongRackFades {
                    SongRackFades(
                        tonalInStartFrame: tonalInStartFrame, tonalInEndFrame: tonalInEndFrame,
                        tonalOutStartFrame: tonalOutStartFrame, tonalOutEndFrame: tonalOutEndFrame,
                        rhythmInFrame: rhythmInFrame, rhythmOutFrame: rhythmOutFrame)
                }
            }
            struct Window: Decodable { let start, count: Int }
            struct Probe: Decodable {
                let frame: Int
                let values: [Double]
            }
            let id, file, carrier: String
            let seed: UInt32
            let frameOrigin: UInt64
            let frames, outputFrames: Int
            let texture: Double
            let fades: Fades
            let windows: [Window]
            let probes: [Probe]
            let channelPeak, channelRms: [Double]
        }
        let cases: [Case]
    }

    @Test func originalAirMatchesAcrossFullPreparationAndChunkedReplay() throws {
        let fixtures = airRoot.appendingPathComponent("tests/fixtures/air-v9")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(manifest.cases.count == 12)
        for item in manifest.cases {
            let air = try QuietAir(
                takeSeed: item.seed, inputFrames: UInt32(item.frames),
                frameOrigin: item.frameOrigin,
                texture: item.texture, rackFades: item.fades.descriptor)
            let actual = try render(air, item: item, partitions: [512])
            air.reset()
            #expect(actual == (try render(air, item: item, partitions: [1, 17, 127, 256, 1023])))
            try verify(actual, item: item)
            try export(actual, name: item.file)
        }
    }

    @Test func bridgeRejectsInvalidPreparationAndKeepsFailedAddsTransactional() throws {
        let fades = SongRackFades(
            tonalOutStartFrame: 5000, tonalOutEndFrame: 6000, rhythmOutFrame: 5500)
        for (seed, frames, origin, texture) in [
            (UInt32(0), UInt32(0), UInt64(0), 0.1),
            (0, QuietAir.maximumInputFrames + 1, 0, 0.1),
            (1 << 31, 10, 0, 0.1),
            (0, 10, 1 << 52, 0.1),
            (0, 10, 0, -0.1), (0, 10, 0, 1.1), (0, 10, 0, .nan),
        ] {
            #expect(throws: QuietAirError.self) {
                try QuietAir(
                    takeSeed: seed, inputFrames: frames, frameOrigin: origin, texture: texture,
                    rackFades: fades)
            }
        }
        let air = try QuietAir(
            takeSeed: 0, inputFrames: 513, frameOrigin: 0, texture: 0.1, rackFades: fades)
        var first = [Float](repeating: 0.125, count: 1026)
        #expect(first.withUnsafeMutableBufferPointer { air.add(to: $0) })
        var exhausted: [Float] = [0.125, 0.125]
        #expect(!exhausted.withUnsafeMutableBufferPointer { air.add(to: $0) })
        #expect(exhausted == [0, 0])
        air.reset()
        var odd: [Float] = [1, 2, 3]
        #expect(!odd.withUnsafeMutableBufferPointer { air.add(to: $0) })
        #expect(odd == [0, 0, 0])
        var invalid: [Float] = [0.1, 0.2, .nan, 0.3]
        #expect(!invalid.withUnsafeMutableBufferPointer { air.add(to: $0) })
        #expect(invalid == [0, 0, 0, 0])
        var replay = [Float](repeating: 0.125, count: first.count)
        #expect(replay.withUnsafeMutableBufferPointer { air.add(to: $0) })
        #expect(first == replay)
    }

    private func carrier(_ item: Manifest.Case, frame: Int, channel: Int) -> Float {
        item.carrier == "zero" ? 0 : Float((frame * 17 + channel * 11) % 31 - 15) / 256
    }

    private func render(_ air: QuietAir, item: Manifest.Case, partitions: [Int]) throws -> [Float] {
        try #require(["zero", "dyadic31"].contains(item.carrier))
        try #require(item.windows.reduce(0) { $0 + $1.count } == item.outputFrames)
        var previousEnd = 0
        for window in item.windows {
            try #require(window.start >= previousEnd && window.count > 0)
            previousEnd = window.start + window.count
            try #require(previousEnd <= item.frames)
        }
        var result: [Float] = []
        result.reserveCapacity(item.outputFrames * 2)
        var storage = [Float](repeating: 0, count: (partitions.max() ?? 1) * 2)
        try storage.withUnsafeMutableBufferPointer { buffer in
            var position = 0
            var block = 0
            var windowIndex = 0
            while position < item.frames {
                let count = min(partitions[block % partitions.count], item.frames - position)
                for frame in 0..<count {
                    buffer[frame * 2] = carrier(item, frame: position + frame, channel: 0)
                    buffer[frame * 2 + 1] = carrier(item, frame: position + frame, channel: 1)
                }
                try #require(
                    air.add(to: UnsafeMutableBufferPointer(rebasing: buffer[..<(count * 2)])))
                while windowIndex < item.windows.count {
                    let window = item.windows[windowIndex]
                    let begin = max(position, window.start)
                    let end = min(position + count, window.start + window.count)
                    if begin < end {
                        result.append(
                            contentsOf: buffer[((begin - position) * 2)..<((end - position) * 2)])
                    }
                    if window.start + window.count > position + count { break }
                    windowIndex += 1
                }
                position += count
                block += 1
            }
        }
        return result
    }

    private func verify(_ samples: [Float], item: Manifest.Case) throws {
        try #require(samples.count == item.outputFrames * 2 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 2 && item.channelRms.count == 2)
        let maximumError = item.carrier == "zero" ? 2e-9 : 1e-8
        let rmsError = item.carrier == "zero" ? 2e-10 : 1e-9
        for channel in 0..<2 {
            var peak = 0.0
            var sum = 0.0
            var outputFrame = 0
            var exact = true
            for window in item.windows {
                for sourceFrame in window.start..<(window.start + window.count) {
                    let value = samples[outputFrame * 2 + channel]
                    peak = max(peak, abs(Double(value)))
                    sum += Double(value) * Double(value)
                    if item.texture == 0
                        || Double(item.frameOrigin + UInt64(sourceFrame))
                            >= item.fades.tonalOutEndFrame
                    {
                        exact =
                            exact && value == carrier(item, frame: sourceFrame, channel: channel)
                    }
                    outputFrame += 1
                }
            }
            #expect(exact)
            #expect(abs(peak - item.channelPeak[channel]) <= maximumError)
            #expect(
                abs(sqrt(sum / Double(item.outputFrames)) - item.channelRms[channel]) <= rmsError)
            for probe in item.probes {
                try #require(
                    (0..<item.outputFrames).contains(probe.frame) && probe.values.count == 2)
                #expect(
                    abs(Double(samples[probe.frame * 2 + channel]) - probe.values[channel])
                        <= maximumError)
            }
        }
    }

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("air")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(airRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw QuietAirError.preparationFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
