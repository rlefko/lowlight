// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Foundation
import Testing

@testable import LowlightAudio

struct PreparedSessionTests {
    private let origins: [UInt64] = [0, 16_017, 40_001, 56_018]
    private let frames = 80_017

    @Test func rollingFourSongsPreserveProtectionAcrossRetirementAndRetry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let expected = try independent(preparer)
        let fixtures = PreparedSongPairTests()
        var observed: SongPreparationPool?
        weak var oldest: PreparedSong?
        weak var survivor: PreparedSong?
        var index = 0
        var attempts: [Int] = []
        var failures = 0
        var session: PreparedSession? = try PreparationModeTests().environment(
            2, ll_test_flush_modes() - 1, true
        ) {
            try PreparedSession(
                frameCount: UInt32(frames), accepted: { index += 1 },
                prepare: { pool, _ in
                    observed = pool
                    attempts.append(index)
                    if index == 2 {
                        #expect(oldest == nil && survivor != nil && pool.reservedRacks == 1)
                    }
                    let child = try fixtures.make(
                        pool, preparer,
                        origin: origins[index] + (index == 2 && failures == 0 ? 1 : 0))
                    if index == 0 { oldest = child }
                    if index == 1 { survivor = child }
                    // First retry exercises native admission failure; the next exercises
                    // a throwing preparation after it has acquired a full rack reservation.
                    if index == 2 && failures < 2 {
                        failures += 1
                        if failures == 2 { throw PreparedSongPairError.preparationFailed }
                    }
                    return (
                        child,
                        index + 1 < origins.count ? UInt32(origins[index + 1]) : UInt32(frames)
                    )
                })
        }
        try withExtendedLifetime(session) {
            let value = try #require(session)
            #expect(throws: PreparedSessionError.renderEndpointUnavailable) {
                try value.makeRenderEndpoint()
            }
            #expect(observed?.reservedRacks == 2 && value.requiredVoiceSlots == 2)
            #expect(value.reservedPCMBytes == 64 * 1024 * 1024)
            #expect(throws: PreparedSessionError.notWaiting) { try value.prepareNext() }
            var odd: [Float] = [1, 1, 1]
            #expect(odd.withUnsafeMutableBufferPointer { value.render(into: $0) } == nil)
            #expect(odd == [0, 0, 0] && value.position == 0)
            var output: [Float] = []
            var block = 0
            var boundaries: [UInt32] = []
            let sizes = [1, 159, 160, 161, 257, 1023, frames]
            while value.position < frames {
                var buffer = [Float](repeating: .nan, count: 2 * sizes[block % sizes.count])
                let count = try #require(
                    buffer.withUnsafeMutableBufferPointer { value.render(into: $0) })
                #expect(buffer.dropFirst(2 * count).allSatisfy { $0 == 0 })
                output.append(contentsOf: buffer.prefix(2 * count))
                if value.needsPreparation {
                    boundaries.append(value.position)
                    buffer = [Float](repeating: .nan, count: 322)
                    #expect(buffer.withUnsafeMutableBufferPointer { value.render(into: $0) } == 0)
                    #expect(buffer.allSatisfy { $0 == 0 } && value.position == boundaries.last)
                    if index == 2 {
                        for _ in 0..<2 {
                            do {
                                try PreparationModeTests().environment(
                                    3, ll_test_flush_modes() - 1, true
                                ) {
                                    try value.prepareNext()
                                }
                                Issue.record("Expected successor preparation to fail")
                            } catch {
                                #expect(index == 2 && value.needsPreparation && !value.isFaulted)
                                #expect(
                                    observed?.reservedRacks == 1 && value.requiredVoiceSlots == 1)
                                #expect(
                                    oldest == nil && survivor != nil
                                        && value.position == boundaries.last)
                            }
                        }
                    }
                    try PreparationModeTests().environment(1, ll_test_flush_modes() - 1, true) {
                        try value.prepareNext()
                    }
                    #expect(!value.needsPreparation && observed?.reservedRacks == 2)
                } else {
                    try #require(count > 0)
                }
                block += 1
            }
            #expect(boundaries == [40_001 - 160, 56_018 - 160])
            #expect(attempts == [0, 1, 2, 2, 2, 3] && index == 4)
            #expect(output.map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(value.stolenVoices == 0 && value.droppedEvents == 0 && !value.isFaulted)
            #expect(!value.needsPreparation && value.position == frames)
            var tail = [Float](repeating: .nan, count: 514)
            #expect(tail.withUnsafeMutableBufferPointer { value.render(into: $0) } == 0)
            #expect(tail.allSatisfy { $0 == 0 })
            #expect(throws: PreparedSessionError.notWaiting) { try value.prepareNext() }
        }
        session = nil
        #expect(oldest == nil && survivor == nil && observed?.reservedRacks == 0)
        #expect(observed?.reservedVoiceSlots == 0 && observed?.preparedPCMBytes == 0)
    }

    /// Offline reference independently places all four complete children before protection.
    private func independent(_ preparer: TonalSamplePreparer) throws -> [Float] {
        let pool = SongPreparationPool()
        var sum = [Float](repeating: 0, count: 2 * frames)
        for origin in origins {
            let child = try PreparedSongPairTests().make(pool, preparer, origin: origin)
            var pcm = [Float](repeating: .nan, count: 80_002)
            try #require(pcm.withUnsafeMutableBufferPointer { child.render(into: $0) } == 40_001)
            for index in 0..<(2 * min(40_001, frames - Int(origin))) {
                sum[2 * Int(origin) + index] += pcm[index]
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
        return Array(output.dropFirst(320))
    }
}
