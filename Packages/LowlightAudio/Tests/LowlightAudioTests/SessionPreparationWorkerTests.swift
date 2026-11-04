// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

final class WorkerAnalysisGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    // Only the preparation worker accesses these fields, read after it has joined.
    var frames: [UInt32] = []
    var timedOut = false

    func observe(_ frame: UInt32) {
        frames.append(frame)
        if frame == 256 {
            reached.signal()
            timedOut = resume.wait(timeout: .now() + 30) != .success
        }
    }
}

final class WorkerScore: @unchecked Sendable {
    enum Injected: Error { case successor }
    let preparer: TonalSamplePreparer
    let origins: [UInt64] = [0, 16_017, 50_001, 60_018]
    let retryEntered = DispatchSemaphore(value: 0)
    let retryResume = DispatchSemaphore(value: 0)
    let failOnce: Bool
    private let lock = NSLock()
    private var calls: [Int] = []
    private var threads: Set<UInt32> = []
    // The remaining fields are worker-owned, inspected only after joining it.
    private var index = 0
    var pool: SongPreparationPool?
    weak var session: PreparedSession?
    var tokens: [PreparationCancellation] = []
    var maximumRacks = 0

    init(_ preparer: TonalSamplePreparer, failOnce: Bool = false) {
        self.preparer = preparer
        self.failOnce = failOnce
    }

    func snapshot() -> (calls: [Int], threads: Set<UInt32>) {
        lock.lock()
        defer { lock.unlock() }
        return (calls, threads)
    }

    func make(_ token: PreparationCancellation) throws -> PreparedSession {
        let value = try PreparedSession(
            frameCount: 90_017, preparation: .concurrent, cancellation: token,
            accepted: { self.index += 1 },
            prepare: { shared, cancellation in
                let current = self.index
                try #require(current < self.origins.count)
                self.lock.lock()
                self.calls.append(current)
                self.threads.insert(pthread_mach_thread_np(pthread_self()))
                let attempt = self.calls.filter { $0 == current }.count
                self.lock.unlock()
                if let cancellation { self.tokens.append(cancellation) }
                if self.failOnce && current == 2 && attempt == 2 {
                    self.retryEntered.signal()
                    try #require(self.retryResume.wait(timeout: .now() + 30) == .success)
                }
                self.pool = shared
                let child = try PreparedSongPairTests().make(
                    shared, self.preparer, origin: self.origins[current], cancellation: cancellation
                )
                self.maximumRacks = max(self.maximumRacks, shared.reservedRacks)
                if self.failOnce && current == 2 && attempt == 1 { throw Injected.successor }
                return (
                    child,
                    current + 1 < self.origins.count
                        ? UInt32(self.origins[current + 1]) : 90_017
                )
            })
        session = value
        return value
    }
}

struct SessionPreparationWorkerTests {
    private func preparer() throws -> TonalSamplePreparer {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try TonalSamplePreparer(bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func until(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try #require(Date() < deadline)
            _ = sched_yield()
        }
    }

    private func consume(_ endpoint: PreparedSession.RenderEndpoint) throws -> SessionConsumer {
        try SessionConsumer {
            let deadline = Date().addingTimeInterval(30)
            var result: [Float] = []
            var block = 0
            let sizes = [1, 159, 160, 161, 257, 1023]
            while endpoint.position < endpoint.frameCount {
                try #require(Date() < deadline)
                var output = [Float](repeating: .nan, count: 2 * sizes[block % sizes.count])
                let count = try #require(
                    output.withUnsafeMutableBufferPointer { endpoint.render(into: $0) })
                #expect(output.dropFirst(count * 2).allSatisfy { $0 == 0 })
                result.append(contentsOf: output.prefix(count * 2))
                if count == 0 { _ = sched_yield() }
                block += 1
            }
            #expect(!endpoint.isFaulted)
            return result
        }
    }

