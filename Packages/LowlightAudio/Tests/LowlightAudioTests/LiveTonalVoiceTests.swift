// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct LiveTonalVoiceTests {
    @Test func preparedAndStreamingVoicesProduceIdenticalPCMAtFixedWarmth() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let score = try NoteEvent.importReference(
            Data(contentsOf: root.appendingPathComponent("tests/fixtures/voices-v9/events.json")))
        let events = Array(score.prefix(6))
        let frameCount = 4 * 32_000
        try #require(events.filter { $0.instrument == .guitar }.count == 4)
        try #require(events.filter { $0.instrument == .piano }.count == 2)
        try #require(events.allSatisfy { $0.releaseEndFrame < frameCount })
        // Overlapping voices, different normalizations/takes, stereo piano, note envelopes,
        // and the Python-compatible rounding boundary all pass through the production mixer.
        for warmth in [0, 0.785, 1] {
            let live = try TonalVoiceMixer(preparer: preparer, events: events, warmth: warmth)
            let baked = try TonalVoiceMixer(
                preparer: preparer, events: events, warmth: warmth, useLiveTonalSamples: false)
            #expect(live.preparedBytes == baked.preparedBytes)
            var rendered = 0
            var index = 0
            let partitions = [1, 17, 257, 4093]
            var a = [Float](repeating: 0, count: 2 * 4093)
            var b = a
            while rendered < frameCount {
                let count = min(partitions[index % partitions.count], frameCount - rendered)
                try a.withUnsafeMutableBufferPointer { output in
                    try #require(
                        live.render(
                            into: UnsafeMutableBufferPointer(rebasing: output[..<(2 * count)])))
                }
                try b.withUnsafeMutableBufferPointer { output in
                    try #require(
                        baked.render(
                            into: UnsafeMutableBufferPointer(rebasing: output[..<(2 * count)])))
                }
                let difference = (0..<(2 * count)).first { a[$0].bitPattern != b[$0].bitPattern }
                try #require(
                    difference == nil,
                    "Warmth \(warmth), first differing frame \(rendered + (difference ?? 0) / 2)")
                rendered += count
                index += 1
            }
        }
    }
}
