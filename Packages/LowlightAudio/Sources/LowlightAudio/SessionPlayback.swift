// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Observation

public enum SessionPlaybackState: Sendable {
    case idle, preparing, playing, paused, stopping, stopped, failed
}

/// Main-actor intent for one finite session. Construction is silent and lazy. Commands
/// coalesce; state acknowledges completed control work, not an audible device playhead.
/// Stop is terminal. On iOS, one host-owned device coordinator manages the shared playback
/// audio session; other app components must not independently change that session's policy.
/// Pause/Stop cannot interrupt a start already executing; it is reconciled before their
/// acknowledgment. Position/errors refresh on commands or explicit refresh, without polling.
@MainActor @Observable
public final class SessionPlayback {
    public private(set) var state = SessionPlaybackState.idle
    public private(set) var lastError: (any Error)?
    /// A failed deactivation leaves cleanup unconfirmed, not proof that the session is active.
    /// Repeated Stop retries cleanup; playback/activation failures remain in lastError.
    public private(set) var audioSessionError: (any Error)?
    public private(set) var position: UInt32 = 0
    public private(set) var sourceStatus = SessionAudioSourceStatus.ready
    public private(set) var preparationStatus = PreparationWorkerStatus.stopped
    @ObservationIgnored private let control: PlaybackControl
    @ObservationIgnored private var revision: UInt64 = 0

    public convenience init(
        bankURL: URL, seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32
    ) {
        self.init(audioSession: .system) { token, prepareOutput in
            try token.check()
            let preparer = try TonalSamplePreparer(bankURL: bankURL)
            try token.check()
            let worker = try SessionPreparationWorker(
                seed: seed, controls: controls, frameCount: frameCount,
                preparer: preparer, cancellation: token)
            do {
                try prepareOutput()
                try token.check()
                return try SessionAudioEngine(worker: worker)
            } catch {
                worker.requestStop()
                worker.join()
                throw error
            }
        }
    }

    // Tests supply a fresh, paused real owner/offline graph; no alternate playback protocol.
    convenience init(
        factory: @escaping @Sendable (PreparationCancellation) throws -> SessionAudioEngine
    ) {
        self.init(audioSession: .unmanaged) { token, prepareOutput in
            try prepareOutput()
            return try factory(token)
        }
    }

    // The synchronous factory calls prepareOutput exactly once, after preparing its worker
    // and before constructing the graph. If it throws, the factory stops/joins that worker.
    init(
        audioSession: PlaybackAudioSession,
        factory:
            @escaping @Sendable (PreparationCancellation, () throws -> Void) throws
            -> SessionAudioEngine
    ) {
        control = PlaybackControl(audioSession: audioSession, factory: factory)
        control.setReceiver { [weak self] snapshot in
            guard let self, snapshot.revision == self.revision else { return }
            self.state = snapshot.state
            self.lastError = snapshot.error
            self.audioSessionError = snapshot.audioSessionError
            self.position = snapshot.position
            self.sourceStatus = snapshot.source
            self.preparationStatus = snapshot.preparation
        }
    }

    deinit { control.request(.stop) }

    /// Explicit Play also retries a failed startup. It does not rewind an existing graph.
    public func play() { revision = control.request(.play) }
    public func pause() { revision = control.request(.pause) }
    public func stop() {
        revision = control.request(.stop)
        if state != .stopped { state = .stopping }
    }

    /// On-demand snapshots only: no timer, automatic EOF stop, or converter-drain claim.
    public func refresh() { revision = control.request(.refresh) }

    /// Retry a latched successor error only; never creates a session or resumes output.
    public func retryPreparation() { revision = control.request(.retry) }

    // Manual offline pulls/inspection must share the engine's serialized control context.
    func inspect<Value: Sendable>(
        _ body: @escaping @Sendable (SessionAudioEngine?) throws -> Value
    ) async throws -> Value {
        try await control.inspect(body)
    }
}

private struct PlaybackSnapshot: Sendable {
    let revision: UInt64
    let state: SessionPlaybackState
    let error: (any Error)?
    let audioSessionError: (any Error)?
    let position: UInt32
    let source: SessionAudioSourceStatus
    let preparation: PreparationWorkerStatus
}

