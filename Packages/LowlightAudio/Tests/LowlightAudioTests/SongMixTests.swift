// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let mixRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongMixTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Limits: Decodable { let maximumAbsoluteError, rmsError: Double }
            struct Segment: Decodable {
                let start, count: Int
                let values: [Float]
            }
            struct Probe: Decodable {
                let frame: Int
                let values: [Double]
            }
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
            let id, file: String
            let frames, inputFrames: Int
            let seed: UInt32
            let frameOrigin: UInt64
            let texture: Double
            let fades: Fades
            let limits: Limits
            let inputSegments: [Segment]?
            let expectedFile, eventsFile, focus: String?
            let warmth, space, energy: Double?
            let preparedBytes: Int?
            let exactSilence: Bool?
            let probes: [Probe]
            let channelPeak, channelRms: [Double]
        }
        let cases: [Case]
    }
    private let fixtures = mixRoot.appendingPathComponent("tests/fixtures/mix-v9")

    @Test func originalSongMixMatchesAcrossBuffersAndReset() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(manifest.cases.count == 10)
        let preparer = try TonalSamplePreparer(
            bankURL: mixRoot.appendingPathComponent("Lowlight/SoundBank"))
        for item in manifest.cases {
            let input = try inputs(item, preparer: preparer)
            let mix = try SongMix(
                takeSeed: item.seed, inputFrames: UInt32(item.inputFrames),
                frameOrigin: item.frameOrigin, texture: item.texture,
                rackFades: item.fades.descriptor)
            let actual = try render(mix, input: input, partitions: [512])
            mix.reset()
            #expect(
                actual == (try render(mix, input: input, partitions: [1, 17, 64, 127, 256, 1023])))
            try verify(actual, item: item)
            try export(actual, name: item.file)
        }
    }

    @Test func bridgeRejectsInvalidPreparationAndKeepsFailedCallsTransactional() throws {
        let fades = SongRackFades(
            tonalOutStartFrame: 1000, tonalOutEndFrame: 2000, rhythmOutFrame: 1500)
        for (seed, frames, origin, texture) in [
            (UInt32(0), UInt32(0), UInt64(0), 0.1),
            (0, SongMix.maximumInputFrames + 1, 0, 0.1),
            (1 << 31, 10, 0, 0.1), (0, 10, 1 << 52, 0.1),
            (0, 10, 0, -0.1), (0, 10, 0, 1.1), (0, 10, 0, .nan),
        ] {
            #expect(throws: SongMixError.self) {
                try SongMix(
                    takeSeed: seed, inputFrames: frames, frameOrigin: origin, texture: texture,
                    rackFades: fades)
            }
        }
        let mix = try SongMix(
            takeSeed: 0, inputFrames: 513, frameOrigin: 0, texture: 0.1, rackFades: fades)
        let input = [HarmonicGlueFrame](
            repeating: HarmonicGlueFrame(
                tonal: (0.125, -0.25), bass: (0.0625, 0.03125), drums: (-0.01, 0.02), duck: 0.95),
            count: 513)
        let first = try render(mix, input: input, partitions: [513])
        var output: [Float] = [1, 1]
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer {
                    mix.process(UnsafeBufferPointer(rebasing: $0[..<1]), into: destination)
                }
            })
        #expect(output == [0, 0])
        mix.reset()
        output = [1, 1, 1]
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer {
                    mix.process(UnsafeBufferPointer(rebasing: $0[..<1]), into: destination)
                }
            })
        #expect(output == [0, 0, 0])
        var invalid = input
        invalid[512].drums.1 = .nan
        output = [Float](repeating: 1, count: 1026)
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                invalid.withUnsafeBufferPointer { mix.process($0, into: destination) }
            })
        #expect(output.allSatisfy { $0 == 0 })
        #expect(first == (try render(mix, input: input, partitions: [17, 256])))
    }

    private func inputs(_ item: Manifest.Case, preparer: TonalSamplePreparer) throws
        -> [HarmonicGlueFrame]
    {
        if let segments = item.inputSegments {
            var result = [HarmonicGlueFrame](
                repeating: HarmonicGlueFrame(tonal: (0, 0), bass: (0, 0), drums: (0, 0), duck: 1),
                count: item.frames)
            for segment in segments {
                try #require(
                    segment.start >= 0 && segment.count > 0
                        && segment.start + segment.count <= item.frames && segment.values.count == 7
                )
                let v = segment.values
                let frame = HarmonicGlueFrame(
                    tonal: (v[0], v[1]), bass: (v[2], v[3]), drums: (v[4], v[5]), duck: v[6])
                for index in segment.start..<(segment.start + segment.count) {
                    result[index] = frame
                }
            }
            return result
        }
        let file = try #require(item.eventsFile)
        let warmth = try #require(item.warmth)
        let space = try #require(item.space)
        let energy = try #require(item.energy)
        try #require(item.focus == "guitar" || item.focus == "piano")
        let events = try NoteEvent.importReference(
            Data(contentsOf: fixtures.appendingPathComponent(file)))
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: events, warmth: warmth, busEnergy: energy,
            rackFades: item.fades.descriptor)
        let originalBytes = try #require(item.preparedBytes)
        #expect(mixer.preparedBytes <= originalBytes)
        let count = item.frames + HarmonicGlue.latencyFrames
        try #require(count < item.inputFrames)
        var buses = [RhythmBusFrame](repeating: RhythmBusFrame(), count: count)
        #expect(buses.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        let glue = try HarmonicGlue(
            inputFrames: UInt64(item.inputFrames), focus: item.focus == "guitar" ? .guitar : .piano)
        var delayed = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: count)
        #expect(
            delayed.withUnsafeMutableBufferPointer { destination in
                buses.withUnsafeBufferPointer { glue.process($0, into: destination) }
            })
        // Match logical original frames; startup delay must never advance air or HP32.
        let logical = Array(delayed.dropFirst(HarmonicGlue.latencyFrames))
        let room = try StereoRoom(space: space, warmth: warmth)
        var result = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: item.frames)
        #expect(
            result.withUnsafeMutableBufferPointer { destination in
                logical.withUnsafeBufferPointer { room.process($0, into: destination) }
            })
        return result
    }

    private func render(_ mix: SongMix, input: [HarmonicGlueFrame], partitions: [Int]) throws
        -> [Float]
    {
        var output = [Float](repeating: .nan, count: input.count * 2)
        try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                var position = 0
                var block = 0
                while position < input.count {
                    let end =
                        position + min(partitions[block % partitions.count], input.count - position)
                    try #require(
                        mix.process(
                            UnsafeBufferPointer(rebasing: source[position..<end]),
                            into: UnsafeMutableBufferPointer(
                                rebasing: destination[(position * 2)..<(end * 2)])))
                    position = end
                    block += 1
                }
            }
        }
        return output
    }

    private func verify(_ samples: [Float], item: Manifest.Case) throws {
        try #require(samples.count == item.frames * 2 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 2 && item.channelRms.count == 2)
        if item.exactSilence == true { #expect(samples.allSatisfy { $0 == 0 }) }
        for channel in 0..<2 {
            var peak = 0.0
            var squared = 0.0
            for frame in 0..<item.frames {
                let value = Double(samples[frame * 2 + channel])
                peak = max(peak, abs(value))
                squared += value * value
            }
            #expect(abs(peak - item.channelPeak[channel]) <= item.limits.maximumAbsoluteError)
            #expect(
                abs(sqrt(squared / Double(item.frames)) - item.channelRms[channel])
                    <= item.limits.rmsError)
            for probe in item.probes {
                try #require((0..<item.frames).contains(probe.frame) && probe.values.count == 2)
                #expect(
                    abs(Double(samples[probe.frame * 2 + channel]) - probe.values[channel])
                        <= item.limits.maximumAbsoluteError)
            }
        }
        if let file = item.expectedFile {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(file))
            try #require(data.count == samples.count * 4)
            var maximum = 0.0
            var squared = 0.0
            data.withUnsafeBytes { bytes in
                for index in samples.indices {
                    let value = Float(
                        bitPattern: UInt32(
                            littleEndian: bytes.loadUnaligned(
                                fromByteOffset: index * 4, as: UInt32.self)))
                    let error = Double(samples[index]) - Double(value)
                    maximum = max(maximum, abs(error))
                    squared += error * error
                }
            }
            #expect(maximum <= item.limits.maximumAbsoluteError)
            #expect(sqrt(squared / Double(samples.count)) <= item.limits.rmsError)
        }
    }

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("mix")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(mixRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw SongMixError.preparationFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
