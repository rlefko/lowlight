// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

@MainActor
private final class SessionPolicyHandle {
    var value: SessionPlayback?
    init(_ value: SessionPlayback) { self.value = value }
}

private final class SessionPolicyProbe: @unchecked Sendable {
    enum Step: String, Error, Sendable {
        case prepare, ready, configure, activate, create, start, deactivate, graph, gate
    }
    struct Snapshot {
        var events: [Step] = []
        var offMain = true, outputStopped = true, handled = false, actionPassed = false
        var lastDeactivationRacks: Int?
        var token: PreparationCancellation?
    }
    private let lock = NSLock()
    private var observation = Snapshot()
    private var action: (@MainActor @Sendable () -> Bool)?
    private var gatedStep = Step.activate
    private let release = DispatchSemaphore(value: 0)
    private let failure: Step?
    private let occurrence: Int
    // The following mutable fields belong only to the coordinator's control queue.
    private var deactivationFailures: Int
    private var score: SourceTestScore?
    private weak var graph: AVAudioEngine?

    init(failure: Step? = nil, occurrence: Int = 1, deactivationFailures: Int = 0) {
        self.failure = failure
        self.occurrence = occurrence
        self.deactivationFailures = deactivationFailures
    }

    func snapshot() -> Snapshot { lock.withLock { observation } }

    func didDeactivate() -> Bool {
        lock.withLock { observation.events.last == .deactivate }
    }

    @discardableResult
    private func record(_ step: Step) -> Int {
        lock.withLock {
            observation.events.append(step)
            observation.offMain = observation.offMain && !Thread.isMainThread
            return observation.events.filter { $0 == step }.count
        }
    }

    private func check(_ step: Step, count: Int) throws {
        if failure == step && occurrence == count { throw step }
    }

    @MainActor func onPolicyStep(_ step: Step, _ action: @escaping @MainActor @Sendable () -> Bool)
    {
        lock.withLock {
            gatedStep = step
            self.action = action
        }
    }

    @MainActor func releaseGate() {
        lock.withLock { action = nil }
        release.signal()
    }

    private func waitIfGated(_ step: Step) throws {
        let action: (@MainActor @Sendable () -> Bool)? = lock.withLock {
            guard gatedStep == step else { return nil }
            defer { self.action = nil }
            return self.action
        }
        guard let action else { return }
        DispatchQueue.main.async {
            defer { self.release.signal() }
            let passed = action()
            self.lock.withLock {
                self.observation.handled = true
                self.observation.actionPassed = passed && Thread.isMainThread
            }
        }
        guard release.wait(timeout: .now() + 30) == .success else { throw Step.gate }
    }

    var policy: PlaybackAudioSession {
        PlaybackAudioSession(
            configure: {
                let count = self.record(.configure)
                try self.waitIfGated(.configure)
                try self.check(.configure, count: count)
            },
            activate: {
                let count = self.record(.activate)
                try self.waitIfGated(.activate)
                try self.check(.activate, count: count)
            },
            deactivate: {
                self.lock.withLock {
                    self.observation.events.append(.deactivate)
                    self.observation.offMain = self.observation.offMain && !Thread.isMainThread
                    self.observation.outputStopped =
                        self.observation.outputStopped
                        && self.graph?.isRunning != true
                    self.observation.lastDeactivationRacks = self.score?.pool?.reservedRacks
                }
                if self.deactivationFailures > 0 {
                    self.deactivationFailures -= 1
                    throw Step.deactivate
                }
            })
    }

    func make(_ token: PreparationCancellation, _ prepareOutput: () throws -> Void) throws
        -> SessionAudioEngine
    {
        lock.withLock { observation.token = token }
        try check(.prepare, count: record(.prepare))
        try token.check()
        let score = try SourceTestScore()
        self.score = score
        let worker = try score.makeWorker()
        do {
            record(.ready)
            try prepareOutput()
            try token.check()
            let engine = AVAudioEngine()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 2)
            else { throw Step.graph }
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            graph = engine
            record(.create)
            return try SessionAudioEngine(
                worker: worker, engine: engine,
                start: { engine in
                    let count = self.record(.start)
                    try engine.start()
                    try self.check(.start, count: count)
                })
        } catch {
            worker.requestStop()
            worker.join()
            throw error
        }
    }

    func pull() throws -> Bool {
        guard let graph,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: graph.manualRenderingFormat, frameCapacity: 257)
        else { throw Step.graph }
        guard try graph.renderOffline(257, to: buffer) == .success,
            let channels = buffer.floatChannelData
        else { throw Step.graph }
        let samples = (0..<257).flatMap { [channels[0][$0], channels[1][$0]] }
        return samples.allSatisfy(\.isFinite) && samples.contains { $0 != 0 }
    }

    func released() -> Bool {
        score == nil
            || (score?.session == nil && score?.worker == nil && score?.pool?.reservedRacks == 0)
    }
}

