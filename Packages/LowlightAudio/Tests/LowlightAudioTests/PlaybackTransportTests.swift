// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private final class TransportPlaybackProbe: @unchecked Sendable {
    enum Failure: Error { case graph }
    let controls = Controls(
        energy: 0.58, mood: 0.35, warmth: 0.86, space: 0.42, texture: 0.08, variation: 0.60)
    let preparer: TonalSamplePreparer
    private let continuous: Bool
    private let lock = NSLock()
    private var receiver: (@Sendable (PlaybackAudioSessionEvent) -> Void)?
    private var activationAction: (@Sendable () -> Void)?
    private var factories = 0
    private var starts = 0
    private var suppliedRestart: SessionRestartIntent?
    // The real owner is the sole strong graph owner. All access here is on its control queue.
    private weak var graph: AVAudioEngine?
    private weak var source: SessionAudioSource?
    private var score: SourceTestScore?

    init(continuous: Bool) throws {
        self.continuous = continuous
        preparer = try SourceTestScore().preparer
    }

    var counts: (factories: Int, starts: Int) { lock.withLock { (factories, starts) } }
    var factoryRestart: SessionRestartIntent? { lock.withLock { suppliedRestart } }
    func onActivation(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { activationAction = action }
    }
    func emit(_ event: PlaybackAudioSessionEvent) {
        let callback = lock.withLock { receiver }
        callback?(event)
    }
    var policy: PlaybackAudioSession {
        PlaybackAudioSession(
            configure: {},
            activate: {
                let action = self.lock.withLock {
                    defer { self.activationAction = nil }
                    return self.activationAction
                }
                action?()
            }, deactivate: {},
            observe: { receive in
                self.lock.withLock { self.receiver = receive }
                return PlaybackAudioSessionObservation {
                    self.lock.withLock { self.receiver = nil }
                }
            })
    }

    func make(
        _ token: PreparationCancellation, _ prepareOutput: () throws -> Void,
        _ restart: SessionRestartIntent?
    ) throws -> SessionAudioEngine {
        lock.withLock {
            factories += 1
            suppliedRestart = restart
        }
        let worker: SessionPreparationWorker
        if continuous {
            worker = try SessionPreparationWorker(
                controls: controls, restart: restart, preparer: preparer, cancellation: token)
        } else {
            let score = try SourceTestScore()
            self.score = score
            worker = try score.makeWorker()
        }
        do {
            try prepareOutput()
            try token.check()
            let engine = AVAudioEngine()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 2)
            else { throw Failure.graph }
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            graph = engine
            return try SessionAudioEngine(
                worker: worker, engine: engine,
                start: { engine in
                    self.lock.withLock { self.starts += 1 }
                    try engine.start()
                },
                makeSource: { worker in
                    let source = try SessionAudioSource(worker: worker)
                    self.source = source
                    return source
                })
        } catch {
            worker.requestStop()
            worker.join()
            throw error
        }
    }

    func failSource() throws -> OSStatus {
        guard let source else { throw Failure.graph }
        var silent = ObjCBool(false)
        var output = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil))
        return source.render(isSilence: &silent, frameCount: 1, outputData: &output)
    }

    func pull(_ count: Int, _ owner: SessionAudioEngine?) throws -> (pcm: [Float], position: UInt64)
    {
        guard let graph, let owner,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: graph.manualRenderingFormat,
                frameCapacity: AVAudioFrameCount(count))
        else { throw Failure.graph }
        let before = owner.position
        guard try graph.renderOffline(AVAudioFrameCount(count), to: buffer) == .success,
            let channels = buffer.floatChannelData
        else { throw Failure.graph }
        let written = Int(owner.position - before)
        return ((0..<written).flatMap { [channels[0][$0], channels[1][$0]] }, owner.position)
    }
}

