// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

private final class ConfigurationProbe: @unchecked Sendable {
    enum Injected: Error, Equatable { case graph, start, gate }
    struct Counts {
        var makes = 0, starts = 0, activations = 0, formats = 0
        var handled = false
    }
    struct Identity: Sendable, Equatable { let owner, graph, source, worker: ObjectIdentifier }
    let preparer: TonalSamplePreparer
    private let center = NotificationCenter(), lock = NSLock()
    private var counts = Counts()
    private var handler: (@Sendable (PlaybackAudioSessionEvent) -> Void)?
    private var gate: (@MainActor @Sendable () -> Void)?
    private let release = DispatchSemaphore(value: 0)
    // Graph, score, availability, and injected-start state belong only to the control queue.
    private weak var graph: AVAudioEngine?
    private var oldGraph: AVAudioEngine?, score: SourceTestScore?
    private var unavailable = false, failStart = false

    init() throws { preparer = try SourceTestScore().preparer }
    func snapshot() -> Counts { lock.withLock { counts } }
    func emit(_ event: PlaybackAudioSessionEvent) { lock.withLock { handler }?(event) }
    @MainActor func onActivation(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { gate = action }
    }
    @MainActor func releaseGate() {
        lock.withLock { gate = nil }
        release.signal()
    }
    var policy: PlaybackAudioSession {
        PlaybackAudioSession(
            configure: {},
            activate: {
                let action = self.lock.withLock {
                    self.counts.activations += 1
                    defer { self.gate = nil }
                    return self.gate
                }
                if let action {
                    DispatchQueue.main.async {
                        defer { self.release.signal() }
                        action()
                        self.lock.withLock { self.counts.handled = true }
                    }
                    guard self.release.wait(timeout: .now() + 30) == .success else {
                        throw Injected.gate
                    }
                }
            }, deactivate: {},
            observe: { handler in
                self.lock.withLock { self.handler = handler }
                return PlaybackAudioSessionObservation { self.lock.withLock { self.handler = nil } }
            })
    }
    func make(_ token: PreparationCancellation, _ prepareOutput: () throws -> Void) throws
        -> SessionAudioEngine
    {
        lock.withLock { counts.makes += 1 }
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
                    if self.failStart {
                        self.failStart = false
                        throw Injected.start
                    }
                    try engine.start()
                }, notificationCenter: center,
                outputFormat: { engine in
                    self.lock.withLock { self.counts.formats += 1 }
                    return self.unavailable ? nil : engine.manualRenderingFormat
                })
        } catch {
            worker.requestStop()
            worker.join()
            throw error
        }
    }
    func change(_ times: Int = 1, unavailable: Bool = false) throws {
        guard let graph else { throw Injected.graph }
        self.unavailable = unavailable
        graph.stop()  // Model the documented engine stop before a hardware configuration notice.
        for _ in 0..<times { center.post(name: .AVAudioEngineConfigurationChange, object: graph) }
    }
    func prepareStartFailure() throws {
        oldGraph = graph
        failStart = true
        try change()
    }
    func postOld() throws {
        guard let oldGraph else { throw Injected.graph }
        center.post(name: .AVAudioEngineConfigurationChange, object: oldGraph)
    }
    func clearOld() { oldGraph = nil }
    func identity(_ owner: SessionAudioEngine?) throws -> Identity {
        guard let owner, let graph, let worker = score?.worker else { throw Injected.graph }
        return try autoreleasepool {
            guard let node = graph.attachedNodes.first(where: { $0 is AVAudioSourceNode })
            else { throw Injected.graph }
            return Identity(
                owner: ObjectIdentifier(owner), graph: ObjectIdentifier(graph),
                source: ObjectIdentifier(node), worker: ObjectIdentifier(worker))
        }
    }
    func pull(_ count: Int, _ owner: SessionAudioEngine?) throws -> [Float] {
        guard let owner, let graph,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: graph.manualRenderingFormat, frameCapacity: 4096)
        else { throw Injected.graph }
        let before = owner.position
        guard try graph.renderOffline(AVAudioFrameCount(count), to: buffer) == .success,
            owner.position == before + UInt32(count), buffer.frameLength == count,
            let channels = buffer.floatChannelData
        else { throw Injected.graph }
        return (0..<count).flatMap { [channels[0][$0], channels[1][$0]] }
    }
    func released() -> Bool {
        graph == nil && score?.worker == nil && score?.session == nil
            && score?.pool?.reservedRacks == 0
    }
}

@MainActor
struct PlaybackConfigurationTests {
    private func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            try Task.checkCancellation()
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func playback(_ probe: ConfigurationProbe) -> SessionPlayback {
        SessionPlayback(audioSession: probe.policy, factory: { try probe.make($0, $1) })
    }
    private func barrier(_ playback: SessionPlayback) async throws {
        _ = try await playback.inspect { $0?.position }
    }

