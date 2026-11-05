// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

private final class MediaServicesProbe: @unchecked Sendable {
    enum Injected: Error, Equatable { case preparation, deactivation, graph, gate }
    enum Stage { case preparation, activation, deactivation }
    struct Counts {
        var makes = 0, starts = 0, activations = 0, deactivations = 0
        var registrations = 0, cancellations = 0
        var handled = false, cancelledImmediately = false, cleanupOffMain = true
        var token: PreparationCancellation?
    }
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var counts = Counts()
    private var receive: (@Sendable (PlaybackAudioSessionEvent) -> Void)?
    private var action: (@MainActor @Sendable () -> Void)?
    private let stage: Stage?, emitBeforeGate: Bool, failFirst: Bool
    // Access only on the coordinator's control queue.
    private var failDeactivation: Bool
    private weak var graph: AVAudioEngine?
    private var score: SourceTestScore?

    init(
        stage: Stage? = nil, emitBeforeGate: Bool = true, failFirst: Bool = false,
        failDeactivation: Bool = false
    ) {
        self.stage = stage
        self.emitBeforeGate = emitBeforeGate
        self.failFirst = failFirst
        self.failDeactivation = failDeactivation
    }
    func snapshot() -> Counts { lock.withLock { counts } }
    func capture() -> (@Sendable (PlaybackAudioSessionEvent) -> Void)? { lock.withLock { receive } }
    func emit(_ event: PlaybackAudioSessionEvent) { capture()?(event) }
    @MainActor func onGate(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { self.action = action }
    }
    @MainActor func releaseGate() {
        lock.withLock { action = nil }
        release.signal()
    }
    private func wait(_ stage: Stage) throws {
        guard self.stage == stage else { return }
        let action = lock.withLock {
            let value = self.action
            self.action = nil
            return value
        }
        guard let action else { return }
        if emitBeforeGate {
            emit(.mediaServicesLost)
            emit(.mediaServicesReset)
            lock.withLock {
                counts.cancelledImmediately =
                    counts.token?.isCancelled == true && !Thread.isMainThread
            }
        }
        DispatchQueue.main.async {
            defer { self.release.signal() }
            action()
            self.lock.withLock { self.counts.handled = true }
        }
        guard release.wait(timeout: .now() + 30) == .success else { throw Injected.gate }
    }
    var policy: PlaybackAudioSession {
        PlaybackAudioSession(
            configure: {},
            activate: {
                self.lock.withLock { self.counts.activations += 1 }
                try self.wait(.activation)
            },
            deactivate: {
                self.lock.withLock { self.counts.deactivations += 1 }
                try self.wait(.deactivation)
                if self.failDeactivation {
                    self.failDeactivation = false
                    throw Injected.deactivation
                }
            },
            observe: { receive in
                self.lock.withLock {
                    self.receive = receive
                    self.counts.registrations += 1
                }
                return PlaybackAudioSessionObservation {
                    self.lock.withLock {
                        self.receive = nil
                        self.counts.cancellations += 1
                        self.counts.cleanupOffMain =
                            self.counts.cleanupOffMain && !Thread.isMainThread
                    }
                }
            })
    }
    func make(_ token: PreparationCancellation, _ prepareOutput: () throws -> Void) throws
        -> SessionAudioEngine
    {
        let call = lock.withLock {
            counts.token = token
            counts.makes += 1
            return counts.makes
        }
        try wait(.preparation)
        if failFirst && call == 1 { throw Injected.preparation }
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
    func prefix(_ owner: SessionAudioEngine?) throws -> [Float] {
        guard let owner, let graph,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: graph.manualRenderingFormat, frameCapacity: 257),
            try graph.renderOffline(257, to: buffer) == .success, owner.position == 257,
            let channels = buffer.floatChannelData
        else { throw Injected.graph }
        return (0..<257).flatMap { [channels[0][$0], channels[1][$0]] }
    }
    func released() -> Bool {
        graph == nil
            && (score == nil
                || (score?.worker == nil && score?.session == nil
                    && score?.pool?.reservedRacks == 0))
    }
}