/// Only the mailbox/delivery fields cross threads, under lock. The engine, failure and
/// final diagnostics belong exclusively to queue. Neither callback nor main actor joins.
private final class PlaybackControl: @unchecked Sendable {
    enum Action { case play, pause, stop, refresh, retry }
    private enum Intent { case play, pause, stop }
    private struct SupersededOutput: Error {}
    private struct Command {
        var intent = Intent.pause
        var revision: UInt64 = 0
        var playRequest: UInt64 = 0
        var interruption: UInt64 = 0
        var retry = false
    }
    private let queue = DispatchQueue(
        label: "Lowlight.SessionPlayback", qos: .default, autoreleaseFrequency: .workItem)
    private let factory:
        @Sendable (PreparationCancellation, () throws -> Void) throws
            -> SessionAudioEngine
    private let audioSession: PlaybackAudioSession
    private let lock = NSLock()
    private var command = Command()
    private var drainScheduled = false
    private var startup: PreparationCancellation?
    private var receiver: (@MainActor @Sendable (PlaybackSnapshot) -> Void)?
    private var deliveryScheduled = false
    private var pendingSnapshot: PlaybackSnapshot?
    private var engine: SessionAudioEngine?
    private var failure: (any Error)?
    private var failedPlayRequest: UInt64?
    private var appliedPlayRequest: UInt64 = 0
    private var appliedPauseRequest: UInt64 = 0
    private var position: UInt32 = 0
    private var source = SessionAudioSourceStatus.ready
    // This records an outstanding cleanup obligation, not the system's current activity.
    private var outputCleanupPending = false
    private var cleanupAttempt: UInt64?
    private var audioSessionError: (any Error)?

    init(
        audioSession: PlaybackAudioSession,
        factory:
            @escaping @Sendable (PreparationCancellation, () throws -> Void) throws
            -> SessionAudioEngine
    ) {
        self.audioSession = audioSession
        self.factory = factory
    }

    func setReceiver(_ receiver: @escaping @MainActor @Sendable (PlaybackSnapshot) -> Void) {
        lock.withLock { self.receiver = receiver }
    }

    @discardableResult
    func request(_ action: Action) -> UInt64 {
        lock.withLock {
            guard command.intent != .stop || action == .stop else { return command.revision }
            command.revision &+= 1
            switch action {
            case .play:
                command.intent = .play
                command.playRequest &+= 1
            case .pause:
                command.intent = .pause
                command.interruption &+= 1
            case .stop:
                command.intent = .stop
                command.interruption &+= 1
            case .refresh: break
            case .retry: command.retry = true
            }
            if command.intent != .play { startup?.cancel() }
            if !drainScheduled {
                drainScheduled = true
                // Pins the backend through cleanup even if the main-actor facade dies.
                queue.async(qos: .default, flags: .enforceQoS) { self.drain() }
            }
            return command.revision
        }
    }

    private func drain() {
        while true {
            let current = lock.withLock { command }
            // Drain Objective-C temporaries before publishing cleanup acknowledgment.
            let result = autoreleasepool { reconcile(current) }
            if let result { publish(result) }
            let finished = lock.withLock {
                guard command.revision == current.revision else { return false }
                drainScheduled = false
                return true
            }
            if finished { return }
        }
    }

    private func reconcile(_ current: Command) -> PlaybackSnapshot? {
        if current.intent == .stop {
            disposeEngine()
            releaseOutput()
            return snapshot(.stopped, current.revision)
        }
        let retry =
            current.retry
            && lock.withLock {
                guard command.revision == current.revision else { return false }
                command.retry = false
                return true
            }
        if current.intent == .pause {
            if appliedPauseRequest != current.interruption {
                engine?.pause()
                releaseOutput()
                appliedPauseRequest = current.interruption
            }
            let state: SessionPlaybackState =
                engine?.state == .playing
                ? .playing
                : (current.playRequest == 0 && current.interruption == 0 ? .idle : .paused)
            return snapshot(state, current.revision)
        }
        var freshOutput = false
        if engine == nil {
            if failedPlayRequest == current.playRequest {
                return snapshot(.failed, current.revision)
            }
            let token = PreparationCancellation()
            let accepted = lock.withLock {
                guard command.revision == current.revision else { return false }
                startup = token
                return true
            }
            guard accepted else { return nil }
            failure = nil
            publish(snapshot(.preparing, current.revision))
            do {
                let candidate = try factory(token) {
                    try self.prepareOutput(for: current, token: token)
                }
                let cancelled = lock.withLock {
                    startup = nil
                    return token.isCancelled
                }
                if cancelled {
                    candidate.stop()
                    releaseOutput()
                    return nil
                }
                engine = candidate
                freshOutput = true
            } catch {
                lock.withLock { startup = nil }
                releaseOutput()
                if error is SupersededOutput || (error is CancellationError && token.isCancelled) {
                    return nil
                }
                record(error, for: current)
                return snapshot(.failed, current.revision)
            }
        }
        // A factory may finish after Pause/Stop. Do not start that obsolete result.
        let latest = lock.withLock { command }
        guard latest.intent == .play else { return nil }
        do {
            // Refresh/retry must not restart a graph paused by a device interruption.
            // Only an explicit, unapplied Play is permission to start/resume output.
            if appliedPlayRequest != latest.playRequest {
                appliedPlayRequest = latest.playRequest
                if !freshOutput, engine?.state != .playing {
                    try prepareOutput(for: latest)
                }
                try checkOutputIntent(latest)
                try engine?.play()
            }
            if retry { engine?.retryPreparation() }
            return snapshot(engine?.state == .playing ? .playing : .paused, latest.revision)
        } catch {
            if error is SupersededOutput {
                engine?.pause()
                releaseOutput()
                return nil
            }
            record(error, for: latest)
            disposeEngine()
            releaseOutput()
            return snapshot(.failed, latest.revision)
        }
    }

