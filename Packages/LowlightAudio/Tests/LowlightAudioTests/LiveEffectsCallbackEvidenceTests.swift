// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import LowlightAudio

struct LiveEffectsCallbackEvidenceTests {
    private enum Mode: String, CaseIterable { case unseeded, seeded, changes }
    private static let block = 256
    private static let initial = LLEffectValues(warmth: 0.78, space: 0.44, texture: 0.09)
    private static let other = LLEffectValues(warmth: 0.04, space: 1, texture: 1)

    /// Derive the same timing buckets on all three passes. The settled tail (>= 8,192
    /// frames) also allows the last submitted target to cross the returned-output clock.
    private struct Pattern {
        var lastEdit: Int?
        var revision: UInt64 = 1

        mutating func next(frame: Int, total: Int) -> (bucket: String, send: Bool) {
            let block = frame / LiveEffectsCallbackEvidenceTests.block
            let phase = (block - 64) % 128
            let elapsed = lastEdit.map { frame - $0 } ?? Int.max
            let settle = 6400 + 2 * Int(LL_PEAK_LATENCY) + Int(LL_GLUE_LATENCY)
            let edit =
                block >= 64 && frame < total - 8192 && phase < 65
                && [0, 1, 4].contains(phase % 8)
            if edit {
                lastEdit = frame
                revision += 1
                if elapsed >= settle { return ("adopt-after-settled", true) }
                // At least 559 intervening frames materializes the complete delay history.
                let full = elapsed >= Int(LL_PEAK_LATENCY) + Int(LL_GLUE_LATENCY)
                return (full ? "adopt-full-history" : "adopt-short-history", true)
            }
            return (elapsed >= settle ? "settled" : "ramping", false)
        }
    }

    private struct Samples: Encodable {
        var frames: [Int] = []
        var wallNanoseconds: [UInt64] = []
        var threadCPUNanoseconds: [UInt64] = []

        mutating func add(frame: Int, wall: UInt64, cpu: UInt64) {
            frames.append(frame)
            wallNanoseconds.append(wall)
            threadCPUNanoseconds.append(cpu)
        }
    }

    private struct Measurement: Encodable {
        let frames, requiredVoiceSlots, preparedPCMBytes: Int
        let gains: [Double]
        let stereoFloat32SHA256: String
        let finalRevision: UInt64
        let buckets: [String: Samples]
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["LOWLIGHT_EFFECT_CALLBACK_EVIDENCE"] != nil))
    func placedTransportCallbackEvidence() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(env["LOWLIGHT_EFFECT_CALLBACK_EVIDENCE"]))
            .resolvingSymlinksInPath().standardizedFileURL
        let build = callbackEvidenceRoot.appendingPathComponent(".build").resolvingSymlinksInPath()
        try #require(directory.path.hasPrefix(build.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let order = try #require(Int(env["LOWLIGHT_EFFECT_CALLBACK_ROTATION"] ?? "0"))
        try #require((0..<Mode.allCases.count).contains(order))
        let bank = try TonalSamplePreparer(
            bankURL: callbackEvidenceRoot.appendingPathComponent("Lowlight/SoundBank"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for name in ["ordinary", "maximum-overlap"] {
            let pool = SongPreparationPool()
            let recipe = try CallbackEvidenceRecipe.named(name, preparer: bank)
            let racks = try recipe.prepare(pool)
            try #require(pool.reservedRacks == 2)
            if name == "maximum-overlap" { try #require(pool.reservedVoiceSlots == 64) }
            var hashes: [Mode: String] = [:]
            for offset in Mode.allCases.indices {
                let mode = Mode.allCases[(offset + order) % Mode.allCases.count]
                // The previous borrower has been destroyed before resetting either child.
                racks.0.reset()
                racks.1.reset()
                let result = try measure(
                    racks, pool: pool, limit: Int(recipe.frameCount), mode: mode)
                hashes[mode] = result.stereoFloat32SHA256
                try encoder.encode(result).write(
                    to: directory.appendingPathComponent("\(name)-\(mode.rawValue).json"),
                    options: .atomic)
            }
            try #require(
                hashes[.unseeded] == hashes[.seeded] && hashes[.changes] != hashes[.seeded])
        }
    }

    private func measure(
        _ racks: (PreparedSong, PreparedSong), pool: SongPreparationPool, limit: Int, mode: Mode
    ) throws -> Measurement {
        let next = UInt64(racks.0.layout.inputFrames)
        let frames = min(limit, Int(next) - Self.block) / Self.block * Self.block
        let pair = try #require(
            ll_song_pair_create_transport(
                racks.0.borrowedHandle, racks.1.borrowedHandle, racks.1.layout.frameOrigin, 0, next)
        )
        defer { withExtendedLifetime(racks) { ll_song_pair_destroy(pair) } }
        if mode != .unseeded { try #require(ll_song_pair_seed_effects(pair, Self.initial, 78)) }
        var scratch = [Float](repeating: 0, count: Self.block * 2)
        var buckets: [String: Samples] = [:]
        var schedule = Pattern()
        var digest = SHA256()
        var maximum: Float = 0
        try scratch.withUnsafeMutableBufferPointer { block in
            for frame in stride(from: 0, to: frames, by: Self.block) {
                let scheduled = schedule.next(frame: frame, total: frames)
                if mode == .changes && scheduled.send {
                    let changed = schedule.revision.isMultiple(of: 2)
                    try #require(
                        ll_song_pair_send_effects(
                            pair, changed ? Self.other : Self.initial, changed ? 4 : 78,
                            schedule.revision))
                }
                var written: UInt32 = 0
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let success = ll_song_pair_render(
                    pair, block.baseAddress, UInt32(Self.block), &written)
                let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
                let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
                try #require(success && written == UInt32(Self.block))
                if frame >= 16_384 {
                    buckets[scheduled.bucket, default: Samples()].add(
                        frame: frame, wall: wall, cpu: cpu)
                }
                if mode == .changes && (scheduled.send || scheduled.bucket == "settled") {
                    let status = ll_song_pair_effect_progress(pair)
                    try #require(status.adopted_revision == schedule.revision)
                    if scheduled.send {
                        try #require(status.settled_revision < schedule.revision)
                    } else {
                        try #require(status.settled_revision == schedule.revision)
                    }
                }
                digest.update(bufferPointer: UnsafeRawBufferPointer(block))
                for sample in block {
                    guard sample.isFinite else { throw PreparedSongPairError.preparationFailed }
                    maximum = max(maximum, abs(sample))
                }
            }
        }
        let revision = mode == .changes ? schedule.revision : (mode == .seeded ? 1 : 0)
        let progress = ll_song_pair_effect_progress(pair)
        try #require(progress.adopted_revision == revision && progress.settled_revision == revision)
        try #require(maximum > 0 && !ll_song_pair_faulted(pair) && buckets.count == 5)
        try #require(
            racks.0.stolenVoices + racks.1.stolenVoices + racks.0.droppedEvents
                + racks.1.droppedEvents == 0)
        return Measurement(
            frames: frames, requiredVoiceSlots: pool.reservedVoiceSlots,
            preparedPCMBytes: pool.preparedPCMBytes,
            gains: [racks.0.linearMultiplier, racks.1.linearMultiplier],
            stereoFloat32SHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            finalRevision: revision, buckets: buckets)
    }
}
