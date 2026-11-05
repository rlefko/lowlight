// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

@MainActor
private final class InterruptionHandle {
    var value: SessionPlayback?
    init(_ value: SessionPlayback) { self.value = value }
}

private final class InterruptionProbe: @unchecked Sendable {
    enum Injected: Error, Equatable { case factory, graph, gate }
    struct Counts {
        var registrations = 0, cancellations = 0, makes = 0, starts = 0
        var activations = 0, deactivations = 0
        var cancelledImmediately = false, handled = false, actionPassed = false
        var offMain = true, outputStopped = true
    }
    let preparer: TonalSamplePreparer
    private let lock = NSLock()
    private var counts = Counts()
    private var handler: (@Sendable (PlaybackAudioSessionEvent) -> Void)?
    private var gateAction: (@MainActor @Sendable () -> Bool)?
    private let gateEvents: [PlaybackAudioSessionEvent]
    private let release = DispatchSemaphore(value: 0)
    private let failFirst: Bool
    // These fields are read/written only on the coordinator's serial control queue.
    private weak var graph: AVAudioEngine?
    private var score: SourceTestScore?

    init(events: [PlaybackAudioSessionEvent] = [], failFirst: Bool = false) throws {
        preparer = try SourceTestScore().preparer
        gateEvents = events
        self.failFirst = failFirst
    }

    func snapshot() -> Counts { lock.withLock { counts } }
    func capture() -> (@Sendable (PlaybackAudioSessionEvent) -> Void)? {
        lock.withLock { handler }
    }
    func emit(_ event: PlaybackAudioSessionEvent) { capture()?(event) }

    var policy: PlaybackAudioSession {
        PlaybackAudioSession(
            configure: {}, activate: { self.lock.withLock { self.counts.activations += 1 } },
            deactivate: {
                self.lock.withLock {
                    self.counts.deactivations += 1
                    self.counts.outputStopped =
                        self.counts.outputStopped && self.graph?.isRunning != true
                }
            },
            observe: { handler in
                self.lock.withLock {
                    self.counts.registrations += 1
                    self.counts.offMain = self.counts.offMain && !Thread.isMainThread
                    self.handler = handler
                }
                return PlaybackAudioSessionObservation {
                    self.lock.withLock {
                        self.counts.cancellations += 1
                        self.counts.offMain = self.counts.offMain && !Thread.isMainThread
                        self.handler = nil
                    }
                }
            })
    }

    @MainActor func onGate(_ action: @escaping @MainActor @Sendable () -> Bool) {
        lock.withLock { gateAction = action }
    }
    @MainActor func releaseGate() {
        lock.withLock { gateAction = nil }
        release.signal()
    }

    func make(_ token: PreparationCancellation, _ prepareOutput: () throws -> Void) throws
        -> SessionAudioEngine
    {
        let call = lock.withLock {
            counts.makes += 1
            return counts.makes
        }
        if call == 1,
            let action = lock.withLock({
                let result = gateAction
                gateAction = nil
                return result
            })
        {
            // Events reach the mailbox off-main while its factory occupies the control queue.
            gateEvents.forEach(emit)
            lock.withLock {
                counts.cancelledImmediately = token.isCancelled && !Thread.isMainThread
            }
            DispatchQueue.main.async {
                defer { self.release.signal() }
                let passed = action()
                self.lock.withLock {
                    self.counts.handled = true
                    self.counts.actionPassed = passed
                }
            }
            guard release.wait(timeout: .now() + 30) == .success else { throw Injected.gate }
        }
        if call == 1 && failFirst { throw Injected.factory }
        try token.check()
        let score = try SourceTestScore()
        self.score = score
        let worker = try score.makeWorker()
        do {
            try prepareOutput()
            try token.check()
            let engine = AVAudioEngine()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 2)
            else { throw Injected.graph }
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            graph = engine
            return try SessionAudioEngine(
                worker: worker, engine: engine,
                start: { engine in
                    self.lock.withLock { self.counts.starts += 1 }
                    try engine.start()
                })
        } catch {
            worker.requestStop()
            worker.join()
            throw error
        }
    }

    func pull(_ count: Int, _ owner: SessionAudioEngine?) throws -> [Float] {
        guard let owner, let graph,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: graph.manualRenderingFormat, frameCapacity: 4096)
        else { throw Injected.graph }
        let before = owner.position
        guard try graph.renderOffline(AVAudioFrameCount(count), to: buffer) == .success,
            buffer.frameLength == count, owner.position == before + UInt32(count),
            let channels = buffer.floatChannelData
        else { throw Injected.graph }
        return (0..<count).flatMap { [channels[0][$0], channels[1][$0]] }
    }

    func released() -> Bool {
        graph == nil
            && (score == nil
                || (score?.worker == nil && score?.session == nil
                    && score?.pool?.reservedRacks == 0))
    }
}