@MainActor
struct PlaybackMediaServicesTests {
    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !predicate() {
            try Task.checkCancellation()
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func playback(_ probe: MediaServicesProbe) -> SessionPlayback {
        SessionPlayback(audioSession: probe.policy, factory: { try probe.make($0, $1) })
    }
    private func barrier(_ playback: SessionPlayback) async throws {
        _ = try await playback.inspect { $0?.position }
    }

    @Test func lossBlocksPlayAndResetRequiresNewUserActionWithoutReRegistering() async throws {
        let probe = MediaServicesProbe()
        let playback = playback(probe)
        defer { playback.stop() }
        playback.play()
        try await until { playback.state == .playing }
        _ = try await playback.inspect { try probe.prefix($0) }
        probe.emit(.mediaServicesLost)
        try await until { !playback.mediaServicesAvailable && playback.state == .paused }
        #expect(playback.position == 257 && playback.preparationStatus == .stopped)
        #expect(try await playback.inspect { $0 == nil && probe.released() })
        playback.play()
        playback.refresh()
        playback.retryPreparation()
        try await barrier(playback)
        #expect(probe.snapshot().makes == 1 && probe.snapshot().deactivations == 0)
        probe.emit(.mediaServicesReset)
        try await until { playback.mediaServicesAvailable && playback.state == .paused }
        probe.emit(.interruptionEnded(shouldResume: true))
        try await barrier(playback)
        #expect(probe.snapshot().makes == 1 && probe.snapshot().activations == 1)
        playback.play()
        try await until { playback.state == .playing }
        #expect(playback.position == 0 && probe.snapshot().makes == 2)
        #expect(probe.snapshot().registrations == 1)
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(probe.snapshot().cancellations == 1 && probe.snapshot().cleanupOffMain)
    }

    @Test func resetAloneDisposesPlayingOrPausedGraphsAndFreshPlayReproducesThePrefix() async throws
    {
        for paused in [false, true] {
            let probe = MediaServicesProbe()
            let playback = playback(probe)
            defer { playback.stop() }
            playback.play()
            try await until { playback.state == .playing }
            let first = try await playback.inspect { try probe.prefix($0) }
            if paused {
                playback.pause()
                try await until { playback.state == .paused }
            }
            let deactivations = probe.snapshot().deactivations
            probe.emit(.mediaServicesReset)
            probe.emit(.mediaServicesReset)
            try await barrier(playback)
            #expect(try await playback.inspect { $0 == nil && probe.released() })
            try await until { playback.state == .paused && playback.position == 257 }
            #expect(probe.snapshot().starts == 1 && probe.snapshot().deactivations == deactivations)
            playback.play()
            try await until { playback.state == .playing }
            #expect(playback.position == 0)
            let second = try await playback.inspect { try probe.prefix($0) }
            #expect(first.map(\.bitPattern) == second.map(\.bitPattern))
            playback.stop()
            try await until { playback.state == .stopped }
        }
    }

    @Test func lostThenResetDuringStartupOrActivationCannotPublishOrDeactivateOldOutput()
        async throws
    {
        for stage in [MediaServicesProbe.Stage.preparation, .activation] {
            for stop in [false, true] {
                let probe = MediaServicesProbe(stage: stage, emitBeforeGate: !stop)
                let playback = playback(probe)
                defer {
                    probe.releaseGate()
                    playback.stop()
                }
                probe.onGate {
                    if stop {
                        playback.stop()
                        // Already terminal intent still invalidates a pending activation's cleanup.
                        probe.emit(.mediaServicesLost)
                        probe.emit(.mediaServicesReset)
                    } else {
                        playback.pause()
                    }
                }
                playback.play()
                try await until {
                    probe.snapshot().handled && playback.state == (stop ? .stopped : .paused)
                }
                #expect(probe.snapshot().token?.isCancelled == true)
                #expect(stop || probe.snapshot().cancelledImmediately)
                #expect(probe.snapshot().starts == 0 && probe.snapshot().deactivations == 0)
                #expect(playback.lastError == nil && playback.audioSessionError == nil)
                #expect(try await playback.inspect { $0 == nil && probe.released() })
                if !stop {
                    playback.play()
                    try await until { playback.state == .playing }
                    #expect(probe.snapshot().makes == 2 && probe.snapshot().starts == 1)
                }
                playback.stop()
                try await until { playback.state == .stopped }
            }
        }
    }

    @Test func resetPreservesPrimaryFailuresButInvalidatesDefunctCleanupObligations() async throws {
        for primary in [false, true] {
            let probe = MediaServicesProbe(failFirst: primary, failDeactivation: !primary)
            let playback = playback(probe)
            defer { playback.stop() }
            playback.play()
            try await until { playback.state == (primary ? .failed : .playing) }
            if !primary {
                playback.pause()
                try await until { playback.state == .paused }
                #expect(playback.audioSessionError as? MediaServicesProbe.Injected == .deactivation)
            }
            let before = probe.snapshot()
            probe.emit(.mediaServicesLost)
            probe.emit(.mediaServicesReset)
            try await barrier(playback)
            try await until { playback.state == .paused && playback.audioSessionError == nil }
            #expect(
                probe.snapshot().makes == before.makes
                    && probe.snapshot().deactivations == before.deactivations)
            #expect(
                (playback.lastError as? MediaServicesProbe.Injected)
                    == (primary ? .preparation : nil))
            playback.refresh()
            playback.retryPreparation()
            try await barrier(playback)
            #expect(probe.snapshot().makes == before.makes)
            playback.play()
            try await until { playback.state == .playing && playback.lastError == nil }
            playback.stop()
            try await until { playback.state == .stopped }
        }
    }
    @Test func resetDuringTerminalDeactivationDiscardsItsLateFailure() async throws {
        let probe = MediaServicesProbe(
            stage: .deactivation, emitBeforeGate: false, failDeactivation: true)
        let playback = playback(probe)
        defer {
            probe.releaseGate()
            playback.stop()
        }
        playback.play()
        try await until { playback.state == .playing }
        let captured = try #require(probe.capture())
        probe.onGate {
            // A callback already captured before observer removal can still finish during Stop.
            captured(.mediaServicesLost)
            captured(.mediaServicesReset)
        }
        playback.stop()
        try await until { probe.snapshot().handled && playback.state == .stopped }
        #expect(playback.lastError == nil && playback.audioSessionError == nil)
        #expect(probe.snapshot().deactivations == 1 && probe.snapshot().cancellations == 1)
        #expect(try await playback.inspect { $0 == nil && probe.released() })
        captured(.mediaServicesLost)
        captured(.mediaServicesReset)
        playback.stop()
        try await barrier(playback)
        #expect(probe.snapshot().deactivations == 1 && playback.state == .stopped)
    }

}
