// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Foundation
import Testing

@testable import LowlightAudio

private let cancellationRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// Only the preparing test thread accesses frames; the controller uses the two semaphores.
private final class AnalysisCancellationGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    var frames: [UInt32] = []

    func observe(_ frame: UInt32) {
        frames.append(frame)
        if frame >= 256 {
            reached.signal()
            #expect(resume.wait(timeout: .now() + 30) == .success)
        }
    }
}

struct PreparationCancellationTests {
    @Test func coldCancellationRejectsBeforeDecodingAndTheTokenIsMonotonic() throws {
        let token = PreparationCancellation()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index.isMultiple(of: 2) { token.cancel() }
            let observed = token.isCancelled
            #expect(!observed || token.isCancelled)
        }
        #expect(token.isCancelled)
        token.cancel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: cancellationRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: directory.appendingPathComponent(name))
        }
        let missing = try TonalSamplePreparer(bankURL: directory)
        let pool = SongPreparationPool()
        let schedule = try SessionPlanning().next()
        #expect(throws: CancellationError.self) {
            try PreparedSong(schedule: schedule, preparer: missing, cancellation: token)
        }
        #expect(throws: CancellationError.self) {
            try pool.prepare(schedule: schedule, preparer: missing, cancellation: token)
        }
        #expect(throws: CancellationError.self) {
            try PreparedSongPairTests().make(pool, missing, origin: 0, cancellation: token)
        }
        #expect(throws: CancellationError.self) {
            try PreparedSession(frameCount: 6_400_000, preparer: missing, cancellation: token)
        }
        #expect(
            pool.reservedRacks == 0 && pool.reservedVoiceSlots == 0 && pool.preparedPCMBytes == 0)
    }

    @Test func externalCancellationAfterRealAnalysisProgressRestoresTheCallerAndReleasesAdmission()
        throws
    {
        let preparer = try TonalSamplePreparer(
            bankURL: cancellationRoot.appendingPathComponent("Lowlight/SoundBank"))
        let pool = SongPreparationPool()
        let gate = AnalysisCancellationGate()
        let token = PreparationCancellation(analysisCheckpoint: gate.observe)
        let worker = pthread_mach_thread_np(pthread_self())
        let controller = DispatchGroup()
        controller.enter()
        DispatchQueue.global().async {
            defer { controller.leave() }
            #expect(gate.reached.wait(timeout: .now() + 30) == .success)
            #expect(pthread_mach_thread_np(pthread_self()) != worker)
            token.cancel()
            gate.resume.signal()
        }
        defer {
            gate.reached.signal()
            gate.resume.signal()
            _ = controller.wait(timeout: .now() + 30)
        }
        #expect(throws: CancellationError.self) {
            try PreparationModeTests().environment(2, ll_test_flush_modes() - 1, true) {
                try PreparedSongPairTests().make(pool, preparer, origin: 0, cancellation: token)
            }
        }
        #expect(controller.wait(timeout: .now() + 30) == .success)
        #expect(gate.frames == [0, 256] && token.isCancelled)
        #expect(
            pool.reservedRacks == 0 && pool.reservedVoiceSlots == 0 && pool.preparedPCMBytes == 0)
        let fresh = PreparationCancellation()
        let song = try PreparedSongPairTests().make(pool, preparer, origin: 0, cancellation: fresh)
        #expect(song.measurement.integratedLUFS != nil && !fresh.isCancelled)
    }

    @Test func cancellationAfterTheSecondInitialCandidateReleasesBothRacks() throws {
        let preparer = try TonalSamplePreparer(
            bankURL: cancellationRoot.appendingPathComponent("Lowlight/SoundBank"))
        for mode in [SessionPreparation.serialized, .concurrent] {
            let token = PreparationCancellation()
            var observed: SongPreparationPool?
            weak var first: PreparedSong?
            weak var second: PreparedSong?
            var accepted = 0
            #expect(throws: CancellationError.self) {
                try PreparedSession(
                    frameCount: 50_003, preparation: mode, cancellation: token,
                    accepted: { accepted += 1 },
                    prepare: { pool, cancellation in
                        observed = pool
                        let song = try PreparedSongPairTests().make(
                            pool, preparer, origin: accepted == 0 ? 0 : 16_017,
                            cancellation: cancellation)
                        if accepted == 0 {
                            first = song
                        } else {
                            second = song
                            token.cancel()
                        }
                        return (song, accepted == 0 ? 16_017 : 50_003)
                    })
            }
            #expect(accepted == 1 && first == nil && second == nil)
            #expect(observed?.reservedRacks == 0 && observed?.reservedVoiceSlots == 0)
            #expect(observed?.preparedPCMBytes == 0)
        }
    }

    @Test func cancelledSuccessorNeverPublishesAndFreshAttemptsRetryTheSameScore() throws {
        let preparer = try TonalSamplePreparer(
            bankURL: cancellationRoot.appendingPathComponent("Lowlight/SoundBank"))
        let origins: [UInt64] = [0, 16_017, 50_001]
        let expected = try ConcurrentSessionTests().independent(preparer, origins: origins)
        for mode in [SessionPreparation.serialized, .concurrent] {
            let initial = PreparationCancellation()
            let cancelled = PreparationCancellation()
            var observed: SongPreparationPool?
            weak var rejected: PreparedSong?
            var index = 0
            var attempts: [Int] = []
            let session = try PreparedSession(
                frameCount: 70_017, preparation: mode, cancellation: initial,
                accepted: { index += 1 },
                prepare: { pool, cancellation in
                    observed = pool
                    attempts.append(index)
                    let song = try PreparedSongPairTests().make(
                        pool, preparer, origin: origins[index], cancellation: cancellation)
                    if index == 2 && cancellation === cancelled {
                        rejected = song
                        cancelled.cancel()
                    }
                    return (song, index == 0 ? 16_017 : index == 1 ? 50_001 : 70_017)
                })
            initial.cancel()  // An accepted session does not retain this attempt's cancellation.
            let endpoint = mode == .concurrent ? try session.makeRenderEndpoint() : nil
            func render(_ buffer: UnsafeMutableBufferPointer<Float>) -> Int? {
                if let endpoint { return endpoint.render(into: buffer) }
                return session.render(into: buffer)
            }
            var output: [Float] = []
            var scratch = [Float](repeating: .nan, count: 70_017 * 2)
            let before = try #require(scratch.withUnsafeMutableBufferPointer { render($0) })
            output.append(contentsOf: scratch.prefix(before * 2))
            #expect(session.needsPreparation && observed?.reservedRacks == 2)
            let position = session.position
            #expect(throws: CancellationError.self) {
                try session.prepareNext(cancellation: cancelled)
            }
            #expect(rejected == nil && index == 2 && attempts == [0, 1, 2])
            #expect(observed?.reservedRacks == 1 && observed?.reservedVoiceSlots == 1)
            #expect(session.position == position && session.needsPreparation && !session.isFaulted)
            #expect(scratch.withUnsafeMutableBufferPointer { render($0) } == 0)
            #expect(scratch.allSatisfy { $0 == 0 })
            #expect(throws: CancellationError.self) {
                try session.prepareNext(cancellation: cancelled)
            }
            #expect(attempts == [0, 1, 2])
            let retry = PreparationCancellation()
            try session.prepareNext(cancellation: retry)
            retry.cancel()  // Cancellation after successful publication cannot revoke that song.
            let after = try #require(scratch.withUnsafeMutableBufferPointer { render($0) })
            output.append(contentsOf: scratch.prefix(after * 2))
            #expect(index == 3 && attempts == [0, 1, 2, 2] && observed?.reservedRacks == 2)
            #expect(session.position == 70_017 && !session.needsPreparation && !session.isFaulted)
            #expect(output.map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(session.stolenVoices == 0 && session.droppedEvents == 0)
        }
    }
}