    private func checkOutputIntent(
        _ operation: Command, token: PreparationCancellation? = nil
    ) throws {
        try token?.check()
        guard
            lock.withLock({
                command.intent == .play && command.interruption == operation.interruption
            })
        else { throw SupersededOutput() }
    }

    private func prepareOutput(
        for operation: Command, token: PreparationCancellation? = nil
    ) throws {
        try checkOutputIntent(operation, token: token)
        cleanupAttempt = nil
        try audioSession.configure()
        try checkOutputIntent(operation, token: token)
        // Activation can fail after changing system state. Always attempt cleanup after
        // an activation attempt; a configure-only failure creates no new obligation.
        outputCleanupPending = true
        try audioSession.activate()
        audioSessionError = nil
        try checkOutputIntent(operation, token: token)
    }

    private func releaseOutput() {
        let request = lock.withLock { command.interruption }
        guard outputCleanupPending, cleanupAttempt != request else { return }
        cleanupAttempt = request
        do {
            try audioSession.deactivate()
            outputCleanupPending = false
            audioSessionError = nil
        } catch {
            audioSessionError = error
        }
    }

    private func record(_ error: any Error, for operation: Command) {
        let latest = lock.withLock { command }
        // Duplicate Play while an operation is pending is not an automatic retry. A
        // Pause→Play generation, however, must not inherit an obsolete startup failure.
        guard
            latest.playRequest == operation.playRequest
                || latest.interruption == operation.interruption
        else { return }
        failure = error
        failedPlayRequest = latest.playRequest
    }

    private func disposeEngine() {
        if let engine {
            engine.stop()
            position = engine.position
            source = engine.sourceStatus
            failure =
                failure ?? engine.preparationError
                ?? (source == .failed ? PreparationWorkerError.renderFailed : nil)
        }
        engine = nil
    }

    private func snapshot(_ state: SessionPlaybackState, _ revision: UInt64) -> PlaybackSnapshot {
        PlaybackSnapshot(
            revision: revision, state: state,
            error: failure ?? engine?.preparationError
                ?? (engine?.sourceStatus == .failed ? PreparationWorkerError.renderFailed : nil),
            audioSessionError: audioSessionError,
            position: engine?.position ?? position, source: engine?.sourceStatus ?? source,
            preparation: state == .preparing ? .preparing : (engine?.preparationStatus ?? .stopped))
    }

    private func publish(_ snapshot: PlaybackSnapshot) {
        lock.withLock {
            guard snapshot.revision == command.revision else { return }
            pendingSnapshot = snapshot
            guard !deliveryScheduled else { return }
            deliveryScheduled = true
            Task { @MainActor in
                let delivery = self.lock.withLock {
                    let value = self.pendingSnapshot
                    self.pendingSnapshot = nil
                    self.deliveryScheduled = false
                    return (value, self.receiver)
                }
                if let value = delivery.0 { delivery.1?(value) }
            }
        }
    }

    func inspect<Value: Sendable>(
        _ body: @escaping @Sendable (SessionAudioEngine?) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: .default, flags: .enforceQoS) {
                do { continuation.resume(returning: try body(self.engine)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
