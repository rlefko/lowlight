// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio

public enum SessionAudioEngineState: Sendable { case paused, playing, stopped }
public enum SessionAudioEngineError: Error { case stopped, outputUnavailable }

/// Owns one graph and preparation worker. All access and final release must be serialized
/// on a non-main control context, never the audio callback. Construction adopts exclusive
/// control of the supplied worker, including stopping/joining it if initialization fails.
/// This synchronous owner does not configure audio-session policy or schedule UI work.
/// Device-mode start may implicitly activate the session; the host sets its policy first.
public final class SessionAudioEngine {
    private let engine: AVAudioEngine
    private let start: (AVAudioEngine) throws -> Void
    private let notificationCenter: NotificationCenter
    private let outputFormat: (AVAudioEngine) -> AVAudioFormat?
    private var worker: SessionPreparationWorker?
    private var source: SessionAudioSource?
    private var finalPosition: UInt32 = 0
    private var finalSourceStatus = SessionAudioSourceStatus.ready
    private var finalPreparationError: (any Error)?

    public let frameCount: UInt32
    public private(set) var playbackError: (any Error)?

    public convenience init(worker: SessionPreparationWorker) throws {
        try self.init(worker: worker, engine: AVAudioEngine())
    }

    // An injected engine must be fresh and stopped. Tests configure offline mode before
    // adoption and serialize manual pulls with controls; the public graph cannot escape.
    init(
        worker: SessionPreparationWorker, engine: AVAudioEngine,
        start: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
        notificationCenter: NotificationCenter = .default,
        outputFormat: ((AVAudioEngine) -> AVAudioFormat?)? = nil
    ) throws {
        do {
            let readOutput = outputFormat ?? Self.currentOutputFormat
            let connection = try Self.connectionFormat(readOutput(engine))
            let source = try SessionAudioSource(worker: worker)
            self.engine = engine
            self.start = start
            self.notificationCenter = notificationCenter
            self.outputFormat = readOutput
            self.worker = worker
            self.source = source
            frameCount = source.frameCount
            // All throwing setup precedes attachment. The source keeps its fixed 32 kHz
            // render format; its connection performs conversion to this output rate.
            engine.attach(source.node)
            engine.connect(source.node, to: engine.mainMixerNode, format: connection)
            worker.suspend()
        } catch {
            engine.stop()
            worker.requestStop()
            worker.join()
            throw error
        }
    }

    deinit { stop() }

    private static func currentOutputFormat(_ engine: AVAudioEngine) -> AVAudioFormat? {
        engine.isInManualRenderingMode
            ? engine.manualRenderingFormat : engine.outputNode.inputFormat(forBus: 0)
    }

    private static func connectionFormat(_ output: AVAudioFormat?) throws -> AVAudioFormat {
        guard let output, output.sampleRate.isFinite, output.sampleRate > 0,
            output.channelCount > 0,
            let connection = AVAudioFormat(
                standardFormatWithSampleRate: output.sampleRate, channels: 2)
        else { throw SessionAudioEngineError.outputUnavailable }
        return connection
    }

    // Control-context only. Preserve the source, worker, and canonical cursor; reconnecting
    // may discard converter-prefetched output. An unavailable format leaves the old
    // connection attached and the owner paused so an explicit Play can retry later.
    func reconfigureOutput() throws {
        guard let source, let worker else { throw SessionAudioEngineError.stopped }
        engine.stop()
        worker.suspend()
        let connection = try Self.connectionFormat(outputFormat(engine))
        engine.disconnectNodeOutput(source.node)
        engine.connect(source.node, to: engine.mainMixerNode, format: connection)
    }

    // The notification arrives on an internal engine queue. Its receiver may only enqueue
    // control work; neither graph mutation nor final engine release belongs in this block.
    func observeConfigurationChanges(
        _ receive: @escaping @Sendable () -> Void
    ) -> PlaybackAudioSessionObservation {
        let token = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in receive() }
        let registration = ConfigurationRegistration(center: notificationCenter, token: token)
        return PlaybackAudioSessionObservation { registration.remove() }
    }

    private final class ConfigurationRegistration: @unchecked Sendable {
        let center: NotificationCenter
        let token: NSObjectProtocol

        init(center: NotificationCenter, token: NSObjectProtocol) {
            self.center = center
            self.token = token
        }

        func remove() { center.removeObserver(token) }
    }

    /// Graph state, independent of source EOF/fault and preparation acknowledgment.
    public var state: SessionAudioEngineState {
        guard source != nil else { return .stopped }
        return engine.isRunning ? .playing : .paused
    }

    /// Generated canonical frames, not the audible device playhead. Snapshots survive stop.
    public var position: UInt32 { source?.position ?? finalPosition }
    public var sourceStatus: SessionAudioSourceStatus { source?.status ?? finalSourceStatus }
    public var preparationStatus: PreparationWorkerStatus { worker?.status ?? .stopped }
    public var preparationError: (any Error)? { worker?.lastError ?? finalPreparationError }

    /// Explicitly start/resume the same source and converter state. A start failure is
    /// terminal and rethrown after cleanup; callbacks may have advanced before failure.
    public func play() throws {
        guard let worker else { throw SessionAudioEngineError.stopped }
        guard !engine.isRunning else { return }
        worker.resume()
        do {
            try start(engine)
        } catch {
            playbackError = error
            stop()
            throw error
        }
    }

    /// Pauses output before requesting cooperative preparation suspension. Observe
    /// preparationStatus for acknowledgment without blocking the main thread.
    public func pause() {
        guard let worker else { return }
        engine.pause()
        worker.suspend()
    }

    /// Preserve explicit error recovery; suspended/stopped preparation rejects retry.
    @discardableResult
    public func retryPreparation() -> Bool { worker?.retry() ?? false }

    /// Terminal and idempotent. Stop the graph before joining preparation, then detach and
    /// release both owners off the callback. EOF alone does not establish converter drain.
    public func stop() {
        guard let source, let worker else { return }
        engine.stop()
        worker.requestStop()
        worker.join()
        finalPosition = source.position
        finalSourceStatus = source.status
        finalPreparationError = worker.lastError
        engine.disconnectNodeOutput(source.node)
        engine.detach(source.node)
        self.source = nil
        self.worker = nil
    }
}