@MainActor
struct PlaybackTransportTests {
    private func until(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while !condition() {
            try Task.checkCancellation()
            try #require(clock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func directCommandsCoalesceAndCannotTurnPreResetPlayIntoFreshPermission() async throws {
        let probe = try TransportPlaybackProbe(continuous: false)
        let playback = SessionPlayback(
            audioSession: probe.policy, restart: nil, factory: probe.make)
        let input = playback.commandInput
        defer { playback.stop() }
        #expect(!input.send(.next))
        probe.onActivation {
            for _ in 0..<100 { _ = input.send(.play) }
            probe.emit(.mediaServicesReset)
        }
        #expect(input.send(.play))
        _ = try await playback.inspect { $0 == nil }
        try await until { playback.state == .paused }
        #expect(probe.counts.factories == 1 && probe.counts.starts == 0)
        #expect(!playback.requestedPlayback && playback.mediaServicesAvailable)
        probe.onActivation {
            _ = input.send(.toggle)
            _ = input.send(.toggle)
        }
        #expect(input.send(.play))
        _ = try await playback.inspect { $0?.state }
        try await until { playback.state == .playing }
        #expect(probe.counts.factories == 3 && probe.counts.starts == 1)
        #expect(playback.requestedPlayback)
        playback.pause()
        _ = try await playback.inspect { $0?.state }
        try await until { playback.state == .paused }
        let starts = probe.counts.starts
        playback.requestCapture()
        playback.refresh()
        _ = try await playback.inspect { $0?.state }
        #expect(probe.counts.starts == starts)
        playback.play()
        _ = try await playback.inspect { $0?.state }
        try await until { playback.state == .playing }
        _ = try await playback.inspect { try probe.pull(257, $0) }
        let status = try await playback.inspect { _ in try probe.failSource() }
        #expect(status == kAudio_ParamError)
        // No Refresh: the existing worker cadence reports the weak source failure.
        try await until { playback.state == .failed }
        #expect(playback.lastError as? PreparationWorkerError == .renderFailed)
        #expect(playback.position == 257)
        #expect(try await playback.inspect { $0 == nil })
        let failedFactories = probe.counts.factories
        #expect(input.send(.play))
        _ = try await playback.inspect { $0?.state }
        try await until { playback.state == .playing }
        #expect(probe.counts.factories == failedFactories + 1)
        playback.stop()
        _ = try await playback.inspect { $0 == nil }
        try await until { playback.state == .stopped }
        #expect(!input.send(.play) && !input.send(.toggle) && !input.send(.next))
    }

    @Test func nativeEarlyNextCapturesSelectedPositionAndWarmRestoresOnlyAfterExplicitPlay()
        async throws
    {
        let probe = try TransportPlaybackProbe(continuous: true)
        let playback = SessionPlayback(
            audioSession: probe.policy, restart: nil, factory: probe.make)
        defer { playback.stop() }
        #expect(probe.counts.factories == 0 && playback.state == .idle)
        playback.play()
        // Initial full-song analysis has no correctness speed limit. This queue barrier
        // waits for the real factory; later waits bound only missing progress/acknowledgment.
        _ = try await playback.inspect { $0?.finiteFrameCount }
        try await until { playback.state == .playing && playback.listeningSnapshot != nil }
        let initial = try #require(playback.listeningSnapshot)
        let schedule = try #require(try SessionPlanning.restore(initial.restart.checkpoint).current)
        let nextID = try #require(initial.nextSong?.id)
        let handoff = try PreparationMode.perform {
            UInt64(
                try schedule.frame(at: 32) - schedule.frame(at: 0)
                    + schedule.outgoing.handoffFrame() - schedule.outgoing.ramp.frame(at: 0))
        }
        let input = playback.commandInput
        playback.pause()
        _ = try await playback.inspect { $0?.position }
        try await until { playback.state == .paused && playback.preparationStatus == .suspended }
        let starts = probe.counts.starts
        for _ in 0..<100 { #expect(input.send(.next)) }
        _ = try await playback.inspect { $0?.position }
        try await until { playback.listeningSnapshot?.nextState == .queued }
        #expect(playback.state == .paused && playback.position == 0)
        #expect(probe.counts.starts == starts)
        playback.play()
        _ = try await playback.inspect { $0?.position }
        try await until { playback.state == .playing }
        var pcm: [Float] = []
        var position: UInt64 = 0
        var stalledSince: ContinuousClock.Instant?
        let clock = ContinuousClock()
        // Small initial pulls give the real worker an offer/adoption turn, without a
        // test-only publication hook or alteration of the callback's preparation policy.
        while playback.listeningSnapshot?.nextState != .transitioning {
            let value = try await playback.inspect { try probe.pull(256, $0) }
            pcm += value.pcm
            if value.position > position {
                stalledSince = nil
            } else {
                stalledSince = stalledSince ?? clock.now
                try #require(clock.now - (stalledSince ?? clock.now) < .seconds(30))
            }
            position = value.position
            try #require(position < handoff)
            try await Task.sleep(for: .milliseconds(1))
        }
        for target in [handoff - 1, handoff, handoff + 32_000] {
            while position < target {
                let count = Int(min(4096, target - position))
                let value = try await playback.inspect { try probe.pull(count, $0) }
                pcm += value.pcm
                if value.position > position {
                    stalledSince = nil
                } else {
                    stalledSince = stalledSince ?? clock.now
                    try #require(clock.now - (stalledSince ?? clock.now) < .seconds(30))
                    try await Task.sleep(for: .milliseconds(1))
                }
                position = value.position
            }
            playback.requestCapture()
            try await until { playback.listeningSnapshot?.transportFrame == target }
            #expect(
                playback.listeningSnapshot?.selectionID
                    == (target < handoff ? initial.selectionID : nextID))
        }
        playback.pause()
        _ = try await playback.inspect { $0?.position }
        try await until { playback.state == .paused && playback.preparationStatus == .suspended }
        playback.requestCapture()
        try await until { playback.listeningSnapshot?.transportFrame == position }
        let captured = try #require(playback.listeningSnapshot)
        #expect(captured.selectionID == nextID && captured.nextState == .none)
        #expect(pcm.count == Int(position) * 2 && pcm.allSatisfy { $0.isFinite })
        #expect(pcm.contains { abs($0) > 0.001 })
        probe.emit(.mediaServicesReset)
        _ = try await playback.inspect { $0 == nil }
        try await until { playback.state == .paused && playback.preparationStatus == .stopped }
        #expect(probe.counts.factories == 1 && !playback.requestedPlayback)
        #expect(playback.listeningSnapshot?.restart == captured.restart)
        playback.play()
        _ = try await playback.inspect { $0?.position }
        try await until { playback.state == .playing && probe.counts.factories == 2 }
        #expect(probe.factoryRestart == captured.restart)
        let restored = try #require(playback.listeningSnapshot)
        #expect(restored.selectionID == captured.selectionID)
        #expect(restored.canonicalFrame == captured.canonicalFrame)
        #expect(restored.transportFrame < captured.transportFrame)
        let entry = try await playback.inspect { try probe.pull(257, $0) }
        #expect(entry.pcm.first == 0 && entry.pcm[1] == 0)
        #expect(entry.pcm.allSatisfy { $0.isFinite })
        playback.stop()
        _ = try await playback.inspect { $0 == nil }
        try await until { playback.state == .stopped }
        #expect(playback.listeningSnapshot?.canonicalFrame == captured.canonicalFrame + 257)
        if let directory = ProcessInfo.processInfo.environment["LOWLIGHT_TRANSPORT_OUTPUT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try pcm.withUnsafeBytes {
                try Data($0).write(to: url.appendingPathComponent("native-next.f32"))
            }
            try captured.restart.encoded().write(to: url.appendingPathComponent("restart.json"))
        }
    }
}
