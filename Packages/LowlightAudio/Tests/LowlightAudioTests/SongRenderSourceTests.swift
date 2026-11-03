// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongRenderSourceTests {
    private let frames = 32_769

    @Test func finiteSourceMatchesPrimitiveChainAcrossOriginsPartitionsAndReset() throws {
        let preparer = try bank()
        let expected = try primitiveChain(preparer)
        #expect(expected.suffix(798).contains { $0 & 0x7fff_ffff != 0 })
        for origin: UInt64 in [0, 1 << 40] {
            let source = try makeSource(preparer, origin: origin)
            #expect(source.layout.frameOrigin == origin && source.position == 0)
            let actual = try render(source, partitions: [1, 17, 257, 1023])
            #expect(actual == expected)
            #expect(source.position == UInt32(frames) && !source.isFaulted)
            #expect(source.preparedBytes > 0 && source.preparedBytes <= 32 * 1024 * 1024)
            #expect(source.stolenVoices == 0 && source.droppedEvents == 0)
            source.reset()
            #expect(source.position == 0 && !source.isFaulted)
            #expect(try render(source, partitions: [65_536]) == expected)
        }
    }

    @Test func partialResetAndRejectedOutputPreserveFiniteState() throws {
        let source = try makeSource(bank())
        let expected = try render(source, partitions: [512])
        source.reset()
        var empty: [Float] = []
        #expect(empty.withUnsafeMutableBufferPointer { source.render(into: $0) } == 0)
        var first: [Float] = [.nan, .nan]
        #expect(first.withUnsafeMutableBufferPointer { source.render(into: $0) } == 1)
        #expect(first.map(\.bitPattern) == Array(expected.prefix(2)))
        var odd: [Float] = [1, 1, 1]
        #expect(odd.withUnsafeMutableBufferPointer { source.render(into: $0) } == nil)
        #expect(odd == [0, 0, 0] && source.position == 1 && !source.isFaulted)
        source.reset()
        #expect(try render(source, partitions: [399, 400, 8191]) == expected)
        var after: [Float] = [1, 1, 1, 1]
        #expect(after.withUnsafeMutableBufferPointer { source.render(into: $0) } == 0)
        #expect(after == [0, 0, 0, 0] && source.position == UInt32(frames))
        #expect(empty.withUnsafeMutableBufferPointer { source.render(into: $0) } == 0)
    }

    @Test func invalidFiniteScoreRejectsBeforeDecoding() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: sourceRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: temporary.appendingPathComponent(name))
        }
        let missing = try TonalSamplePreparer(bankURL: temporary)
        let early = try event(.guitar, start: 0)
        let late = try event(.guitar, start: Int64(frames))
        for (origin, events, seed) in [
            (UInt64(0), [late], UInt32(0)), (1, [early], 0),
            (0, [try event(.guitar, start: 1), early], 0),
            (0, Array(repeating: early, count: 2049), 0), (0, [early], 1 << 31),
        ] {
            do {
                _ = try makeSource(missing, origin: origin, events: events, seed: seed)
                Issue.record("Invalid finite source accepted")
            } catch SongRenderSourceError.invalidConfiguration {}
        }
        for controls in [
            (Double.nan, 0.35, 0.44, 0.09),
            (0.78, Double(bitPattern: 0x8000_0000_0000_0001), 0.44, 0.09),
            (0.78, 0.35, Double(bitPattern: 0x3ff0_0000_0000_0001), 0.09),
            (0.78, 0.35, 0.44, -0.1),
        ] {
            do {
                _ = try makeSource(missing, events: [early], controls: controls)
                Issue.record("Invalid source controls accepted")
            } catch SongRenderSourceError.invalidConfiguration {}
        }
    }

    private func bank() throws -> TonalSamplePreparer {
        try TonalSamplePreparer(bankURL: sourceRoot.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func fades(_ origin: UInt64 = 0) -> SongRackFades {
        SongRackFades(
            tonalInStartFrame: Double(origin), tonalInEndFrame: Double(origin + 1024),
            tonalOutStartFrame: Double(origin + UInt64(frames) + 1024),
            tonalOutEndFrame: Double(origin + UInt64(frames) + 2048),
            rhythmInFrame: Double(origin), rhythmOutFrame: Double(origin + UInt64(frames) + 1500))
    }

    private func score(_ origin: UInt64 = 0) throws -> [NoteEvent] {
        try NoteEvent.Instrument.allCases.enumerated().map {
            try event($0.element, start: Int64(origin) + Int64($0.offset * 37))
        } + [event(.piano, start: Int64(origin) + Int64(frames) - 17)]
    }

    private func event(_ instrument: NoteEvent.Instrument, start: Int64) throws -> NoteEvent {
        let harmonic = instrument == .guitar || instrument == .piano
        let record: [String: Any] = [
            "formatVersion": 1, "instrument": instrument.rawValue,
            "role": harmonic ? "chord" : (instrument == .bass ? "bass" : "drum"),
            "articulation": "normal",
            "note": harmonic ? 60 : (instrument == .bass ? 31 : (instrument == .snare ? 1 : 0)),
            "roundRobin": 1, "beat": 0, "velocity": 0.72, "pan": -0.25,
            "startFrame": start, "gateEndFrame": start + 4096, "releaseEndFrame": start + 8192,
        ]
        return try JSONDecoder().decode(
            NoteEvent.self, from: JSONSerialization.data(withJSONObject: record))
    }

    private func makeSource(
        _ preparer: TonalSamplePreparer, origin: UInt64 = 0,
        events: [NoteEvent]? = nil, seed: UInt32 = 1_278_560_406,
        controls: (Double, Double, Double, Double) = (0.78, 0.35, 0.44, 0.09)
    ) throws -> SongRenderSource {
        try SongRenderSource(
            layout: SongRenderLayout(
                frameOrigin: origin, inputFrames: UInt32(frames), bodyFrames: 1024..<30000),
            preparer: preparer, events: events ?? score(origin), takeSeed: seed, focus: .guitar,
            warmth: controls.0, energy: controls.1, space: controls.2, texture: controls.3,
            rackFades: fades(origin))
    }

    private func render(_ source: SongRenderSource, partitions: [Int]) throws -> [UInt32] {
        var result: [UInt32] = []
        var block = 0
        while true {
            var buffer = [Float](repeating: .nan, count: partitions[block % partitions.count] * 2)
            let count = try #require(
                buffer.withUnsafeMutableBufferPointer { source.render(into: $0) })
            try #require(count >= 0 && count * 2 <= buffer.count)
            #expect(buffer.dropFirst(count * 2).allSatisfy { $0 == 0 })
            #expect(buffer.allSatisfy { $0.isFinite })
            result += buffer.prefix(count * 2).map(\.bitPattern)
            if count == 0 { break }
            block += 1
        }
        #expect(result.count == frames * 2)
        return result
    }

    /// Independent wiring of the already-tested primitives; no SongRenderSource calls.
    private func primitiveChain(_ preparer: TonalSamplePreparer) throws -> [UInt32] {
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: score(), warmth: 0.78,
            busEnergy: 0.35, rackFades: fades())
        let glue = try HarmonicGlue(inputFrames: UInt64(frames), focus: .guitar)
        let room = try StereoRoom(space: 0.44, warmth: 0.78)
        let mix = try SongMix(
            takeSeed: 1_278_560_406, inputFrames: UInt32(frames), frameOrigin: 0,
            texture: 0.09, rackFades: fades())
        var buses = [RhythmBusFrame](repeating: RhythmBusFrame(), count: frames)
        var delayed = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: frames + 399)
        try #require(buses.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
        try delayed.withUnsafeMutableBufferPointer { destination in
            try buses.withUnsafeBufferPointer {
                try #require(
                    glue.process(
                        $0, into: UnsafeMutableBufferPointer(rebasing: destination[..<frames])))
            }
            try #require(
                glue.drain(into: UnsafeMutableBufferPointer(rebasing: destination[frames...]))
                    == 399)
        }
        var wet = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: frames)
        try wet.withUnsafeMutableBufferPointer { destination in
            try delayed.withUnsafeBufferPointer {
                try #require(
                    room.process(UnsafeBufferPointer(rebasing: $0[399...]), into: destination))
            }
        }
        var output = [Float](repeating: 0, count: frames * 2)
        try output.withUnsafeMutableBufferPointer { destination in
            try wet.withUnsafeBufferPointer { try #require(mix.process($0, into: destination)) }
        }
        return output.map(\.bitPattern)
    }
}
