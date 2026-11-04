// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let pairRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct PreparedSongPairTests {
    private let frames = 50_003
    private let arrival: UInt64 = 16_017

    @Test func finitePairMatchesIndependentSumFadesAndProtectionAcrossReset() throws {
        let preparer = try TonalSamplePreparer(
            bankURL: pairRoot.appendingPathComponent("Lowlight/SoundBank"))
        let expected = try independent(preparer)
        var observed: SongPreparationPool?
        weak var firstLifetime: PreparedSong?
        weak var secondLifetime: PreparedSong?
        var pair: PreparedSongPair? = try PreparationModeTests().environment(
            2, ll_test_flush_modes() - 1, true
        ) {
            try PreparedSongPair(frameCount: UInt32(frames)) { pool in
                observed = pool
                let first = try make(pool, preparer, origin: 0)
                let second = try make(pool, preparer, origin: arrival)
                firstLifetime = first
                secondLifetime = second
                return (first, second)
            }
        }
        try withExtendedLifetime(pair) {
            let value = try #require(pair)
            #expect(value.position == 0 && !value.isFaulted && value.frameCount == frames)
            #expect(value.requiredVoiceSlots == 2 && value.preparedPCMBytes > 0)
            #expect(value.reservedPCMBytes == 64 * 1024 * 1024 && observed?.reservedRacks == 2)
            var empty: [Float] = []
            #expect(empty.withUnsafeMutableBufferPointer { value.render(into: $0) } == 0)
            var first: [Float] = [.nan, .nan]
            let written = try PreparationModeTests().environment(
                3, ll_test_flush_modes() - 1, true
            ) { first.withUnsafeMutableBufferPointer { value.render(into: $0) } }
            #expect(written == 1 && first.map(\.bitPattern) == expected.prefix(2).map(\.bitPattern))
            var odd: [Float] = [1, 1, 1]
            #expect(odd.withUnsafeMutableBufferPointer { value.render(into: $0) } == nil)
            #expect(odd == [0, 0, 0] && value.position == 1 && !value.isFaulted)
            value.reset()
            let output = try render(value, sizes: [1, 159, 160, 161, 257, 1023])
            #expect(output.map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(value.position == frames && value.stolenVoices == 0 && value.droppedEvents == 0)
            #expect(observed?.reservedRacks == 2 && firstLifetime != nil && secondLifetime != nil)
            value.reset()
            #expect(value.position == 0 && observed?.reservedVoiceSlots == 2)
            #expect(
                try render(value, sizes: [frames + 257]).map(\.bitPattern)
                    == output.map(\.bitPattern))
        }
        pair = nil
        #expect(firstLifetime == nil && secondLifetime == nil)
        #expect(observed?.reservedRacks == 0 && observed?.reservedVoiceSlots == 0)
        #expect(observed?.preparedPCMBytes == 0 && observed?.reservedPCMBytes == 0)
    }

    @Test func secondChildFailureReleasesTheFirstAndEveryReservation() throws {
        let preparer = try TonalSamplePreparer(
            bankURL: pairRoot.appendingPathComponent("Lowlight/SoundBank"))
        var observed: SongPreparationPool?
        weak var firstLifetime: PreparedSong?
        do {
            _ = try PreparationModeTests().environment(1, ll_test_flush_modes() - 1, true) {
                try PreparedSongPair(frameCount: UInt32(frames)) { pool in
                    observed = pool
                    let first = try make(pool, preparer, origin: 0)
                    firstLifetime = first
                    return (first, try make(pool, preparer, origin: arrival, silent: true))
                }
            }
            Issue.record("An unmeasurable second song prepared a pair")
        } catch PreparedSongError.unmeasurableBody {}
        #expect(firstLifetime == nil && observed?.reservedRacks == 0)
        #expect(observed?.reservedVoiceSlots == 0 && observed?.preparedPCMBytes == 0)
    }

    @Test func invalidAdjacencyAndFiniteBoundsRejectBeforeDecoding() throws {
        var timeline = try SessionTimeline()
        let first = try timeline.next()
        let second = try timeline.next()
        let third = try timeline.next()
        let start = UInt32(try second.frame(at: 0))
        let end = UInt32(try second.outgoing.ramp.frame(at: 0))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: pairRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: temporary.appendingPathComponent(name))
        }
        let missing = try TonalSamplePreparer(bankURL: temporary)
        for (left, right, count) in [
            (first, first, start + 1), (second, third, end + 1),
            (first, third, end + 1), (first, second, 0),
            (first, second, start), (first, second, end + 1),
        ] {
            do {
                _ = try PreparationModeTests().environment(2, ll_test_flush_modes() - 1, true) {
                    try PreparedSongPair(
                        first: left, second: right, frameCount: count, preparer: missing)
                }
                Issue.record("An invalid pair reached sample decoding")
            } catch PreparedSongPairError.invalidPair {}
        }
    }

    private func make(
        _ pool: SongPreparationPool, _ preparer: TonalSamplePreparer,
        origin: UInt64, silent: Bool = false
    ) throws -> PreparedSong {
        let record: [String: Any] = [
            "formatVersion": 1, "instrument": "guitar", "role": "chord", "articulation": "normal",
            "note": origin == 0 ? 60 : 64, "roundRobin": 0, "beat": 0, "velocity": 0.5,
            "pan": origin == 0 ? -0.25 : 0.375, "startFrame": origin,
            "gateEndFrame": origin + 12_800, "releaseEndFrame": origin + 20_992,
        ]
        let event = try JSONDecoder().decode(
            NoteEvent.self, from: JSONSerialization.data(withJSONObject: record))
        return try pool.prepare(
            layout: SongRenderLayout(
                frameOrigin: origin, inputFrames: 40_001, bodyFrames: 0..<12_800),
            preparer: preparer, events: silent ? [] : [event], takeSeed: 1, focus: .guitar,
            warmth: 0.78, energy: 0.35, space: 0.44, texture: 0,
            rackFades: SongRackFades(
                tonalOutStartFrame: Double(origin + 24_000),
                tonalOutEndFrame: Double(origin + 32_000),
                rhythmInFrame: Double(origin), rhythmOutFrame: Double(origin + 28_000)))
    }

    private func render(_ pair: PreparedSongPair, sizes: [Int]) throws -> [Float] {
        var result: [Float] = []
        var block = 0
        while true {
            var output = [Float](repeating: .nan, count: 2 * sizes[block % sizes.count])
            let count = try #require(
                output.withUnsafeMutableBufferPointer { pair.render(into: $0) })
            let finite = output.allSatisfy(\.isFinite)
            #expect(finite && output.dropFirst(count * 2).allSatisfy { $0 == 0 })
            if count == 0 { break }
            result.append(contentsOf: output.prefix(count * 2))
            block += 1
        }
        #expect(result.count == frames * 2)
        return result
    }

    /// Existing children and protector, independently placed/faded; never calls the pair renderer.
    private func independent(_ preparer: TonalSamplePreparer) throws -> [Float] {
        let pool = SongPreparationPool()
        var sum = [Float](repeating: 0, count: frames * 2)
        for origin in [UInt64(0), arrival] {
            let child = try make(pool, preparer, origin: origin)
            var output = [Float](repeating: .nan, count: Int(child.layout.inputFrames) * 2)
            try #require(output.withUnsafeMutableBufferPointer { child.render(into: $0) } == 40_001)
            for index in 0..<(min(40_001, frames - Int(origin)) * 2) {
                sum[Int(origin) * 2 + index] += output[index]
            }
        }
        for frame in 0..<frames {
            for channel in 0..<2 {
                let index = frame * 2 + channel
                sum[index] = Float(Double(sum[index]) * min(1, Double(frame) / 12_800))
                sum[index] = Float(Double(sum[index]) * min(1, Double(frames - frame) / 89_600))
            }
        }
        let peak = try PeakProtector(mode: .session)
        var output = [Float](repeating: .nan, count: sum.count + 320)
        try output.withUnsafeMutableBufferPointer { destination in
            try sum.withUnsafeBufferPointer {
                try #require(
                    peak.process(
                        $0, into: UnsafeMutableBufferPointer(rebasing: destination[..<sum.count])))
            }
            try #require(
                peak.drain(into: UnsafeMutableBufferPointer(rebasing: destination[sum.count...]))
                    == 160)
        }
        #expect(output.prefix(320).allSatisfy { $0 == 0 })
        return Array(output.dropFirst(320))
    }
}
