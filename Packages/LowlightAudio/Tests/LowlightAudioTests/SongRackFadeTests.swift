// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let fadesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongRackFadeTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            struct Probe: Decodable {
                let frame: Int
                let values: [Double]
            }
            let id, file, eventsFile: String
            let frames, preparedBytes: Int
            let warmth, energy: Double
            let incomingStartSeconds, incomingEndSeconds: Double
            let outgoingStartSeconds, outgoingEndSeconds, rhythmHandoffSeconds: Double
            let rhythmStartFrame: Double
            let probes: [Probe]
            let channelPeak, channelRms: [Double]

            var fades: SongRackFades {
                SongRackFades(
                    tonalInStartFrame: incomingStartSeconds * 32_000,
                    tonalInEndFrame: incomingEndSeconds * 32_000,
                    tonalOutStartFrame: outgoingStartSeconds * 32_000,
                    tonalOutEndFrame: outgoingEndSeconds * 32_000,
                    rhythmInFrame: rhythmStartFrame,
                    rhythmOutFrame: rhythmHandoffSeconds * 32_000)
            }
        }
        let cases: [Case]
    }
    private let fixtures = fadesRoot.appendingPathComponent("tests/fixtures/fades-v9")
    private let bank = fadesRoot.appendingPathComponent("Lowlight/SoundBank")

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

    @Test func independentFadesMatchAcrossPartitionsAndReset() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let items = try cases()
        try #require(items.count == 2)
        for item in items {
            let mixer = try TonalVoiceMixer(
                preparer: preparer, events: events(item), warmth: item.warmth,
                busEnergy: item.energy, rackFades: item.fades)
            #expect(mixer.preparedBytes == item.preparedBytes)
            let actual = try buses(mixer, frames: item.frames, partitions: [512])
            mixer.reset()
            #expect(
                actual
                    == (try buses(
                        mixer, frames: item.frames, partitions: [1, 17, 64, 127, 256, 1023])))
            #expect(mixer.position == item.frames && mixer.activeVoices == 0)
            #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
            try verify(actual, item: item)
            try export(actual, name: item.file)
        }
    }

    @Test func dryViewIsUnchangedAndAdvancesFadedBuses() throws {
        let item = try #require(cases().first)
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let score = try events(item)
        let faded = try TonalVoiceMixer(
            preparer: preparer, events: score, warmth: item.warmth,
            busEnergy: item.energy, rackFades: item.fades)
        let raw = try TonalVoiceMixer(preparer: preparer, events: score, warmth: item.warmth)
        let frames = 210_017
        let split = 100_017
        let expectedDry = try dry(raw, frames: frames)
        #expect(expectedDry == (try dry(faded, frames: frames)))
        faded.reset()
        let expectedBuses = try buses(faded, frames: frames, partitions: [257])
        faded.reset()
        _ = try dry(faded, frames: split)
        #expect(
            Array(expectedBuses[(split * 9)...])
                == (try buses(faded, frames: frames - split, partitions: [19, 503])))
        faded.reset()
        _ = try buses(faded, frames: split, partitions: [127])
        #expect(Array(expectedDry[(split * 2)...]) == (try dry(faded, frames: frames - split)))
    }

    @Test func bridgeRejectsFadesWithoutBusesAndInvalidDescriptors() throws {
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let valid = SongRackFades(
            tonalOutStartFrame: 200, tonalOutEndFrame: 500, rhythmOutFrame: 400)
        #expect(throws: VoiceMixerError.self) {
            try TonalVoiceMixer(preparer: preparer, events: [], warmth: 0.78, rackFades: valid)
        }
        for fades in [
            SongRackFades(tonalOutStartFrame: 200, tonalOutEndFrame: 200, rhythmOutFrame: 400),
            SongRackFades(tonalOutStartFrame: .nan, tonalOutEndFrame: 500, rhythmOutFrame: 400),
            SongRackFades(
                tonalOutStartFrame: 200, tonalOutEndFrame: 500,
                rhythmInFrame: 401, rhythmOutFrame: 400),
        ] {
            #expect(throws: VoiceMixerError.self) {
                try TonalVoiceMixer(
                    preparer: preparer, events: [], warmth: 0.78, busEnergy: 0.35,
                    rackFades: fades)
            }
        }
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: [], warmth: 0.78, busEnergy: 0.35, rackFades: valid)
        let output = try buses(mixer, frames: 513, partitions: [1, 17, 256])
        #expect(output.enumerated().allSatisfy { $0.element == ($0.offset % 9 == 8 ? 1 : 0) })
    }

    @Test func nativeSchedulesKeepTheirSharedRoundedClock() throws {
        for (from, to) in [(60.0, 100.0), (100.0, 60.0)] {
            var planner = try SongPlanner(controls: Controls(variation: 0, tempo: from))
            let predecessor = try planner.next()
            try planner.setControls(Controls(variation: 0, tempo: to))
            let outgoingPlan = try planner.next()
            let incomingPlan = try planner.next()
            #expect(outgoingPlan.tempo == from && incomingPlan.tempo == to)
            let first = try SongSchedule(song: predecessor, successor: outgoingPlan)
            let firstFades = try SongRackFades(schedule: first)
            #expect(
                firstFades.tonalInStartFrame == 0 && firstFades.tonalInEndFrame == 0
                    && firstFades.rhythmInFrame == 0)
            for origin in [0.0, 86_400.123456] {
                let arrival = try SongTransition(
                    from: predecessor, to: outgoingPlan, startSeconds: origin)
                let outgoing = try SongSchedule(
                    song: outgoingPlan, successor: incomingPlan, incoming: arrival)
                let incoming = try SongSchedule(
                    song: incomingPlan, successor: planner.pending, incoming: outgoing.outgoing)
                for schedule in [outgoing, incoming] {
                    let fades = try SongRackFades(schedule: schedule)
                    let transition = try #require(schedule.incoming)
                    #expect(fades.tonalInStartFrame == Double(try transition.ramp.frame(at: 0)))
                    #expect(fades.tonalInEndFrame == Double(try transition.ramp.frame(at: 16)))
                    #expect(fades.rhythmInFrame == Double(try transition.handoffFrame()))
                    #expect(
                        fades.tonalOutStartFrame == Double(try schedule.outgoing.ramp.frame(at: 0)))
                    #expect(
                        fades.tonalOutEndFrame == Double(try schedule.outgoing.ramp.frame(at: 16)))
                    #expect(fades.rhythmOutFrame == Double(try schedule.outgoing.handoffFrame()))
                }
                let old = try SongRackFades(schedule: outgoing)
                let new = try SongRackFades(schedule: incoming)
                #expect(old.tonalOutStartFrame == new.tonalInStartFrame)
                #expect(old.tonalOutEndFrame == new.tonalInEndFrame)
                #expect(old.rhythmOutFrame == new.rhythmInFrame)
                // Beat eight is not the elapsed-time midpoint of a changing tempo.
                #expect(
                    abs(
                        (old.rhythmOutFrame - old.tonalOutStartFrame)
                            / (old.tonalOutEndFrame - old.tonalOutStartFrame) - 0.5) > 0.05)
            }
        }
    }

    private func verify(_ samples: [Float], item: Manifest.Case) throws {
        try #require(samples.count == item.frames * 9 && samples.allSatisfy(\.isFinite))
        try #require(item.channelPeak.count == 9 && item.channelRms.count == 9)
        for channel in 0..<9 {
            let maximumError = channel == 8 ? 1e-7 : 1e-5
            let rmsError = channel == 8 ? 1e-8 : 1e-6
            var peak = 0.0
            var squared = 0.0
            var silenceMatches = true
            for frame in 0..<item.frames {
                let value = Double(samples[frame * 9 + channel])
                peak = max(peak, abs(value))
                squared += value * value
                if (channel < 4 && frame >= 329_601)
                    || ((4..<6).contains(channel) && frame >= 188_801)
                    || (channel < 8 && frame >= 400_000)
                {
                    silenceMatches = silenceMatches && value == 0
                }
            }
            #expect(silenceMatches)
            #expect(abs(peak - item.channelPeak[channel]) <= maximumError)
            #expect(abs(sqrt(squared / Double(item.frames)) - item.channelRms[channel]) <= rmsError)
            for probe in item.probes {
                try #require((0..<item.frames).contains(probe.frame) && probe.values.count == 9)
                let actual = samples[probe.frame * 9 + channel]
                if channel == 8 {
                    #expect(actual == Float(probe.values[channel]))
                } else {
                    let strictTail =
                        (6..<8).contains(channel) && (188_801..<192_001).contains(probe.frame)
                    #expect(
                        abs(Double(actual) - probe.values[channel])
                            <= (strictTail ? 1e-8 : maximumError))
                }
            }
        }
    }

    private func buses(_ mixer: TonalVoiceMixer, frames: Int, partitions: [Int]) throws -> [Float] {
        var output = [RhythmBusFrame](repeating: RhythmBusFrame(), count: frames)
        try output.withUnsafeMutableBufferPointer { buffer in
            var frame = 0
            var block = 0
            while frame < frames {
                let end = frame + min(partitions[block % partitions.count], frames - frame)
                try #require(
                    mixer.renderBuses(
                        into: UnsafeMutableBufferPointer(rebasing: buffer[frame..<end])))
                frame = end
                block += 1
            }
        }
        return output.flatMap {
            [
                $0.guitar.0, $0.guitar.1, $0.piano.0, $0.piano.1, $0.bass.0, $0.bass.1,
                $0.drums.0, $0.drums.1, $0.duck,
            ]
        }
    }

    private func dry(_ mixer: TonalVoiceMixer, frames: Int) throws -> [Float] {
        var output = [Float](repeating: .nan, count: frames * 2)
        try output.withUnsafeMutableBufferPointer { try #require(mixer.render(into: $0)) }
        return output
    }

    private func export(_ samples: [Float], name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("fades")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            .standardizedFileURL
        guard directory.path.hasPrefix(fadesRoot.path + "/.build/"),
            destination.path.hasPrefix(directory.path + "/")
        else { throw VoiceMixerError.invalidScore }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = samples.map { $0.bitPattern.littleEndian }
        try words.withUnsafeBytes { try Data($0).write(to: destination, options: .atomic) }
    }
}