    @Test func coalescedRecoveryPreservesAllOwnersAndExactCanonicalAudio() async throws {
        let probe = try ConfigurationProbe()
        let playback = playback(probe)
        defer { playback.stop() }
        let expected = try await playback.inspect { _ in
            try ConcurrentSessionTests().independent(
                probe.preparer, origins: [0, 16_017], count: 50_003)
        }
        playback.play()
        try await until { playback.state == .playing }
        let identity = try await playback.inspect { try probe.identity($0) }
        var pcm = try await playback.inspect { try probe.pull(257, $0) }
        try await playback.inspect { _ in try probe.change(64) }
        try await until {
            probe.snapshot().starts == 2 && playback.state == .playing && playback.position == 257
        }
        #expect(try await playback.inspect { try probe.identity($0) } == identity)
        #expect(playback.position == 257 && probe.snapshot().makes == 1)
        while pcm.count / 2 < 50_003 {
            let count = min(4096, 50_003 - pcm.count / 2)
            pcm += try await playback.inspect { try probe.pull(count, $0) }
        }
        #expect(pcm.map(\.bitPattern) == expected.map(\.bitPattern))
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(try await playback.inspect { _ in probe.released() })
    }

    @Test func configurationCannotOverridePauseInterruptionDisconnectionOrStop() async throws {
        for intent in 0..<4 {
            let probe = try ConfigurationProbe()
            let playback = playback(probe)
            defer { playback.stop() }
            playback.play()
            try await until { playback.state == .playing }
            let identity = try await playback.inspect { try probe.identity($0) }
            switch intent {
            case 0: playback.pause()
            case 1: probe.emit(.interruptionBegan)
            case 2: probe.emit(.oldDeviceUnavailable)
            default: break
            }
            if intent < 3 { try await until { playback.state == .paused } }
            let before = probe.snapshot()
            try await playback.inspect { _ in try probe.change(32) }
            if intent == 3 { playback.stop() }
            try await barrier(playback)
            if intent == 3 {
                try await until { playback.state == .stopped }
                #expect(try await playback.inspect { _ in probe.released() })
            } else {
                #expect(
                    playback.state == .paused && probe.snapshot().activations == before.activations)
                #expect(probe.snapshot().formats == before.formats)
                if intent == 1 {
                    probe.emit(.interruptionEnded(shouldResume: true))
                } else {
                    probe.emit(.interruptionEnded(shouldResume: true))
                    try await barrier(playback)
                    #expect(playback.state == .paused)
                    playback.play()
                }
                try await until { playback.state == .playing }
                #expect(try await playback.inspect { try probe.identity($0) } == identity)
                #expect(probe.snapshot().makes == 1)
            }
            playback.stop()
            try await until { playback.state == .stopped }
        }
    }

    @Test func newerPauseOrStopDuringRecoveryActivationPreventsLateStart() async throws {
        for stop in [false, true] {
            let probe = try ConfigurationProbe()
            let playback = playback(probe)
            defer {
                probe.releaseGate()
                playback.stop()
            }
            playback.play()
            try await until { playback.state == .playing }
            probe.onActivation { if stop { playback.stop() } else { playback.pause() } }
            try await playback.inspect { _ in try probe.change() }
            try await until {
                probe.snapshot().handled && playback.state == (stop ? .stopped : .paused)
            }
            #expect(probe.snapshot().starts == 1 && probe.snapshot().makes == 1)
            #expect(playback.lastError == nil && playback.audioSessionError == nil)
            if !stop {
                playback.play()
                try await until { playback.state == .playing }
                #expect(probe.snapshot().starts == 2)
            }
            playback.stop()
            try await until { playback.state == .stopped }
            #expect(try await playback.inspect { _ in probe.released() })
        }
    }

    @Test func unavailableOutputLatchesUntilPlayAndOldEngineNoticesCannotRestartItsReplacement()
        async throws
    {
        let probe = try ConfigurationProbe()
        let playback = playback(probe)
        defer { playback.stop() }
        playback.play()
        try await until { playback.state == .playing }
        let identity = try await playback.inspect { try probe.identity($0) }
        _ = try await playback.inspect { try probe.pull(257, $0) }
        try await playback.inspect { _ in try probe.change(unavailable: true) }
        try await until { playback.lastError as? SessionAudioEngineError == .outputUnavailable }
        #expect(try await playback.inspect { $0?.state == .paused && $0?.position == 257 })
        let before = probe.snapshot()
        try await playback.inspect { _ in try probe.change(32) }
        playback.refresh()
        playback.retryPreparation()
        try await barrier(playback)
        #expect(
            probe.snapshot().starts == before.starts && probe.snapshot().formats == before.formats)
        playback.play()
        try await until { playback.state == .playing && playback.lastError == nil }
        #expect(try await playback.inspect { try probe.identity($0) } == identity)
        #expect(playback.position == 257 && probe.snapshot().makes == 1)
        do {
            try await playback.inspect { _ in try probe.prepareStartFailure() }
            try await until { playback.state == .failed }
            #expect(playback.lastError as? ConfigurationProbe.Injected == .start)
            playback.play()
            try await until { playback.state == .playing }
            #expect(probe.snapshot().makes == 2)
            let replacement = try await playback.inspect { try probe.identity($0) }
            #expect(replacement != identity)
            let starts = probe.snapshot().starts
            try await playback.inspect { _ in try probe.postOld() }
            try await barrier(playback)
            #expect(probe.snapshot().starts == starts && playback.state == .playing)
            try await playback.inspect { _ in probe.clearOld() }
        } catch {
            try? await playback.inspect { _ in probe.clearOld() }
            throw error
        }
        playback.stop()
        try await until { playback.state == .stopped }
        #expect(try await playback.inspect { _ in probe.released() })
    }
}
