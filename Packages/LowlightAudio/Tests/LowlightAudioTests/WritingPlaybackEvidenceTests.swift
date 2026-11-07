// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

/// Host measurements around production 256-frame pulls. Nothing is recorded on a device callback.
struct WritingPlaybackEvidenceTests {
    private struct Measurement: Encodable {
        let edition: Int
        let firstPairSeconds: Double
        let successorSeconds: [Double]
        let maxPoolBytes, maxVoiceSlots, timedBlocks: Int
        let wallP99Microseconds, wallP999Microseconds, meanThreadCPUMicroseconds: Double
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOWLIGHT_WRITING_TIMING"] != nil))
    func measureWriting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = try #require(ProcessInfo.processInfo.environment["LOWLIGHT_WRITING_TIMING"])
        let out = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        try #require(
            out.path.hasPrefix(
                root.appendingPathComponent(".build").resolvingSymlinksInPath().path + "/"))
        var records: [Measurement] = []
        // Alternate order to spread warm caches and scheduling load across both versions.
        for edition: CompositionEdition in [
            .classic, .evolving, .evolving, .classic, .classic, .evolving,
        ] {
            let bank = try TonalSamplePreparer(
                bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
            records.append(try measure(edition, bank: bank))
        }
        try JSONEncoder().encode(records).write(to: out, options: .withoutOverwriting)
    }

    private func measure(_ edition: CompositionEdition, bank: TonalSamplePreparer) throws
        -> Measurement
    {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let session = try PreparedSession(
            seed: 91_031, controls: .preset(.focus), edition: edition, preparer: bank)
        let endpoint = try session.makeRenderEndpoint()
        let first = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
        var wall: [UInt64] = []
        var preparations: [Double] = []
        var cpu: UInt64 = 0
        var samples = [Float](repeating: 0, count: 512)
        var highPCM = session.preparedPCMBytes
        var highVoices = session.requiredVoiceSlots
        let total: UInt64 = 600 * 32_000
        try samples.withUnsafeMutableBufferPointer { block in
            while endpoint.position < total {
                if session.needsPreparation {
                    let begin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    try session.prepareNext()
                    preparations.append(
                        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - begin) / 1e9)
                    highPCM = max(highPCM, session.preparedPCMBytes)
                    highVoices = max(highVoices, session.requiredVoiceSlots)
                }
                let clock = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let thread = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let result = endpoint.render(into: block)
                let used = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - thread
                let duration = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - clock
                try #require(result == 256)
                if endpoint.position > 16_384 {
                    wall.append(duration)
                    cpu += used
                }
            }
        }
        try #require(!session.isFaulted && endpoint.position == total)
        try #require(
            session.stolenVoices == 0 && session.droppedEvents == 0 && !preparations.isEmpty)
        wall.sort()
        func percentile(_ q: Double) -> Double {
            Double(wall[Int(ceil(Double(wall.count) * q)) - 1]) / 1000
        }
        return Measurement(
            edition: edition.rawValue, firstPairSeconds: first, successorSeconds: preparations,
            maxPoolBytes: highPCM, maxVoiceSlots: highVoices, timedBlocks: wall.count,
            wallP99Microseconds: percentile(0.99), wallP999Microseconds: percentile(0.999),
            meanThreadCPUMicroseconds: Double(cpu) / Double(wall.count) / 1000)
    }
}
