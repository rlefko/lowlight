// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let glueRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct HarmonicGlueTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Probe: Decodable {
                let frame: Int
                let values: [Double]
            }
            let id, focus, file: String
            let frames, inputFrames: Int
            let inputFile, expectedFile, eventsFile: String?
            let energy: Double?
            let preparedBytes: Int?
            let probes: [Probe]
            let channelPeak, channelRms: [Double]
        }
        let warmth: Double
        let latencyFrames: Int
        let cases: [Case]
    }
    private let fixtures = glueRoot.appendingPathComponent("tests/fixtures/glue-v9")

    @Test func independentGlueCasesMatchAcrossBuffers() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(manifest.cases.count == 15 && manifest.latencyFrames == 399)
        let preparer = try TonalSamplePreparer(
            bankURL: glueRoot.appendingPathComponent("Lowlight/SoundBank"))
        for item in manifest.cases {
            try #require(item.focus == "guitar" || item.focus == "piano")
            let input = try inputs(item, warmth: manifest.warmth, preparer: preparer)
            let glue = try HarmonicGlue(
                inputFrames: UInt64(item.inputFrames),
                focus: item.focus == "guitar" ? .guitar : .piano)
            let actual = try render(glue, input: input, item: item, partitions: [512])
            glue.reset()
            #expect(
                actual
                    == (try render(
                        glue, input: input, item: item, partitions: [1, 17, 64, 127, 256, 1023])))
            try verify(actual, item: item)
            let aligned = (0..<item.frames).allSatisfy { index in
                let source = input[index]
                let start = index * 7
                return actual[start + 2] == source.bass.0 && actual[start + 3] == source.bass.1
                    && actual[start + 4] == source.drums.0 && actual[start + 5] == source.drums.1
                    && actual[start + 6] == source.duck
            }
            #expect(aligned)
            try export(actual, name: item.file)
        }
    }

    @Test func bridgeRejectsInvalidLengthsAndHandlesEmptyStreams() throws {
        #expect(throws: HarmonicGlueError.self) {
            try HarmonicGlue(inputFrames: .max, focus: .guitar)
        }
        let empty = try HarmonicGlue(inputFrames: 0, focus: .guitar)
        var output = [HarmonicGlueFrame](
            repeating: HarmonicGlueFrame(
                tonal: (.nan, .nan), bass: (.nan, .nan), drums: (.nan, .nan), duck: .nan), count: 3)
        #expect(output.withUnsafeMutableBufferPointer { empty.drain(into: $0) } == 0)
        #expect(output.allSatisfy { $0.duck == 0 && $0.tonal.0 == 0 })
        let glue = try HarmonicGlue(inputFrames: 1, focus: .piano)
        let input = [
            RhythmBusFrame(guitar: (0.1, -0.1), piano: (0, 0), bass: (0, 0), drums: (0, 0), duck: 1)
        ]
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { glue.process($0, into: destination) }
            })
        output = [HarmonicGlueFrame()]
        #expect(
            output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { glue.process($0, into: destination) }
            })
        #expect(output[0].duck == 1 && output[0].tonal.0 == 0)
    }

    private func inputs(
        _ item: Manifest.Case, warmth: Double, preparer: TonalSamplePreparer
    ) throws -> [RhythmBusFrame] {
        if let file = item.inputFile {
            let values = try floats(fixtures.appendingPathComponent(file))
            try #require(values.count == item.inputFrames * 9 && item.frames == item.inputFrames)
            return stride(from: 0, to: values.count, by: 9).map { offset in
                RhythmBusFrame(
                    guitar: (values[offset], values[offset + 1]),
                    piano: (values[offset + 2], values[offset + 3]),
                    bass: (values[offset + 4], values[offset + 5]),
                    drums: (values[offset + 6], values[offset + 7]), duck: values[offset + 8])
            }
        }
        let file = try #require(item.eventsFile)
        let energy = try #require(item.energy)
        let events = try NoteEvent.importReference(
            Data(contentsOf: fixtures.appendingPathComponent(file)))
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: events, warmth: warmth, busEnergy: energy)
        let originalBytes = try #require(item.preparedBytes)
        #expect(mixer.preparedBytes <= originalBytes)
        // Preserve the original full rack length while observing only this prefix plus lookahead.
        try #require(item.frames + HarmonicGlue.latencyFrames < item.inputFrames)
        var input = [RhythmBusFrame](
            repeating: RhythmBusFrame(), count: item.frames + HarmonicGlue.latencyFrames)
        #expect(input.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        return input
    }

    private func render(
        _ glue: HarmonicGlue, input: [RhythmBusFrame], item: Manifest.Case, partitions: [Int]
    ) throws -> [Float] {
        let latency = HarmonicGlue.latencyFrames
        var output = [HarmonicGlueFrame](
            repeating: HarmonicGlueFrame(
                tonal: (.nan, .nan), bass: (.nan, .nan), drums: (.nan, .nan), duck: .nan),
            count: item.frames + latency)
        try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                var position = 0
                var block = 0
                while position < source.count {
                    let count = min(partitions[block % partitions.count], source.count - position)
                    let end = position + count
                    try #require(
                        glue.process(
                            UnsafeBufferPointer(rebasing: source[position..<end]),
                            into: UnsafeMutableBufferPointer(rebasing: destination[position..<end]))
                    )
                    position = end
                    block += 1
                }
                if input.count == item.inputFrames {
                    while position < destination.count {
                        let count = min(
                            partitions[block % partitions.count], destination.count - position)
                        let end = position + count
                        try #require(
                            glue.drain(
                                into: UnsafeMutableBufferPointer(
                                    rebasing: destination[position..<end])) == count)
                        position = end
                        block += 1
                    }
                }
            }
        }
        let neutral = output.prefix(latency).allSatisfy {
            $0.tonal.0 == 0 && $0.tonal.1 == 0 && $0.bass.0 == 0 && $0.bass.1 == 0
                && $0.drums.0 == 0 && $0.drums.1 == 0 && $0.duck == 1
        }
        #expect(neutral)
        var samples: [Float] = []
        samples.reserveCapacity(item.frames * 7)
        for frame in output.dropFirst(latency) {
            samples.append(frame.tonal.0)
            samples.append(frame.tonal.1)
            samples.append(frame.bass.0)
            samples.append(frame.bass.1)
            samples.append(frame.drums.0)
            samples.append(frame.drums.1)
            samples.append(frame.duck)
        }
        return samples
    }

    private func verify(_ samples: [Float], item: Manifest.Case) throws {
        try #require(samples.count == item.frames * 7 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 7 && item.channelRms.count == 7)
        let maximumError = item.inputFile == nil ? 1e-5 : 2e-6
        let rmsError = item.inputFile == nil ? 1e-6 : 2e-7
        for channel in 0..<7 {
            var peak = 0.0
            var squared = 0.0
            for frame in 0..<item.frames {
                let value = Double(samples[frame * 7 + channel])
                peak = max(peak, abs(value))
                squared += value * value
            }
            #expect(abs(peak - item.channelPeak[channel]) <= maximumError)
            #expect(abs(sqrt(squared / Double(item.frames)) - item.channelRms[channel]) <= rmsError)
            for probe in item.probes {
                try #require((0..<item.frames).contains(probe.frame) && probe.values.count == 7)
                #expect(
                    abs(Double(samples[probe.frame * 7 + channel]) - probe.values[channel])
                        <= maximumError)
            }
        }
        if let file = item.expectedFile {
            let expected = try floats(fixtures.appendingPathComponent(file))
            try #require(expected.count == samples.count)
            var maximum = 0.0
            var squared = 0.0
            for index in samples.indices {
                let error = Double(samples[index]) - Double(expected[index])
                maximum = max(maximum, abs(error))
                squared += error * error
            }
            #expect(maximum <= maximumError && sqrt(squared / Double(samples.count)) <= rmsError)
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
        let directory = URL(fileURLWithPath: output).appendingPathComponent("glue")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(glueRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw HarmonicGlueError.invalidConfiguration }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
