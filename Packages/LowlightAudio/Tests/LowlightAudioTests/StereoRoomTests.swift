// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let roomRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct StereoRoomTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Record: Decodable {
                let frame: Int
                let values: [Double]
            }
            let id, file: String
            let frames, inputFrames: Int
            let space, warmth: Double
            let inputEvents: [Record]?
            let expectedFile, eventsFile, focus: String?
            let energy: Double?
            let preparedBytes: Int?
            let probes: [Record]
            let channelPeak, channelRms: [Double]
        }
        let cases: [Case]
    }
    private let fixtures = roomRoot.appendingPathComponent("tests/fixtures/room-v9")

    @Test func independentRoomCasesMatchAcrossBuffers() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try #require(manifest.cases.count == 9)
        let preparer = try TonalSamplePreparer(
            bankURL: roomRoot.appendingPathComponent("Lowlight/SoundBank"))
        for item in manifest.cases {
            let input = try inputs(item, preparer: preparer)
            let room = try StereoRoom(space: item.space, warmth: item.warmth)
            let offset = item.inputEvents == nil ? HarmonicGlue.latencyFrames : 0
            let actual = try render(room, input: input, offset: offset, partitions: [512])
            room.reset()
            #expect(
                actual
                    == (try render(
                        room, input: input, offset: offset, partitions: [1, 17, 64, 127, 256, 1023]))
            )
            let aligned = (0..<item.frames).allSatisfy { index in
                let source = input[index + offset]
                let start = index * 7
                return actual[start + 2] == source.bass.0 && actual[start + 3] == source.bass.1
                    && actual[start + 4] == source.drums.0 && actual[start + 5] == source.drums.1
                    && actual[start + 6] == source.duck
            }
            #expect(aligned)
            try verify(actual, item: item)
            try export(actual, name: item.file)
        }
    }

    @Test func bridgeRejectsInvalidConfigurationAndLengths() throws {
        for value in [-Double.infinity, -0.01, 1.01, .infinity, .nan] {
            #expect(throws: StereoRoomError.self) { try StereoRoom(space: value, warmth: 0.78) }
            #expect(throws: StereoRoomError.self) { try StereoRoom(space: 0.70, warmth: value) }
        }
        let room = try StereoRoom(space: 0.70, warmth: 0.78)
        let input = [HarmonicGlueFrame(tonal: (0.25, -0.25), bass: (0, 0), drums: (0, 0), duck: 1)]
        var output = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: 2)
        #expect(
            !output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { room.process($0, into: destination) }
            })
        #expect(output.allSatisfy { $0.tonal == (0, 0) && $0.duck == 0 })
        #expect(
            room.process(
                UnsafeBufferPointer(start: nil, count: 0),
                into: UnsafeMutableBufferPointer(start: nil, count: 0)))
        output = [HarmonicGlueFrame()]
        #expect(
            output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { room.process($0, into: destination) }
            })
        #expect(output[0].tonal == (0.25 * Float(0.92), -0.25 * Float(0.92)))
        #expect(output[0].duck == 1 && StereoRoom.tonalLimit == 1024)
    }

    private func inputs(_ item: Manifest.Case, preparer: TonalSamplePreparer) throws
        -> [HarmonicGlueFrame]
    {
        if let events = item.inputEvents {
            try #require(item.frames == item.inputFrames)
            var result = [HarmonicGlueFrame](
                repeating: HarmonicGlueFrame(
                    tonal: (0, 0), bass: (0, 0), drums: (0, 0), duck: 1), count: item.frames)
            for event in events {
                try #require(result.indices.contains(event.frame) && event.values.count == 7)
                let values = event.values.map(Float.init)
                result[event.frame] = HarmonicGlueFrame(
                    tonal: (values[0], values[1]), bass: (values[2], values[3]),
                    drums: (values[4], values[5]), duck: values[6])
            }
            return result
        }
        let file = try #require(item.eventsFile)
        let energy = try #require(item.energy)
        try #require(item.focus == "guitar" || item.focus == "piano")
        let events = try NoteEvent.importReference(
            Data(contentsOf: fixtures.appendingPathComponent(file)))
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: events, warmth: item.warmth, busEnergy: energy)
        #expect(mixer.preparedBytes == item.preparedBytes)
        let count = item.frames + HarmonicGlue.latencyFrames
        try #require(count < item.inputFrames)
        var buses = [RhythmBusFrame](repeating: RhythmBusFrame(), count: count)
        #expect(buses.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        let glue = try HarmonicGlue(
            inputFrames: UInt64(item.inputFrames),
            focus: item.focus == "guitar" ? .guitar : .piano)
        var result = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: count)
        // This remains a prefix of the original full rack, never a fabricated endpoint.
        #expect(
            result.withUnsafeMutableBufferPointer { destination in
                buses.withUnsafeBufferPointer { glue.process($0, into: destination) }
            })
        return result
    }

    private func render(
        _ room: StereoRoom, input: [HarmonicGlueFrame], offset: Int,
        partitions: [Int]
    ) throws -> [Float] {
        var output = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: input.count)
        try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination in
                var position = 0
                var block = 0
                while position < source.count {
                    let end =
                        position
                        + min(partitions[block % partitions.count], source.count - position)
                    try #require(
                        room.process(
                            UnsafeBufferPointer(rebasing: source[position..<end]),
                            into: UnsafeMutableBufferPointer(rebasing: destination[position..<end]))
                    )
                    position = end
                    block += 1
                }
            }
        }
        #expect(output.prefix(offset).allSatisfy { $0.tonal == (0, 0) && $0.duck == 1 })
        var samples: [Float] = []
        samples.reserveCapacity((input.count - offset) * 7)
        for frame in output.dropFirst(offset) {
            samples.append(contentsOf: [
                frame.tonal.0, frame.tonal.1, frame.bass.0, frame.bass.1,
                frame.drums.0, frame.drums.1, frame.duck,
            ])
        }
        return samples
    }

    private func verify(_ samples: [Float], item: Manifest.Case) throws {
        try #require(samples.count == item.frames * 7 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 7 && item.channelRms.count == 7)
        let maximumError = item.inputEvents == nil ? 1e-5 : 2e-6
        let rmsError = item.inputEvents == nil ? 1e-6 : 2e-7
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
            let data = try Data(contentsOf: fixtures.appendingPathComponent(file))
            try #require(data.count == samples.count * 4)
            var squared = 0.0
            var maximum = 0.0
            data.withUnsafeBytes { bytes in
                for index in samples.indices {
                    let value = Float(
                        bitPattern: UInt32(
                            littleEndian:
                                bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                    let error = Double(samples[index]) - Double(value)
                    maximum = max(maximum, abs(error))
                    squared += error * error
                }
            }
            #expect(maximum <= maximumError && sqrt(squared / Double(samples.count)) <= rmsError)
        }
    }

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("room")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(roomRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw StereoRoomError.invalidConfiguration }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
