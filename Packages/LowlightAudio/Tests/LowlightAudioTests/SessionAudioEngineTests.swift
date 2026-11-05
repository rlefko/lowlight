// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

private final class EngineProbe {
    let engine = AVAudioEngine()
    private let buffer: AVAudioPCMBuffer

    init(rate: Double = 32_000) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    }

    var sourceNode: AVAudioSourceNode? {
        autoreleasepool {
            engine.attachedNodes.compactMap { $0 as? AVAudioSourceNode }.first
        }
    }

    func pull(_ count: Int) throws -> [Float] {
        let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
        try #require(status == .success && buffer.frameLength == count)
        let channels = try #require(buffer.floatChannelData)
        return (0..<count).flatMap { [channels[0][$0], channels[1][$0]] }
    }
}

struct SessionAudioEngineTests {
    private enum Injected: Error, Equatable { case start }

    private func until(_ condition: () -> Bool) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            _ = sched_yield()
        }
    }

    @Test func ownedGraphConvertsToDeviceRatesWithFiniteOutputAndDrainedTail() throws {
        for rate in [44_100.0, 48_000.0] {
            let score = try SourceTestScore(frames: 51_200)
            let graph = try EngineProbe(rate: rate)
            let owner = try SessionAudioEngine(worker: score.makeWorker(), engine: graph.engine)
            defer { owner.stop() }
            try owner.play()
            let frames = Int(score.frames) * Int(rate) / 32_000
            var output: [Float] = []
            while output.count / 2 < frames {
                output += try graph.pull(min(1023, frames - output.count / 2))
            }
            #expect(output.allSatisfy(\.isFinite) && output.contains { abs($0) > 0.001 })
            #expect(graph.engine.manualRenderingSampleTime == Int64(frames))
            let tail = try graph.pull(4096)
            #expect(tail.allSatisfy(\.isFinite) && tail.suffix(2048).allSatisfy { $0 == 0 })
            #expect(owner.position == score.frames && owner.sourceStatus == .finished)
            #expect(owner.playbackError == nil && owner.preparationError == nil)
        }
    }

    @Test func ownedGraphPreservesExactAudioAcrossPausesAndLeavesEOFExplicit() throws {
        let score = try SourceTestScore()
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: Int(score.frames))
        let graph = try EngineProbe()
        let owner = try SessionAudioEngine(worker: score.makeWorker(), engine: graph.engine)
        defer { owner.stop() }
        #expect(owner.state == .paused && !graph.engine.isRunning)
        #expect(owner.frameCount == score.frames && owner.position == 0)
        #expect(owner.sourceStatus == .ready && owner.playbackError == nil)
        try owner.play()
        try owner.play()
        #expect(owner.state == .playing && graph.engine.isRunning)
        var actual: [Float] = []
        let sizes = [1, 159, 160, 161, 257, 1023, 4096]
        var block = 0
        while actual.count / 2 < score.frames {
            actual += try graph.pull(
                min(sizes[block % sizes.count], Int(score.frames) - actual.count / 2))
            #expect(owner.position == actual.count / 2)
            block += 1
            if block == 3 || block == 12 {
                let deviceFrame = graph.engine.manualRenderingSampleTime
                owner.pause()
                owner.pause()
                try until { owner.preparationStatus == .suspended }
                #expect(owner.state == .paused && !graph.engine.isRunning)
                #expect(owner.position == actual.count / 2 && !owner.retryPreparation())
                #expect(owner.preparationError == nil && owner.playbackError == nil)
                try owner.play()
                try owner.play()
                #expect(
                    owner.state == .playing && graph.engine.manualRenderingSampleTime == deviceFrame
                )
            }
        }
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(owner.position == score.frames && owner.sourceStatus == .finished)
        #expect(owner.state == .playing && graph.engine.isRunning)
        #expect(try graph.pull(257).allSatisfy { $0 == 0 })
        owner.stop()
        owner.stop()
        owner.pause()
        #expect(owner.state == .stopped && !graph.engine.isRunning)
        #expect(owner.position == score.frames && owner.sourceStatus == .finished)
        #expect(owner.preparationStatus == .stopped && !owner.retryPreparation())
        #expect(owner.preparationError == nil && owner.playbackError == nil)
        #expect(throws: SessionAudioEngineError.stopped) { try owner.play() }
        #expect(score.pool?.reservedRacks == 0 && score.session == nil && score.worker == nil)
    }

    @Test func stopAndDeinitReleaseTheGraphAndBothOwnersFromEveryControlState() throws {
        for phase in 0..<3 {
            for explicitStop in [false, true] {
                let score = try SourceTestScore()
                let graph = try EngineProbe()
                weak var node: AVAudioSourceNode?
                weak var lifetime: SessionAudioEngine?
                try autoreleasepool {
                    var owner: SessionAudioEngine? = try SessionAudioEngine(
                        worker: score.makeWorker(), engine: graph.engine)
                    lifetime = owner
                    node = graph.sourceNode
                    #expect(node != nil && score.pool?.reservedRacks == 2)
                    if phase > 0 {
                        try owner?.play()
                        #expect(try graph.pull(257).contains { $0 != 0 })
                    }
                    if phase == 2 {
                        owner?.pause()
                        try until { owner?.preparationStatus == .suspended }
                    }
                    if explicitStop {
                        owner?.stop()
                        owner?.stop()
                        #expect(
                            owner?.state == .stopped && owner?.position == (phase == 0 ? 0 : 257))
                        #expect(owner?.preparationStatus == .stopped && graph.sourceNode == nil)
                    }
                    owner = nil
                }
                #expect(lifetime == nil && node == nil && !graph.engine.isRunning)
                #expect(graph.sourceNode == nil && score.worker == nil && score.session == nil)
                #expect(score.pool?.reservedRacks == 0 && score.pool?.preparedPCMBytes == 0)
            }
        }
    }

    @Test func startFailuresBeforeAndAfterActualEngineStartAreTerminalAndReleaseResources() throws {
        for resumeFailure in [false, true] {
            let score = try SourceTestScore()
            let graph = try EngineProbe()
            var starts = 0
            let owner = try SessionAudioEngine(
                worker: score.makeWorker(), engine: graph.engine,
                start: { engine in
                    starts += 1
                    if resumeFailure { try engine.start() }
                    if resumeFailure && starts == 2 { _ = try graph.pull(113) }
                    if !resumeFailure || starts == 2 { throw Injected.start }
                })
            defer { owner.stop() }
            weak let node = graph.sourceNode
            if resumeFailure {
                try owner.play()
                _ = try graph.pull(257)
                owner.pause()
                try until { owner.preparationStatus == .suspended }
            }
            let position = owner.position
            #expect(throws: Injected.start) { try owner.play() }
            #expect(owner.state == .stopped && !graph.engine.isRunning)
            #expect(owner.position == position + (resumeFailure ? 113 : 0))
            #expect(owner.playbackError as? Injected == .start)
            #expect(owner.preparationStatus == .stopped && !owner.retryPreparation())
            #expect(throws: SessionAudioEngineError.stopped) { try owner.play() }
            #expect(starts == (resumeFailure ? 2 : 1))
            owner.stop()
            #expect(node == nil && graph.sourceNode == nil)
            #expect(score.worker == nil && score.session == nil && score.pool?.reservedRacks == 0)
        }
    }

    @Test func endpointClaimFailureStopsTheWorkerWithoutLeavingAnAttachedNode() throws {
        let score = try SourceTestScore()
        let graph = try EngineProbe()
        try autoreleasepool {
            let worker = try score.makeWorker()
            _ = try worker.makeRenderEndpoint()
            #expect(throws: PreparationWorkerError.renderEndpointUnavailable) {
                try SessionAudioEngine(worker: worker, engine: graph.engine)
            }
            #expect(worker.status == .stopped && graph.sourceNode == nil && !graph.engine.isRunning)
        }
        #expect(score.worker == nil && score.session == nil && score.pool?.reservedRacks == 0)
    }

    @Test func preparationFailuresRemainObservableAcrossPauseRetryAndTerminalStop() throws {
        let fixture = try SourceTestScore()
        let origins: [UInt64] = [0, 16_017, 50_001, 60_018]
        let expected = try ConcurrentSessionTests().independent(
            fixture.preparer, origins: origins, count: 90_017)
        for retry in [false, true] {
            let score = WorkerScore(fixture.preparer, failOnce: true)
            let graph = try EngineProbe()
            let worker = try SessionPreparationWorker { try score.make($0) }
            let owner = try SessionAudioEngine(worker: worker, engine: graph.engine)
            defer {
                score.retryResume.signal()
                owner.stop()
            }
            var actual: [Float] = []
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            func pullLogical() throws {
                try #require(ContinuousClock.now < deadline)
                let before = owner.position
                let output = try graph.pull(1023)
                let written = Int(owner.position - before)
                actual += output.prefix(written * 2)
                #expect(output.dropFirst(written * 2).allSatisfy { $0 == 0 })
                if written == 0 { _ = sched_yield() }
            }
            try owner.play()
            while owner.preparationStatus != .waitingForRetry { try pullLogical() }
            #expect(owner.preparationError is WorkerScore.Injected && owner.playbackError == nil)
            owner.pause()
            try until { owner.preparationStatus == .suspended }
            #expect(!owner.retryPreparation() && owner.preparationError is WorkerScore.Injected)
            if retry {
                try owner.play()
                score.retryResume.signal()
                #expect(owner.retryPreparation())
                while owner.position < owner.frameCount { try pullLogical() }
                #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
                #expect(owner.sourceStatus == .finished && owner.preparationError == nil)
            }
            let position = owner.position
            owner.stop()
            #expect(owner.position == position && owner.state == .stopped)
            #expect(owner.preparationStatus == .stopped && !owner.retryPreparation())
            #expect((owner.preparationError is WorkerScore.Injected) == !retry)
            #expect(score.snapshot().calls == (retry ? [0, 1, 2, 2, 3] : [0, 1, 2]))
        }
    }
}
