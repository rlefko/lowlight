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
        start: @escaping (AVAudioEngine) throws -> Void = { try $0.start() }
    ) throws {
        do {
            let output =
                engine.isInManualRenderingMode
                ? engine.manualRenderingFormat : engine.outputNode.inputFormat(forBus: 0)
            guard output.sampleRate.isFinite, output.sampleRate > 0, output.channelCount > 0,
                let connection = AVAudioFormat(
                    standardFormatWithSampleRate: output.sampleRate, channels: 2)
            else { throw SessionAudioEngineError.outputUnavailable }
            let source = try SessionAudioSource(worker: worker)
            self.engine = engine
            self.start = start
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