@MainActor
struct PlaybackAudioSessionTests {
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try Task.checkCancellation()
            try #require(Date() < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func playback(_ probe: SessionPolicyProbe) -> SessionPlayback {
        SessionPlayback(audioSession: probe.policy, factory: { try probe.make($0, $1) })
    }

    @Test func policyStaysLazyAndOrdersActivationGraphStartPauseAndResume() async throws {
        let probe = SessionPolicyProbe()
        let playback = playback(probe)
        defer { playback.stop() }
        playback.refresh()
        playback.retryPreparation()
        #expect(try await playback.inspect { $0 == nil })
        #expect(probe.snapshot().events.isEmpty)
        playback.play()
        try await until { playback.state == .playing }
        let first: [SessionPolicyProbe.Step] = [
            .prepare, .ready, .configure, .activate, .create, .start,
        ]
        #expect(probe.snapshot().events == first)
        #expect(try await playback.inspect { _ in try probe.pull() })
        for _ in 0..<16 {
            playback.play()
            playback.refresh()
            playback.retryPreparation()
        }
        _ = try await playback.inspect { $0?.position }
        #expect(probe.snapshot().events == first)
        playback.pause()
        try await until { playback.state == .paused }
        #expect(probe.snapshot().events == first + [.deactivate])
        playback.play()
        try await until { playback.state == .playing }
        #expect(probe.snapshot().events == first + [.deactivate, .configure, .activate, .start])
        #expect(playback.position == 257)
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(try await playback.inspect { _ in probe.released() })
        #expect(probe.snapshot().outputStopped && probe.snapshot().offMain)
        #expect(playback.lastError == nil && playback.audioSessionError == nil)
    }

    @Test func startupFailuresPreservePrimaryErrorsAndIndependentCleanupErrors() async throws {
        for failure in [SessionPolicyProbe.Step.prepare, .configure, .activate, .start] {
            let cleanupOwed = failure == .activate || failure == .start
            let probe = SessionPolicyProbe(
                failure: failure, deactivationFailures: cleanupOwed ? 1 : 0)
            let playback = playback(probe)
            defer { playback.stop() }
            playback.play()
            try await until { playback.state == .failed }
            #expect(playback.lastError as? SessionPolicyProbe.Step == failure)
            #expect(
                (playback.audioSessionError as? SessionPolicyProbe.Step)
                    == (cleanupOwed ? .deactivate : nil))
            #expect(
                probe.snapshot().events.filter { $0 == .deactivate }.count == (cleanupOwed ? 1 : 0))
            #expect(try await playback.inspect { _ in probe.released() })
            let events = probe.snapshot().events
            playback.stop()
            try await until { playback.state == .stopped }
            #expect(probe.snapshot().events == events + (cleanupOwed ? [.deactivate] : []))
            #expect(playback.lastError as? SessionPolicyProbe.Step == failure)
            #expect(playback.audioSessionError == nil && probe.snapshot().outputStopped)
        }
    }

    @Test func onlyExplicitStopRetriesFailedTerminalDeactivation() async throws {
        let probe = SessionPolicyProbe(deactivationFailures: 2)
        let playback = playback(probe)
        defer { playback.stop() }
        playback.play()
        try await until { playback.state == .playing }
        playback.pause()
        try await until { playback.state == .paused }
        #expect(
            playback.lastError == nil
                && playback.audioSessionError as? SessionPolicyProbe.Step == .deactivate)
        playback.stop()
        try await until { playback.state == .stopped }
        let failed = probe.snapshot().events
        #expect(failed.filter { $0 == .deactivate }.count == 2)
        playback.play()
        playback.pause()
        playback.refresh()
        playback.retryPreparation()
        #expect(try await playback.inspect { $0 == nil && probe.released() })
        #expect(probe.snapshot().events == failed && playback.state == .stopped)
        #expect(playback.audioSessionError as? SessionPolicyProbe.Step == .deactivate)
        playback.stop()
        try await until { playback.state == .stopped && playback.audioSessionError == nil }
        #expect(probe.snapshot().events == failed + [.deactivate])
        #expect(probe.snapshot().outputStopped && probe.snapshot().lastDeactivationRacks == 0)
    }

    @Test func pauseStopAndDeinitDuringPolicyCallsCannotStartLateOrRetryCleanup() async throws {
        let cases: [(SessionPolicyProbe.Step, Int, Int)] = [
            (.configure, 0, 0), (.configure, 1, 0),
            (.activate, 0, 0), (.activate, 1, 0), (.activate, 2, 0), (.activate, 1, 1),
        ]
        for (step, intent, cleanupFailures) in cases {
            let probe = SessionPolicyProbe(deactivationFailures: cleanupFailures)
            let holder = SessionPolicyHandle(playback(probe))
            defer {
                probe.releaseGate()
                holder.value?.stop()
            }
            weak let lifetime = holder.value
            probe.onPolicyStep(step) { [weak lifetime] in
                if intent == 0 {
                    holder.value?.pause()
                } else if intent == 1 {
                    holder.value?.stop()
                } else {
                    holder.value = nil
                }
                return probe.snapshot().token?.isCancelled == true
                    && (intent != 2 || lifetime == nil)
            }
            holder.value?.play()
            try await until { probe.snapshot().handled }
            #expect(probe.snapshot().actionPassed)
            var expected: [SessionPolicyProbe.Step] = [.prepare, .ready, .configure]
            if step == .activate { expected += [.activate, .deactivate] }
            if let playback = holder.value {
                try await until { playback.state == (intent == 0 ? .paused : .stopped) }
                #expect(playback.lastError == nil)
                #expect(try await playback.inspect { _ in probe.released() })
                #expect(probe.snapshot().events == expected)
                if cleanupFailures > 0 {
                    #expect(playback.audioSessionError as? SessionPolicyProbe.Step == .deactivate)
                    playback.refresh()
                    playback.retryPreparation()
                    #expect(try await playback.inspect { $0 == nil })
                    #expect(probe.snapshot().events == expected)
                    playback.stop()
                    try await until {
                        playback.state == .stopped && playback.audioSessionError == nil
                    }
                    expected.append(.deactivate)
                } else {
                    #expect(playback.audioSessionError == nil)
                }
            } else {
                try await until { probe.didDeactivate() }
            }
            #expect(probe.snapshot().events == expected && probe.snapshot().offMain)
            if step == .activate { #expect(probe.snapshot().lastDeactivationRacks == 0) }
        }
    }

    @Test func resumePolicyFailureDisposesTheExistingOwnerAndPreservesItsPosition() async throws {
        for failure in [SessionPolicyProbe.Step.configure, .activate] {
            let probe = SessionPolicyProbe(failure: failure, occurrence: 2)
            let playback = playback(probe)
            defer { playback.stop() }
            playback.play()
            try await until { playback.state == .playing }
            #expect(try await playback.inspect { _ in try probe.pull() })
            playback.pause()
            try await until { playback.state == .paused }
            playback.play()
            try await until { playback.state == .failed }
            #expect(
                playback.position == 257
                    && playback.lastError as? SessionPolicyProbe.Step == failure)
            #expect(try await playback.inspect { $0 == nil && probe.released() })
            #expect(probe.snapshot().events.filter { $0 == .start }.count == 1)
            playback.play()
            try await until { playback.state == .playing }
            #expect(
                playback.position == 0 && playback.lastError == nil
                    && playback.audioSessionError == nil)
            #expect(probe.snapshot().events.filter { $0 == .create }.count == 2)
            playback.stop()
            try await until { playback.state == .stopped }
            #expect(probe.snapshot().outputStopped && probe.snapshot().offMain)
        }
    }
}