@MainActor
struct PlaybackInterruptionTests {
    private func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            try Task.checkCancellation()
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func playback(_ probe: InterruptionProbe) -> SessionPlayback {
        SessionPlayback(audioSession: probe.policy, factory: { try probe.make($0, $1) })
    }
    private func barrier(_ playback: SessionPlayback) async throws {
        _ = try await playback.inspect { $0?.position }
    }

    @Test func matchedAndCoalescedInterruptionsPreserveExactOfflinePCMAndPosition() async throws {
        let probe = try InterruptionProbe()
        let playback = playback(probe)
        defer { playback.stop() }
        let expected = try await playback.inspect { _ in
            try ConcurrentSessionTests().independent(
                probe.preparer, origins: [0, 16_017], count: 50_003)
        }
        playback.play()
        try await until { playback.state == .playing }
        var pcm = try await playback.inspect { try probe.pull(257, $0) }
        probe.emit(.interruptionBegan)
        try await until { playback.isInterrupted && playback.state == .paused }
        #expect(playback.position == 257 && probe.snapshot().deactivations == 1)
        probe.emit(.interruptionBegan)  // Duplicate begin is not a nested interruption.
        try await barrier(playback)
        #expect(probe.snapshot().deactivations == 1)
        probe.emit(.interruptionEnded(shouldResume: true))
        try await until { !playback.isInterrupted && playback.state == .playing }
        #expect(playback.position == 257 && probe.snapshot().starts == 2)
        // Both events arrive before the serial queue can reconcile either one.
        try await playback.inspect { _ in
            probe.emit(.interruptionBegan)
            probe.emit(.interruptionEnded(shouldResume: true))
        }
        try await until { probe.snapshot().starts == 3 && playback.state == .playing }
        #expect(probe.snapshot().deactivations == 2 && probe.snapshot().outputStopped)
        for count in [1, 159, 160, 161, 1023] {
            pcm += try await playback.inspect { try probe.pull(count, $0) }
        }
        while pcm.count / 2 < 50_003 {
            let count = min(4096, 50_003 - pcm.count / 2)
            pcm += try await playback.inspect { try probe.pull(count, $0) }
        }
        #expect(pcm.map(\.bitPattern) == expected.map(\.bitPattern))
        playback.refresh()
        try await until { playback.position == 50_003 && playback.sourceStatus == .finished }
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(try await playback.inspect { _ in probe.released() })
    }

    @Test func userIntentPermissionAndRouteLossControlResumption() async throws {
        for action in 0..<5 {
            let probe = try InterruptionProbe()
            let playback = playback(probe)
            defer { playback.stop() }
            playback.play()
            try await until { playback.state == .playing }
            probe.emit(.interruptionEnded(shouldResume: true))  // Unmatched end is inert.
            try await barrier(playback)
            #expect(probe.snapshot().starts == 1)
            probe.emit(.interruptionBegan)
            try await until { playback.isInterrupted && playback.state == .paused }
            switch action {
            case 0: playback.pause()
            case 1: playback.stop()
            case 2:
                playback.pause()
                playback.play()
            case 3: break  // End without permission remains paused.
            default: probe.emit(.oldDeviceUnavailable)
            }
            if action == 2 {
                // End notifications are not guaranteed; explicit Play supersedes the old begin.
                try await until { playback.state == .playing && !playback.isInterrupted }
            }
            try await barrier(playback)
            let starts = action == 2 ? 2 : 1
            #expect(probe.snapshot().starts == starts && probe.snapshot().activations == starts)
            probe.emit(.interruptionEnded(shouldResume: action != 2 && action != 3))
            try await until { action == 1 ? playback.state == .stopped : !playback.isInterrupted }
            if action == 2 {
                try await barrier(playback)
                #expect(playback.state == .playing && probe.snapshot().starts == 2)
            } else {
                #expect(playback.state == (action == 1 ? .stopped : .paused))
                probe.emit(.interruptionEnded(shouldResume: true))
                playback.refresh()
                playback.retryPreparation()
                try await barrier(playback)
                #expect(probe.snapshot().starts == 1)
                if action != 1 {
                    playback.play()
                    try await until { playback.state == .playing }
                    #expect(probe.snapshot().starts == 2)
                }
            }
            playback.stop()
            try await until { playback.state == .stopped }
        }
    }

