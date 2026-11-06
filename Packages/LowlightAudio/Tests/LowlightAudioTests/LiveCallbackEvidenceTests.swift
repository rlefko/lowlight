// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Darwin
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

let callbackEvidenceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct LiveCallbackEvidenceTests {
    private struct Fixture {
        let pair: PreparedSongPair
        let gains: [Double]
    }

    private struct Measurement: Encodable {
        let frames, measuredBlocks, requiredVoiceSlots, preparedPCMBytes: Int
        let gains: [Double]
        let stereoFloat32SHA256: String
        let wallNanoseconds, threadCPUNanoseconds: [UInt64]
    }

    /// Run the same Release fixture on both revisions and compare complete stereo output
    /// within each architecture. Timing encloses only render, with one preallocated buffer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOWLIGHT_CALLBACK_EVIDENCE"] != nil))
    func productionCallbackEvidence() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOWLIGHT_CALLBACK_EVIDENCE"])
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let build = callbackEvidenceRoot.appendingPathComponent(".build").resolvingSymlinksInPath()
        try #require(directory.path.hasPrefix(build.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bank = try TonalSamplePreparer(
            bankURL: callbackEvidenceRoot.appendingPathComponent("Lowlight/SoundBank"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for name in ["ordinary", "maximum-overlap"] {
            let recipe = try CallbackEvidenceRecipe.named(name, preparer: bank)
            var gains: [Double] = []
            let pair = try PreparedSongPair(frameCount: recipe.frameCount) { pool in
                let racks = try recipe.prepare(pool)
                gains = [racks.0.linearMultiplier, racks.1.linearMultiplier]
                return racks
            }
            if name == "maximum-overlap" { try #require(pair.requiredVoiceSlots == 64) }
            let fixture = Fixture(pair: pair, gains: gains)
            let result = try measure(fixture)
            try encoder.encode(result).write(
                to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        }
    }

    private func measure(_ fixture: Fixture) throws -> Measurement {
        let pair = fixture.pair
        var buffer = [Float](repeating: 0, count: 512)
        var wall: [UInt64] = []
        var cpu: [UInt64] = []
        var digest = SHA256()
        var maximum: Float = 0
        var frames = 0
        try buffer.withUnsafeMutableBufferPointer { block in
            while frames < pair.frameCount {
                let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let result = pair.render(into: block)
                let cpuDuration = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStarted
                let duration = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started
                let count = try #require(result)
                try #require(count == min(256, Int(pair.frameCount) - frames))
                // Keep launch warmup and the partial final block out of percentile samples.
                if frames >= 16_384 && count == 256 {
                    wall.append(duration)
                    cpu.append(cpuDuration)
                }
                let samples = UnsafeBufferPointer(rebasing: block[..<(count * 2)])
                digest.update(bufferPointer: UnsafeRawBufferPointer(samples))
                for sample in samples {
                    guard sample.isFinite else { throw EvidenceError.nonfinite }
                    maximum = max(maximum, abs(sample))
                }
                frames += count
            }
        }
        try #require(
            maximum > 0 && !pair.isFaulted && pair.stolenVoices == 0 && pair.droppedEvents == 0)
        return Measurement(
            frames: frames, measuredBlocks: wall.count, requiredVoiceSlots: pair.requiredVoiceSlots,
            preparedPCMBytes: pair.preparedPCMBytes, gains: fixture.gains,
            stereoFloat32SHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            wallNanoseconds: wall, threadCPUNanoseconds: cpu)
    }

    private enum EvidenceError: Error { case nonfinite }
}

struct CallbackEvidenceRecipe {
    let frameCount: UInt32
    let prepare: (SongPreparationPool) throws -> (PreparedSong, PreparedSong)

    static func named(_ name: String, preparer: TonalSamplePreparer) throws -> Self {
        switch name {
        case "ordinary": return try ordinary(preparer)
        case "maximum-overlap": return maximumOverlap(preparer)
        default: throw PreparedSongPairError.invalidPair
        }
    }

    /// A real seeded first selection and its complete outgoing overlap, including both
    /// song protectors, room, quiet air, and the shared session protection and fades.
    static func ordinary(_ preparer: TonalSamplePreparer) throws -> Self {
        var timeline = try SessionTimeline()
        let first = try timeline.next()
        let second = try timeline.next()
        let end = UInt32(try first.outgoing.ramp.frame(at: 16))
        return Self(frameCount: end) { pool in
            let left = try pool.prepare(schedule: first, preparer: preparer)
            let right = try pool.prepare(schedule: second, preparer: preparer)
            return (left, right)
        }
    }

    /// Sustain 32 tonal voices on each of two overlapping production racks. Their staggered
    /// onsets exercise both racks independently while keeping within the real admission bound.
    static func maximumOverlap(_ preparer: TonalSamplePreparer) -> Self {
        let frames: UInt32 = 32 * 32_000
        return Self(frameCount: frames) { pool in
            func rack(origin: UInt64) throws -> PreparedSong {
                var events: [NoteEvent] = []
                for second in 0..<32 {
                    for voice in 0..<32 {
                        let start = origin + UInt64(second * 32_000)
                        let record: [String: Any] = [
                            "formatVersion": 1,
                            "instrument": voice.isMultiple(of: 2) ? "piano" : "guitar",
                            "role": "chord", "articulation": "normal", "note": 60 + voice % 4,
                            "roundRobin": voice % 2, "beat": second, "velocity": 0.16,
                            "pan": Double(voice % 5 - 2) / 4,
                            "startFrame": start, "gateEndFrame": start + 31_500,
                            "releaseEndFrame": start + 32_000,
                        ]
                        events.append(
                            try JSONDecoder().decode(
                                NoteEvent.self, from: JSONSerialization.data(withJSONObject: record)
                            ))
                    }
                }
                let end = Double(origin + UInt64(frames))
                return try pool.prepare(
                    layout: SongRenderLayout(
                        frameOrigin: origin, inputFrames: frames, bodyFrames: 0..<32_000),
                    preparer: preparer, events: events, takeSeed: 308, focus: .guitar,
                    warmth: 0.78, energy: 0.35, space: 0.44, texture: 0.09,
                    rackFades: SongRackFades(
                        tonalOutStartFrame: end, tonalOutEndFrame: end + 1024,
                        rhythmInFrame: Double(origin), rhythmOutFrame: end))
            }
            let left = try rack(origin: 0)
            let right = try rack(origin: 256)
            return (left, right)
        }
    }
}
