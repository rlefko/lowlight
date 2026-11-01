// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let rhythmRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct RhythmBusTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Probe: Decodable {
                let frame: Int
                let values: [Double]
            }
            let id, eventsFile: String
            let frames, eventCount, preparedBytes, tailSilenceStartFrame: Int
            let energy: Double
            let probes: [Probe]
            let channelPeak, channelRms: [Double]
        }
        let cases: [Case]
    }
    private let fixtures = rhythmRoot.appendingPathComponent("tests/fixtures/rhythm-v9")
    private let bank = rhythmRoot.appendingPathComponent("Lowlight/SoundBank")

    private func cases() throws -> [Manifest.Case] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))
        ).cases
    }

    private func events(_ item: Manifest.Case) throws -> [NoteEvent] {
        try NoteEvent.importReference(
            Data(contentsOf: fixtures.appendingPathComponent(item.eventsFile)))
    }

    @Test func configurationAndEmptyBuses() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        for energy in [-0.01, 1.01, .nan, .infinity, -.infinity] {
            #expect(throws: VoiceMixerError.self) {
                try TonalVoiceMixer(
                    preparer: preparer, events: [], warmth: 0.78, busEnergy: energy)
            }
        }
        for energy in [0.0, 0.35, 1.0] {
            let mixer = try TonalVoiceMixer(
                preparer: preparer, events: [], warmth: 0.78, busEnergy: energy)
            let output = try renderBuses(mixer, frames: 257, partitions: [1, 17, 64])
            for frame in 0..<257 {
                #expect(output[(frame * 9)..<(frame * 9 + 8)].allSatisfy { $0 == 0 })
                #expect(output[frame * 9 + 8] == 1)
            }
            #expect(mixer.position == 257 && mixer.preparedBytes == 0 && mixer.activeVoices == 0)
            var empty: [RhythmBusFrame] = []
            #expect(empty.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
            #expect(mixer.position == 257)
        }
        let dry = try TonalVoiceMixer(preparer: preparer, events: [], warmth: 0.78)
        var unavailable = [RhythmBusFrame()]
        #expect(!unavailable.withUnsafeMutableBufferPointer { dry.renderBuses(into: $0) })
        #expect(dry.position == 0)
    }

    @Test func independentBusCasesMatchAcrossBuffers() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let fixtures = try cases()
        #expect(fixtures.count == 3)
        for item in fixtures {
            let score = try events(item)
            #expect(score.count == item.eventCount)
            let mixer = try TonalVoiceMixer(
                preparer: preparer, events: score, warmth: 0.78, busEnergy: item.energy)
            #expect(mixer.preparedBytes <= item.preparedBytes)
            let actual = try renderBuses(mixer, frames: item.frames, partitions: [512])
            mixer.reset()
            #expect(
                actual
                    == (try renderBuses(
                        mixer, frames: item.frames, partitions: [1, 17, 64, 127, 256, 1023])))
            #expect(mixer.position == item.frames && mixer.activeVoices == 0)
            #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
            try verify(actual, against: item)
            try export(actual, name: item.id + ".f32")
        }
    }

    @Test func dryAndBusViewsShareStateWithoutChangingDrySound() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let item = try #require(cases().first { $0.id == "rhythm-prefix" })
        let score = try events(item)
        let configured = try TonalVoiceMixer(
            preparer: preparer, events: score, warmth: 0.78, busEnergy: item.energy)
        let dry = try TonalVoiceMixer(preparer: preparer, events: score, warmth: 0.78)
        let frames = 18_017
        let split = 4_097
        let expectedDry = try renderDry(dry, frames: frames)
        #expect(expectedDry == (try renderDry(configured, frames: frames)))
        configured.reset()
        let expectedBuses = try renderBuses(configured, frames: frames, partitions: [257])
        configured.reset()
        _ = try renderDry(configured, frames: split)
        #expect(
            Array(expectedBuses[(split * 9)...])
                == (try renderBuses(configured, frames: frames - split, partitions: [19, 503])))
        configured.reset()
        _ = try renderBuses(configured, frames: split, partitions: [127])
        #expect(
            Array(expectedDry[(split * 2)...])
                == (try renderDry(configured, frames: frames - split)))
        for (instrument, channel) in [(NoteEvent.Instrument.guitar, 0), (.piano, 2)] {
            let isolated = try TonalVoiceMixer(
                preparer: preparer, events: score.filter { $0.instrument == instrument },
                warmth: 0.78)
            let samples = try renderDry(isolated, frames: frames)
            var separated: [Float] = []
            separated.reserveCapacity(frames * 2)
            for frame in 0..<frames {
                let offset = frame * 9 + channel
                separated.append(expectedBuses[offset])
                separated.append(expectedBuses[offset + 1])
            }
            #expect(separated == samples)
        }
    }

    private func verify(_ samples: [Float], against item: Manifest.Case) throws {
        try #require(samples.count == item.frames * 9 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 9 && item.channelRms.count == 9)
        for channel in 0..<9 {
            let maximumError = channel == 8 ? 1e-7 : 1e-5
            let rmsError = channel == 8 ? 1e-8 : 1e-6
            var peak = 0.0
            var squared = 0.0
            var tailMatches = true
            for frame in 0..<item.frames {
                let value = Double(samples[frame * 9 + channel])
                peak = max(peak, abs(value))
                squared += value * value
                if frame >= item.tailSilenceStartFrame {
                    tailMatches = tailMatches && value == (channel == 8 ? 1 : 0)
                }
            }
            #expect(tailMatches)
            #expect(abs(peak - item.channelPeak[channel]) <= maximumError)
            #expect(abs(sqrt(squared / Double(item.frames)) - item.channelRms[channel]) <= rmsError)
            for probe in item.probes {
                try #require((0..<item.frames).contains(probe.frame) && probe.values.count == 9)
                #expect(
                    abs(Double(samples[probe.frame * 9 + channel]) - probe.values[channel])
                        <= maximumError)
            }
        }
    }

    private func renderBuses(
        _ mixer: TonalVoiceMixer, frames: Int, partitions: [Int]
    ) throws -> [Float] {
        let unset = RhythmBusFrame(
            guitar: (.nan, .nan), piano: (.nan, .nan), bass: (.nan, .nan), drums: (.nan, .nan),
            duck: .nan)
        var output = [RhythmBusFrame](repeating: unset, count: frames)
        try output.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            var block = 0
            while frame < frames {
                let count = min(partitions[block % partitions.count], frames - frame)
                try #require(
                    mixer.renderBuses(
                        into: UnsafeMutableBufferPointer(
                            rebasing: buffer[frame..<(frame + count)])))
                frame += count
                block += 1
            }
        }
        var samples: [Float] = []
        samples.reserveCapacity(frames * 9)
        for frame in output {
            samples.append(frame.guitar.0)
            samples.append(frame.guitar.1)
            samples.append(frame.piano.0)
            samples.append(frame.piano.1)
            samples.append(frame.bass.0)
            samples.append(frame.bass.1)
            samples.append(frame.drums.0)
            samples.append(frame.drums.1)
            samples.append(frame.duck)
        }
        return samples
    }

    private func renderDry(_ mixer: TonalVoiceMixer, frames: Int) throws -> [Float] {
        var output = [Float](repeating: .nan, count: frames * 2)
        try output.withUnsafeMutableBufferPointer { buffer in
            try #require(mixer.render(into: buffer))
        }
        return output
    }

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("rhythm")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(rhythmRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw VoiceMixerError.invalidScore }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