    @Test func automaticWorkerPreservesFourSongsAndStopsAtFiniteEOF() throws {
        let score = WorkerScore(try preparer())
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: 90_017)
        var worker: SessionPreparationWorker? = try SessionPreparationWorker { try score.make($0) }
        defer {
            worker?.requestStop()
            worker?.join()
        }
        do {
            let owner = try #require(worker)
            let endpoint = try owner.makeRenderEndpoint()
            #expect(throws: PreparationWorkerError.renderEndpointUnavailable) {
                try owner.makeRenderEndpoint()
            }
            let consumer = try consume(endpoint)
            defer { _ = try? consumer.join() }
            #expect(try consumer.join().map(\.bitPattern) == expected.map(\.bitPattern))
            try until { owner.status == .stopped }
            owner.join()
            #expect(owner.lastError == nil && !owner.retry())
            #expect(score.snapshot().calls == [0, 1, 2, 3])
            #expect(score.snapshot().threads.count == 1)
            #expect(!score.snapshot().threads.contains(pthread_mach_thread_np(pthread_self())))
            #expect(score.maximumRacks == 2 && score.pool?.reservedRacks == 2)
            #expect(score.session?.stolenVoices == 0 && score.session?.droppedEvents == 0)
        }
        worker = nil
        #expect(score.session == nil && score.pool?.reservedRacks == 0)
    }

    @Test func failedSuccessorLatchesUntilOneExplicitFreshRetry() throws {
        let score = WorkerScore(try preparer(), failOnce: true)
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: 90_017)
        let worker = try SessionPreparationWorker { try score.make($0) }
        defer {
            score.retryResume.signal()
            worker.requestStop()
            worker.join()
        }
        let endpoint = try worker.makeRenderEndpoint()
        #expect(!worker.retry())
        let consumer = try consume(endpoint)
        defer { _ = try? consumer.join() }
        try until { worker.status == .waitingForRetry }
        #expect(worker.lastError is WorkerScore.Injected)
        #expect(score.snapshot().calls == [0, 1, 2])
        #expect(worker.retry())
        try #require(score.retryEntered.wait(timeout: .now() + 30) == .success)
        #expect(!worker.retry())
        score.retryResume.signal()
        #expect(try consumer.join().map(\.bitPattern) == expected.map(\.bitPattern))
        try until { worker.status == .stopped }
        worker.join()
        #expect(score.snapshot().calls == [0, 1, 2, 2, 3])
        #expect(score.tokens[2] !== score.tokens[3])
        #expect(score.maximumRacks == 2 && score.session?.droppedEvents == 0)
    }

    @Test func stopCancelsRealSuccessorAnalysisAndEndpointRetainsTheSurvivor() throws {
        let score = WorkerScore(try preparer())
        let gate = WorkerAnalysisGate()
        var worker: SessionPreparationWorker? = try SessionPreparationWorker(
            makeCancellation: {
                PreparationCancellation(analysisCheckpoint: { frame in gate.observe(frame) })
            }, prepare: { try score.make($0) })
        defer {
            gate.resume.signal()
            worker?.requestStop()
            worker?.join()
        }
        var endpoint: PreparedSession.RenderEndpoint? = try worker?.makeRenderEndpoint()
        do {
            let render = try #require(endpoint)
            let consumer = try SessionConsumer {
                var output = [Float](repeating: .nan, count: 2 * 50_001)
                let count = try #require(
                    output.withUnsafeMutableBufferPointer { render.render(into: $0) })
                #expect(count >= 40_001 - 160 && !render.isFaulted)
                return []
            }
            defer { _ = try? consumer.join() }
            _ = try consumer.join()
        }
        try #require(gate.reached.wait(timeout: .now() + 30) == .success)
        worker?.requestStop()
        worker?.requestStop()
        gate.resume.signal()
        worker?.join()
        #expect(worker?.status == .stopped && worker?.retry() == false)
        #expect(gate.frames == [0, 256] && !gate.timedOut)
        #expect(score.snapshot().calls == [0, 1, 2] && score.pool?.reservedRacks == 1)
        worker = nil
        #expect(score.session != nil && score.pool?.reservedRacks == 1)
        endpoint = nil  // Both roles are quiescent; final release is off the callback.
        #expect(score.session == nil && score.pool?.reservedRacks == 0)
    }

    @Test func startupCancellationAndIdleStopAreTerminal() throws {
        let score = WorkerScore(try preparer())
        let cancelled = PreparationCancellation()
        cancelled.cancel()
        #expect(throws: CancellationError.self) {
            try SessionPreparationWorker(cancellation: cancelled) { try score.make($0) }
        }
        #expect(score.snapshot().calls.isEmpty && score.pool == nil)
        let gate = WorkerAnalysisGate()
        let token = PreparationCancellation(analysisCheckpoint: { @Sendable frame in
            gate.observe(frame)
        })
        let ready = DispatchSemaphore(value: 0)
        let controller = try SessionConsumer {
            ready.signal()
            try #require(gate.reached.wait(timeout: .now() + 30) == .success)
            token.cancel()
            gate.resume.signal()
            return []
        }
        defer {
            gate.reached.signal()
            gate.resume.signal()
            _ = try? controller.join()
        }
        try #require(ready.wait(timeout: .now() + 30) == .success)
        #expect(throws: CancellationError.self) {
            try SessionPreparationWorker(cancellation: token) { try score.make($0) }
        }
        _ = try controller.join()
        #expect(gate.frames == [0, 256] && !gate.timedOut && score.pool?.reservedRacks == 0)
        let completed = WorkerScore(score.preparer)
        #expect(throws: CancellationError.self) {
            try SessionPreparationWorker { token in
                let session = try completed.make(token)
                token.cancel()
                return session
            }
        }
        #expect(completed.snapshot().calls == [0, 1])
        #expect(completed.session == nil && completed.pool?.reservedRacks == 0)
        let idle = WorkerScore(score.preparer)
        var worker: SessionPreparationWorker? = try SessionPreparationWorker { try idle.make($0) }
        do {
            let owner = try #require(worker)
            let joining = DispatchSemaphore(value: 0)
            let first = try SessionConsumer {
                joining.signal()
                owner.join()
                return []
            }
            defer {
                owner.requestStop()
                _ = try? first.join()
            }
            let second = try SessionConsumer {
                joining.signal()
                owner.join()
                return []
            }
            defer {
                owner.requestStop()
                _ = try? second.join()
            }
            for _ in 0..<2 {
                try #require(joining.wait(timeout: .now() + 30) == .success)
            }
            owner.requestStop()
            _ = try first.join()
            _ = try second.join()
        }
        #expect(worker?.status == .stopped && worker?.retry() == false)
        #expect(throws: PreparationWorkerError.renderEndpointUnavailable) {
            try worker?.makeRenderEndpoint()
        }
        #expect(idle.snapshot().calls == [0, 1])
        worker = nil
        #expect(idle.pool?.reservedRacks == 0 && idle.session == nil)
    }
}
