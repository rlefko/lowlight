// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

private final class PlaybackRelease {
    let finish: () -> Void
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    deinit { finish() }
}

@MainActor
private final class PlaybackHandle {
    var value: SessionPlayback?
    init(_ value: SessionPlayback) { self.value = value }
}

private final class PlaybackProbe: @unchecked Sendable {
    enum Injected: Error, Equatable { case factory, start, graph, gate }
    enum Gate { case none, beforeOwner, afterOwner }
    struct Counts {
        var calls = 0, active = 0, maximum = 0, starts = 0, releases = 0
        var allOffMain = true, allReleased = true
        var handled = false, actionPassed = false
        var tokens: [PreparationCancellation] = []
    }
    let preparer: TonalSamplePreparer
    let resume = DispatchSemaphore(value: 0)
    private let gate: Gate
    private let failFirst: Bool
    private let failStart: Bool
    private let failSuccessor: Bool
    private let lock = NSLock()
    private var counts = Counts()
    private var gateAction: (@MainActor @Sendable () -> Bool)?
    // Only the coordinator's control queue accesses graph/score state. No strong graph escapes.
    private weak var graph: AVAudioEngine?
    private var score: WorkerScore?

    init(
        gate: Gate = .none, failFirst: Bool = false, failStart: Bool = false,
        failSuccessor: Bool = false
    ) throws {
        preparer = try SourceTestScore().preparer
        self.gate = gate
        self.failFirst = failFirst
        self.failStart = failStart
        self.failSuccessor = failSuccessor
    }

    func snapshot() -> Counts { lock.withLock { counts } }

    @MainActor
    func onGate(_ action: @escaping @MainActor @Sendable () -> Bool) {
        lock.withLock { gateAction = action }
    }

    @MainActor
    func releaseGate() {
        lock.withLock { gateAction = nil }
        resume.signal()
    }

    private func wait() throws {
        let action = lock.withLock {
            defer { gateAction = nil }
            return gateAction
        }
        guard let action else { throw Injected.gate }
        // Controls and release run together, without waiting for a suspended test task
        // to resume while unrelated synchronous tests occupy the cooperative executors.
        DispatchQueue.main.async {
            defer { self.resume.signal() }
            let passed = action()
            self.lock.withLock {
                self.counts.handled = true
                self.counts.actionPassed = passed && Thread.isMainThread
            }
        }
        guard resume.wait(timeout: .now() + 30) == .success else { throw Injected.gate }
    }

    func make(_ token: PreparationCancellation) throws -> SessionAudioEngine {
        let call = lock.withLock {
            counts.calls += 1
            counts.active += 1
            counts.maximum = max(counts.maximum, counts.active)
            counts.allOffMain = counts.allOffMain && !Thread.isMainThread
            counts.tokens.append(token)
            return counts.calls
        }
        defer { lock.withLock { counts.active -= 1 } }
        if call == 1 && gate == .beforeOwner { try wait() }
        if call == 1 && failFirst { throw Injected.factory }
        try token.check()
        let score = WorkerScore(preparer, failOnce: failSuccessor)
        self.score = score
        let worker = try SessionPreparationWorker(cancellation: token) { try score.make($0) }
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 2)
        else { throw Injected.graph }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        graph = engine
        let released = PlaybackRelease { [weak worker] in
            self.lock.withLock {
                self.counts.releases += 1
                self.counts.allOffMain = self.counts.allOffMain && !Thread.isMainThread
                self.counts.allReleased =
                    self.counts.allReleased && worker == nil
                    && score.session == nil && score.pool?.reservedRacks == 0
            }
        }
        let owner = try SessionAudioEngine(
            worker: worker, engine: engine,
            start: { engine in
                try withExtendedLifetime(released) {
                    self.lock.withLock {
                        self.counts.starts += 1
                        self.counts.allOffMain = self.counts.allOffMain && !Thread.isMainThread
                    }
                    try engine.start()
                    if self.failStart {
                        guard
                            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 113),
                            try engine.renderOffline(113, to: buffer) == .success
                        else { throw Injected.graph }
                        throw Injected.start
                    }
                }
            })
        // Deliberately return a completed owner even if cancellation arrived in this gate.
        if call == 1 && gate == .afterOwner { try wait() }
        return owner
    }

    func pull(_ count: Int, _ owner: SessionAudioEngine?) throws
        -> (pcm: [Float], position: UInt32, cleared: Bool, failed: Bool)
    {
        guard !Thread.isMainThread, let owner, let graph,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: graph.manualRenderingFormat, frameCapacity: 4096)
        else { throw Injected.graph }
        let before = owner.position
        guard try graph.renderOffline(AVAudioFrameCount(count), to: buffer) == .success,
            buffer.frameLength == count, let channels = buffer.floatChannelData
        else { throw Injected.graph }
        let output = (0..<count).flatMap { [channels[0][$0], channels[1][$0]] }
        let written = Int(owner.position - before)
        return (
            Array(output.prefix(written * 2)), owner.position,
            output.dropFirst(written * 2).allSatisfy { $0 == 0 },
            owner.preparationError is WorkerScore.Injected
        )
    }

    func releaseRetry() { score?.retryResume.signal() }

    func pauseGraph() throws {
        guard !Thread.isMainThread, let graph else { throw Injected.graph }
        graph.pause()
    }
}