    @Test func offMainStartupEventsCancelImmediatelyAndCoalescedEndCanPrepareFresh() async throws {
        for coalesced in [false, true] {
            let events: [PlaybackAudioSessionEvent] =
                coalesced
                ? [.interruptionBegan, .interruptionEnded(shouldResume: true)]
                : [.interruptionBegan]
            let probe = try InterruptionProbe(events: events)
            let playback = playback(probe)
            defer {
                probe.releaseGate()
                playback.stop()
            }
            probe.onGate {
                if !coalesced {
                    playback.pause()
                    probe.emit(.interruptionEnded(shouldResume: true))
                }
                return probe.snapshot().cancelledImmediately
            }
            playback.play()
            try await until {
                probe.snapshot().handled && playback.state == (coalesced ? .playing : .paused)
            }
            let result = probe.snapshot()
            #expect(result.actionPassed && result.cancelledImmediately && playback.lastError == nil)
            #expect(result.makes == (coalesced ? 2 : 1) && result.starts == (coalesced ? 1 : 0))
            #expect(result.activations == (coalesced ? 1 : 0) && result.registrations == 1)
            playback.stop()
            try await until { playback.state == .stopped }
        }
    }

    @Test func interruptionNeverRetriesALatchedStartupFailure() async throws {
        let probe = try InterruptionProbe(failFirst: true)
        let playback = playback(probe)
        defer { playback.stop() }
        playback.play()
        try await until { playback.state == .failed }
        #expect(playback.lastError as? InterruptionProbe.Injected == .factory)
        probe.emit(.interruptionBegan)
        try await until { playback.isInterrupted }
        probe.emit(.interruptionEnded(shouldResume: true))
        try await until { !playback.isInterrupted }
        playback.refresh()
        playback.retryPreparation()
        try await barrier(playback)
        #expect(probe.snapshot().makes == 1 && probe.snapshot().starts == 0)
        #expect(playback.lastError as? InterruptionProbe.Injected == .factory)
        playback.play()
        try await until { playback.state == .playing }
        #expect(probe.snapshot().makes == 2 && probe.snapshot().registrations == 1)
        playback.stop()
        try await until { playback.state == .stopped }
    }

    @Test func observationsAreLazySingleAndRemovedBeforeTerminalOrDeinitLateEvents() async throws {
        for explicitStop in [false, true] {
            let probe = try InterruptionProbe()
            let handle = InterruptionHandle(playback(probe))
            weak var facade = handle.value
            defer { handle.value?.stop() }
            handle.value?.refresh()
            handle.value?.retryPreparation()
            try await handle.value?.inspect { _ in () }
            #expect(probe.snapshot().registrations == 0)
            handle.value?.play()
            try await until { handle.value?.state == .playing }
            let late = try #require(probe.capture())
            if explicitStop {
                handle.value?.stop()
                try await until { handle.value?.state == .stopped }
            } else {
                handle.value = nil
            }
            try await until { probe.snapshot().cancellations == 1 }
            let before = probe.snapshot()
            late(.interruptionBegan)
            late(.interruptionEnded(shouldResume: true))
            late(.oldDeviceUnavailable)
            if let value = handle.value {
                try await barrier(value)
                #expect(value.state == .stopped)
                #expect(try await value.inspect { _ in probe.released() })
                handle.value = nil
            }
            #expect(facade == nil && probe.snapshot().registrations == 1)
            #expect(probe.snapshot().starts == before.starts && probe.snapshot().cancellations == 1)
            #expect(probe.snapshot().offMain)
        }
    }
}
