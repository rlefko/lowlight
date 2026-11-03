// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let preparedRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct PreparedSongTests {
    private let frames: UInt32 = 65_553
    private let body: Range<UInt32> = 32_000..<44_800

    @Test func measuredReplayMatchesIndependentStagesWithActiveProtection() throws {
        let preparer = try bank()
        let expected = try independent(preparer)
        #expect(expected.gained.map(\.bitPattern) != expected.output.map(\.bitPattern))
        #expect(expected.gained.map { abs($0) }.max() ?? 0 > 1)
        for origin: UInt64 in [0, 1 << 40] {
            let song = try make(preparer, origin: origin)
            #expect(song.position == 0 && !song.isFaulted)
            #expect(song.measurement == expected.measurement)
            #expect(song.gainDecibels == expected.gain.decibels)
            #expect(song.linearMultiplier == expected.gain.linearMultiplier)
            #expect(song.layout.frameOrigin == origin && song.layout.bodyFrames == body)
            #expect(song.preparedBytes > 0 && song.preparedBytes <= 32 * 1024 * 1024)
            let output = try render(song, partitions: [1, 17, 159, 160, 161, 1023])
            #expect(output.map(\.bitPattern) == expected.output.map(\.bitPattern))
            #expect(song.position == frames && song.stolenVoices == 0 && song.droppedEvents == 0)
            song.reset()
            #expect(song.measurement == expected.measurement && song.position == 0)
            #expect(
                try render(song, partitions: [8191]).map(\.bitPattern) == output.map(\.bitPattern))
        }
    }

    @Test func partialResetAndFiniteBufferRulesPreservePreparedGain() throws {
        let song = try make(bank())
        let expected = try render(song, partitions: [512])
        let gain = song.linearMultiplier
        song.reset()
        var empty: [Float] = []
        #expect(empty.withUnsafeMutableBufferPointer { song.render(into: $0) } == 0)
        var first: [Float] = [.nan, .nan]
        #expect(first.withUnsafeMutableBufferPointer { song.render(into: $0) } == 1)
        #expect(first.map(\.bitPattern) == Array(expected.prefix(2)).map(\.bitPattern))
        var odd: [Float] = [1, 1, 1]
        #expect(odd.withUnsafeMutableBufferPointer { song.render(into: $0) } == nil)
        #expect(odd == [0, 0, 0] && song.position == 1 && !song.isFaulted)
        song.reset()
        var oversized = [Float](repeating: .nan, count: Int(frames + 257) * 2)
        #expect(oversized.withUnsafeMutableBufferPointer { song.render(into: $0) } == Int(frames))
        #expect(
            Array(oversized.prefix(Int(frames) * 2)).map(\.bitPattern) == expected.map(\.bitPattern)
        )
        #expect(oversized.suffix(514).allSatisfy { $0 == 0 })
        first = [1, 1]
        #expect(first.withUnsafeMutableBufferPointer { song.render(into: $0) } == 0)
        #expect(first == [0, 0] && song.position == frames && song.linearMultiplier == gain)
    }

    @Test func minimumBodyAndUnmeasurableBodyUseFreshAnalysis() throws {
        let preparer = try bank()
        let minimum = try make(
            preparer, count: 12_800, range: 0..<12_800,
            events: [event(.guitar, start: 0, velocity: 0.5)])
        #expect(minimum.measurement.totalBlocks == 1 && minimum.measurement.integratedLUFS != nil)
        #expect(try render(minimum, partitions: [127]).count == 25_600)
        let outside = try [event(.kick, start: 0), event(.kick, start: Int64(frames) - 1000)]
        for events in [[], outside] {
            do {
                _ = try make(preparer, events: events)
                Issue.record("An unmeasurable body prepared a song")
            } catch PreparedSongError.unmeasurableBody {}
        }
    }

    private func bank() throws -> TonalSamplePreparer {
        try TonalSamplePreparer(bankURL: preparedRoot.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func event(
        _ instrument: NoteEvent.Instrument, start: Int64, velocity: Double = 1
    ) throws -> NoteEvent {
        let record: [String: Any] = [
            "formatVersion": 1, "instrument": instrument.rawValue,
            "role": instrument == .guitar ? "chord" : "drum", "articulation": "normal",
            "note": instrument == .guitar ? 60 : 0, "roundRobin": 0, "beat": 0,
            "velocity": velocity, "pan": -0.25,
            "startFrame": start, "gateEndFrame": start + 12_800, "releaseEndFrame": start + 20_992,
        ]
        return try JSONDecoder().decode(
            NoteEvent.self, from: JSONSerialization.data(withJSONObject: record))
    }

    private func score(_ origin: UInt64 = 0) throws -> [NoteEvent] {
        try [
            event(.kick, start: Int64(origin)),
            event(.guitar, start: Int64(origin) + 32_000, velocity: 0.03),
            event(.kick, start: Int64(origin) + Int64(frames) - 1000),
        ]
    }

    private func fades(_ origin: UInt64, _ count: UInt32) -> SongRackFades {
        SongRackFades(
            tonalOutStartFrame: Double(origin + UInt64(count) + 1024),
            tonalOutEndFrame: Double(origin + UInt64(count) + 2048),
            rhythmInFrame: Double(origin), rhythmOutFrame: Double(origin + UInt64(count) + 1500))
    }

    private func make(
        _ preparer: TonalSamplePreparer, origin: UInt64 = 0, count: UInt32? = nil,
        range: Range<UInt32>? = nil, events: [NoteEvent]? = nil
    ) throws -> PreparedSong {
        let count = count ?? frames
        return try PreparedSong(
            layout: SongRenderLayout(
                frameOrigin: origin, inputFrames: count, bodyFrames: range ?? body),
            preparer: preparer, events: events ?? score(origin), takeSeed: 1, focus: .guitar,
            warmth: 0.78, energy: 0.35, space: 0.44, texture: 0, rackFades: fades(origin, count))
    }

    private func render(_ song: PreparedSong, partitions: [Int]) throws -> [Float] {
        var output: [Float] = []
        var block = 0
        while true {
            var buffer = [Float](repeating: .nan, count: partitions[block % partitions.count] * 2)
            let count = try #require(
                buffer.withUnsafeMutableBufferPointer { song.render(into: $0) })
            #expect(buffer[(count * 2)...].allSatisfy { $0 == 0 })
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count * 2))
            block += 1
        }
        #expect(output.count == Int(song.layout.inputFrames) * 2 && output.allSatisfy(\.isFinite))
        return output
    }

    /// Independent body slicing and composition; does not call PreparedSong.
    private func independent(_ preparer: TonalSamplePreparer) throws -> (
        measurement: SongLoudnessMeasurement, gain: SongFixedGain, gained: [Float], output: [Float]
    ) {
        let source = try SongRenderSource(
            layout: SongRenderLayout(frameOrigin: 0, inputFrames: frames, bodyFrames: body),
            preparer: preparer, events: score(), takeSeed: 1, focus: .guitar,
            warmth: 0.78, energy: 0.35, space: 0.44, texture: 0, rackFades: fades(0, frames))
        var input = [Float](repeating: .nan, count: Int(frames) * 2)
        try #require(
            input.withUnsafeMutableBufferPointer { source.render(into: $0) } == Int(frames))
        let meter = try SongLoudnessMeter(bodyFrames: body.upperBound - body.lowerBound)
        try input.withUnsafeBufferPointer {
            try #require(
                meter.process(
                    UnsafeBufferPointer(
                        rebasing: $0[Int(body.lowerBound) * 2..<Int(body.upperBound) * 2])))
        }
        let measurement = try meter.finish()
        let gain = try SongFixedGain(measurement: measurement)
        var gained = input
        try gained.withUnsafeMutableBufferPointer { destination in
            try input.withUnsafeBufferPointer { try #require(gain.process($0, into: destination)) }
        }
        #expect(gained.map(\.bitPattern) != input.map(\.bitPattern))
        let protector = try PeakProtector(mode: .song)
        var delayed = [Float](repeating: .nan, count: gained.count + 320)
        try delayed.withUnsafeMutableBufferPointer { destination in
            try gained.withUnsafeBufferPointer {
                try #require(
                    protector.process(
                        $0, into: UnsafeMutableBufferPointer(rebasing: destination[..<gained.count])
                    ))
            }
            try #require(
                protector.drain(
                    into: UnsafeMutableBufferPointer(rebasing: destination[gained.count...])) == 160
            )
        }
        #expect(delayed.prefix(320).allSatisfy { $0 == 0 })
        return (measurement, gain, gained, Array(delayed.dropFirst(320)))
    }
}
