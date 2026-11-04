// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

private final class SuspensionTokens: @unchecked Sendable {
    let gate = WorkerAnalysisGate()
    private var count = 0  // Only the worker creates successor tokens.

    func make() -> PreparationCancellation {
        count += 1
        return count == 1
            ? PreparationCancellation(analysisCheckpoint: { self.gate.observe($0) })
            : PreparationCancellation()
    }
}

private final class SuspensionFailure: @unchecked Sendable {
    enum Injected: Error { case preparation }
    let reached = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let origins: [UInt64] = [0, 16_017, 50_001]
    // Worker-owned, inspected after join.
    private var index = 0
    var calls: [Int] = []

    func make(_ preparer: TonalSamplePreparer, _ token: PreparationCancellation) throws
        -> PreparedSession
    {
        try PreparedSession(
            frameCount: 70_017, preparation: .concurrent, cancellation: token,
            accepted: { self.index += 1 },
            prepare: { pool, cancellation in
                self.calls.append(self.index)
                if self.calls == [0, 1, 2] {
                    self.reached.signal()
                    try #require(self.resume.wait(timeout: .now() + 30) == .success)
                    // A genuine failure must survive a simultaneous suspension request.
                    throw Injected.preparation
                }
                let song = try PreparedSongPairTests().make(
                    pool, preparer, origin: self.origins[self.index], cancellation: cancellation)
                return (song, self.index == 0 ? 16_017 : self.index == 1 ? 50_001 : 70_017)
            })
    }
}