@MainActor
struct SessionPlaybackTests {
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try Task.checkCancellation()
            try #require(Date() < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func latestPauseDiscardsBlockedStartupWithoutLateAutoplay() async throws {
        let probe = try PlaybackProbe(gate: .afterOwner)
        let playback = SessionPlayback(factory: { try probe.make($0) })
        defer {
            probe.releaseGate()
            playback.stop()
        }
        #expect(playback.state == .idle && probe.snapshot().calls == 0)
        probe.onGate {
            for _ in 0..<128 {
                playback.play()
                playback.pause()
                playback.play()
                playback.refresh()
                playback.retryPreparation()
            }
            playback.pause()
            return probe.snapshot().tokens.first?.isCancelled == true
        }
        playback.play()
        try await until { probe.snapshot().handled }
        #expect(probe.snapshot().actionPassed)
        try await until { playback.state == .paused }
        #expect(probe.snapshot().calls == 1 && probe.snapshot().starts == 0)
        #expect(probe.snapshot().releases == 1 && probe.snapshot().allReleased)
        #expect(playback.lastError == nil && playback.position == 0)
        playback.play()
        try await until { playback.state == .playing }
        playback.stop()
        try await until { playback.state == .stopped }
        let result = probe.snapshot()
        #expect(result.calls == 2 && result.starts == 1 && result.maximum == 1)
        #expect(result.releases == 2 && result.allReleased && result.allOffMain)
    }

    @Test func duplicatePlayLatchesOneFailureButANewInterruptionCanRetry() async throws {
        for interrupted in [false, true] {
            let probe = try PlaybackProbe(gate: .beforeOwner, failFirst: true)
            let playback = SessionPlayback(factory: { try probe.make($0) })
            defer {
                probe.releaseGate()
                playback.stop()
            }
            probe.onGate {
                for _ in 0..<128 {
                    playback.play()
                    playback.refresh()
                }
                if interrupted {
                    playback.pause()
                    playback.play()
                }
                return probe.snapshot().calls == 1
                    && (!interrupted || probe.snapshot().tokens.first?.isCancelled == true)
            }
            playback.play()
            try await until { probe.snapshot().handled }
            #expect(probe.snapshot().actionPassed)
            if !interrupted {
                try await until { playback.state == .failed }
                #expect(playback.lastError as? PlaybackProbe.Injected == .factory)
                #expect(try await playback.inspect { $0 == nil })
                #expect(probe.snapshot().calls == 1)
                playback.play()
            }
            try await until { playback.state == .playing }
            #expect(playback.lastError == nil && probe.snapshot().calls == 2)
            playback.stop()
            try await until { playback.state == .stopped }
            let result = probe.snapshot()
            #expect(result.maximum == 1 && result.starts == 1 && result.allReleased)
        }
    }

    @Test func terminalStopAndFacadeDeinitCancelStartupAndReleaseOffMain() async throws {
        for dropFacade in [false, true] {
            let probe = try PlaybackProbe(gate: .afterOwner)
            let holder = PlaybackHandle(SessionPlayback(factory: { try probe.make($0) }))
            defer {
                probe.releaseGate()
                holder.value?.stop()
            }
            weak let lifetime = holder.value
            probe.onGate { [weak lifetime] in
                let observed: Bool
                if dropFacade {
                    holder.value = nil
                    observed = lifetime == nil
                } else {
                    holder.value?.stop()
                    observed = holder.value?.state == .stopping
                    holder.value?.play()
                    holder.value?.pause()
                    holder.value?.retryPreparation()
                }
                return observed && probe.snapshot().tokens.first?.isCancelled == true
            }
            holder.value?.play()
            try await until { probe.snapshot().handled }
            #expect(probe.snapshot().actionPassed)
            try await until { probe.snapshot().releases == 1 && probe.snapshot().active == 0 }
            if let playback = holder.value {
                try await until { playback.state == .stopped }
                #expect(try await playback.inspect { $0 == nil })
                #expect(playback.position == 0 && playback.lastError == nil)
            }
            let result = probe.snapshot()
            #expect(
                result.calls == 1 && result.starts == 0 && result.allReleased && result.allOffMain)
        }
    }

    @Test func actualStartFailurePreservesItsErrorAndRenderedPositionAfterCleanup() async throws {
        let probe = try PlaybackProbe(failStart: true)
        let playback = SessionPlayback(factory: { try probe.make($0) })
        defer { playback.stop() }
        playback.play()
        try await until { playback.state == .failed }
        #expect(playback.lastError as? PlaybackProbe.Injected == .start)
        #expect(playback.position == 113 && playback.sourceStatus == .rendering)
        #expect(try await playback.inspect { $0 == nil })
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(playback.lastError as? PlaybackProbe.Injected == .start && playback.position == 113)
        let result = probe.snapshot()
        #expect(result.calls == 1 && result.starts == 1 && result.releases == 1)
        #expect(result.allReleased && result.allOffMain)
    }

    @Test func refreshAndPreparationRetryNeverResumeAnExternallyPausedGraph() async throws {
        let probe = try PlaybackProbe()
        let playback = SessionPlayback(factory: { try probe.make($0) })
        defer { playback.stop() }
        playback.play()
        try await until { playback.state == .playing }
        let first = try await playback.inspect { try probe.pull(257, $0) }
        #expect(first.position == 257 && probe.snapshot().starts == 1)
        try await playback.inspect { _ in try probe.pauseGraph() }
        playback.refresh()
        try await until { playback.state == .paused }
        #expect(playback.position == 257 && probe.snapshot().starts == 1)
        playback.retryPreparation()
        #expect(try await playback.inspect { $0?.state == .paused })
        #expect(probe.snapshot().starts == 1)
        playback.play()
        try await until { playback.state == .playing }
        #expect(probe.snapshot().starts == 2 && playback.position == 257)
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(probe.snapshot().allReleased && probe.snapshot().allOffMain)
    }

    @Test func realOfflineAudioSurvivesAsyncPauseResumeAndCoalescedPreparationRetry() async throws {
        let probe = try PlaybackProbe(failSuccessor: true)
        let playback = SessionPlayback(factory: { try probe.make($0) })
        defer { playback.stop() }
        let expected = try await playback.inspect { _ in
            try ConcurrentSessionTests().independent(
                probe.preparer, origins: [0, 16_017, 50_001, 60_018], count: 90_017)
        }
        playback.play()
        try await until { playback.state == .playing }
        var actual: [Float] = []
        let sizes = [1, 159, 160, 161, 257, 1023]
        var block = 0
        var retried = false
        let clock = ContinuousClock()
        var progressDeadline = clock.now.advanced(by: .seconds(30))
        while actual.count / 2 < 90_017 {
            try Task.checkCancellation()
            let before = UInt32(actual.count / 2)
            let count = sizes[block % sizes.count]
            let output = try await playback.inspect { try probe.pull(count, $0) }
            actual += output.pcm
            #expect(output.cleared && output.position == actual.count / 2)
            if !output.pcm.isEmpty && output.position > before {
                progressDeadline = clock.now.advanced(by: .seconds(30))
            }
            block += 1
            if block == 3 || block == 12 || (output.failed && !retried) {
                playback.pause()
                try await until { playback.state == .paused }
                #expect(playback.position == actual.count / 2)
                if output.failed {
                    #expect(playback.lastError is WorkerScore.Injected)
                    playback.retryPreparation()
                    #expect(
                        try await playback.inspect { $0?.preparationError is WorkerScore.Injected })
                    try await playback.inspect { _ in probe.releaseRetry() }
                }
                playback.play()
                if output.failed {
                    playback.retryPreparation()
                    retried = true
                }
                try await until { playback.state == .playing }
                // Deliberate suspension is outside the consumption watchdog.
                progressDeadline = clock.now.advanced(by: .seconds(30))
            }
            if output.pcm.isEmpty {
                // Detect a stall, not slow total execution under concurrent test load.
                try #require(clock.now < progressDeadline)
                await Task.yield()
            }
        }
        playback.refresh()
        try await until { playback.position == 90_017 && playback.sourceStatus == .finished }
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern) && retried)
        #expect(playback.state == .playing && playback.lastError == nil)
        playback.stop()
        try await until { playback.state == .stopped }
        let result = probe.snapshot()
        #expect(result.calls == 1 && result.maximum == 1 && result.releases == 1)
        #expect(result.allReleased && result.allOffMain)
    }
}