struct SessionPreparationSuspensionTests {
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
            _ = sched_yield()  // Controller-only; no timed assertion about worker idleness.
        }
    }

    private func pull(_ endpoint: PreparedSession.RenderEndpoint, _ count: Int) throws -> [Float] {
        var output = [Float](repeating: .nan, count: count * 2)
        let written = try #require(
            output.withUnsafeMutableBufferPointer { endpoint.render(into: $0) })
        #expect(output.dropFirst(written * 2).allSatisfy { $0 == 0 })
        return Array(output.prefix(written * 2))
    }

    private func finish(_ endpoint: PreparedSession.RenderEndpoint) throws -> SessionConsumer {
        try SessionConsumer {
            let deadline = Date().addingTimeInterval(30)
            var output: [Float] = []
            let sizes = [1, 159, 160, 161, 257, 1023]
            var block = 0
            while endpoint.position < endpoint.frameCount {
                try #require(Date() < deadline)
                let next = try self.pull(endpoint, sizes[block % sizes.count])
                output += next
                if next.isEmpty { _ = sched_yield() }
                block += 1
            }
            #expect(!endpoint.isFaulted)
            return output
        }
    }

    @Test func cancelledAnalysisResumesTheSameSongWithExactAudioEvenBeforeAcknowledgement() throws {
        let preparer = try preparer()
        let expected = try ConcurrentSessionTests().independent(
            preparer, origins: [0, 16_017, 50_001, 60_018], count: 90_017)
        for earlyResume in [false, true] {
            let score = WorkerScore(preparer)
            let tokens = SuspensionTokens()
            let worker = try SessionPreparationWorker(
                makeCancellation: { tokens.make() }, prepare: { try score.make($0) })
            defer {
                tokens.gate.resume.signal()
                worker.requestStop()
                worker.join()
            }
            var joiners: [SessionConsumer] = []
            defer {
                worker.requestStop()
                for joiner in joiners { _ = try? joiner.join() }
            }
            let endpoint = try worker.makeRenderEndpoint()
            var actual = try pull(endpoint, 50_001)
            try #require(tokens.gate.reached.wait(timeout: .now() + 30) == .success)
            #expect(worker.suspend() && !worker.suspend())
            #expect(worker.status == .preparing && !worker.retry())
            if earlyResume {
                #expect(worker.resume() && !worker.resume())
                for _ in 0..<16 { #expect(worker.suspend() && worker.resume()) }
            }
            tokens.gate.resume.signal()
            if !earlyResume {
                try until { worker.status == .suspended }
                let position = endpoint.position
                #expect(worker.lastError == nil && !worker.retry())
                #expect(try pull(endpoint, 257).isEmpty && endpoint.position == position)
                #expect(score.snapshot().calls == [0, 1, 2])
                let joining = DispatchSemaphore(value: 0)
                for _ in 0..<2 {
                    joiners.append(
                        try SessionConsumer {
                            joining.signal()
                            worker.join()
                            return []
                        })
                }
                // Both callers have reached join; enrollment in its wait is not observable.
                for _ in joiners {
                    try #require(joining.wait(timeout: .now() + 30) == .success)
                }
                #expect(worker.resume() && !worker.resume())
            }
            let consumer = try finish(endpoint)
            defer { _ = try? consumer.join() }
            actual += try consumer.join()
            for joiner in joiners {
                try #require(joiner.finished.wait(timeout: .now() + 30) == .success)
                _ = try joiner.join()
            }
            worker.join()  // Finite EOF wakes the worker's ordinary service loop.
            #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(worker.status == .stopped && worker.lastError == nil)
            #expect(score.snapshot().calls == [0, 1, 2, 2, 3])
            #expect(score.tokens[2].isCancelled && score.tokens[2] !== score.tokens[3])
            #expect(tokens.gate.frames == [0, 256] && !tokens.gate.timedOut)
            #expect(score.maximumRacks == 2 && score.session?.droppedEvents == 0)
        }
    }

    @Test func genuineFailureRacingSuspensionStillRequiresExplicitRetry() throws {
        let preparer = try preparer()
        let score = SuspensionFailure()
        let expected = try ConcurrentSessionTests().independent(preparer, origins: score.origins)
        let worker = try SessionPreparationWorker { try score.make(preparer, $0) }
        defer {
            score.resume.signal()
            worker.requestStop()
            worker.join()
        }
        let endpoint = try worker.makeRenderEndpoint()
        var actual = try pull(endpoint, 50_001)
        try #require(score.reached.wait(timeout: .now() + 30) == .success)
        #expect(worker.suspend())
        score.resume.signal()
        try until { worker.status == .suspended }
        #expect(worker.lastError is SuspensionFailure.Injected && !worker.retry())
        #expect(worker.resume())
        try until { worker.status == .waitingForRetry }
        #expect(worker.lastError is SuspensionFailure.Injected)
        #expect(try pull(endpoint, 257).isEmpty)
        #expect(worker.suspend())
        try until { worker.status == .suspended }
        #expect(!worker.retry() && worker.resume())
        try until { worker.status == .waitingForRetry }
        #expect(worker.retry() && !worker.retry())
        let consumer = try finish(endpoint)
        defer { _ = try? consumer.join() }
        actual += try consumer.join()
        worker.join()
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(score.calls == [0, 1, 2, 2] && worker.lastError == nil)
    }

    @Test func idleSuspensionLeavesRenderingLiveAndTerminalStopReleasesAfterBothOwners() throws {
        let score = WorkerScore(try preparer())
        var worker: SessionPreparationWorker? = try SessionPreparationWorker { try score.make($0) }
        var endpoint: PreparedSession.RenderEndpoint?
        do {
            let owner = try #require(worker)
            defer {
                owner.requestStop()
                owner.join()
            }
            endpoint = try owner.makeRenderEndpoint()
            #expect(!owner.resume() && owner.suspend() && !owner.suspend())
            try until { owner.status == .suspended }
            let render = try #require(endpoint)
            #expect(try pull(render, 257).count == 514 && render.position == 257)
            #expect(owner.status == .suspended && score.snapshot().calls == [0, 1])
            #expect(owner.lastError == nil && !owner.retry())
            owner.requestStop()
            owner.join()
            #expect(
                owner.status == .stopped && !owner.suspend() && !owner.resume() && !owner.retry())
            #expect(throws: PreparationWorkerError.renderEndpointUnavailable) {
                try owner.makeRenderEndpoint()
            }
        }
        worker = nil
        #expect(score.session != nil && score.pool?.reservedRacks == 2)
        endpoint = nil
        #expect(score.session == nil && score.pool?.reservedRacks == 0)
    }
}
