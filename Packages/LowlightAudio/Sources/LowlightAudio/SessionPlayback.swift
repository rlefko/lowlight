// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Observation

public enum SessionPlaybackState: Sendable {
    case idle, preparing, playing, paused, stopping, stopped, failed
}

public enum SessionPlaybackCommand: Sendable { case play, pause, toggle, next }

/// A synchronous, weak command capability. Remote handlers use the same bounded mailbox
/// as the facade; no main-actor hop can turn a pre-reset command into new permission.
public struct SessionPlaybackCommandInput: Sendable {
    private let submit: @Sendable (SessionPlaybackCommand) -> Bool
    fileprivate init(_ submit: @escaping @Sendable (SessionPlaybackCommand) -> Bool) {
        self.submit = submit
    }
    @discardableResult public func send(_ command: SessionPlaybackCommand) -> Bool {
        submit(command)
    }
}

/// Main-actor intent for a session. Construction is silent and lazy. Commands
/// coalesce; state acknowledges completed control work, not an audible device playhead.
/// Stop is terminal. On iOS, one host-owned device coordinator manages the shared playback
/// audio session; other app components must not independently change that session's policy.
/// Pause/Stop cannot interrupt a start already executing; it is reconciled before their
/// acknowledgment. Position/errors refresh on commands or explicit refresh, without polling.
@MainActor @Observable
public final class SessionPlayback {
    public private(set) var state = SessionPlaybackState.idle
    public private(set) var isInterrupted = false
    /// False between media-services loss and reset. Reset never grants playback permission.
    public private(set) var mediaServicesAvailable = true
    public private(set) var lastError: (any Error)?
    /// A failed deactivation leaves cleanup unconfirmed, not proof that the session is active.
    /// Repeated Stop retries cleanup; playback/activation failures remain in lastError.
    public private(set) var audioSessionError: (any Error)?
    public private(set) var position: UInt64 = 0
    public private(set) var requestedPlayback = false
    public private(set) var listeningSnapshot: SessionListeningSnapshot?
    public var commandInput: SessionPlaybackCommandInput {
        SessionPlaybackCommandInput { [weak control] command in
            control?.submit(command) ?? false
        }
    }
    public private(set) var sourceStatus = SessionAudioSourceStatus.ready
    public private(set) var preparationStatus = PreparationWorkerStatus.stopped
    @ObservationIgnored private let control: PlaybackControl

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

    /// Continuous listening. A saved musical position warms a fresh current-song prefix;
    /// predecessor tails and prior session-protector history are not restored.
    public convenience init(
        bankURL: URL, seed: UInt64 = 91_031, controls: Controls = Controls(),
        restart: SessionRestartIntent? = nil
    ) {
        self.init(audioSession: .system, restart: restart) { token, prepareOutput, latest in
            try token.check()
            let preparer = try TonalSamplePreparer(bankURL: bankURL)
            let worker = try SessionPreparationWorker(
                seed: seed, controls: controls, restart: latest,
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
    convenience init(
        audioSession: PlaybackAudioSession,
        factory:
            @escaping @Sendable (PreparationCancellation, () throws -> Void) throws
            -> SessionAudioEngine
    ) {
        self.init(audioSession: audioSession, restart: nil) { token, prepareOutput, _ in
            try factory(token, prepareOutput)
        }
    }

    init(
        audioSession: PlaybackAudioSession, restart: SessionRestartIntent?,
        factory:
            @escaping @Sendable (PreparationCancellation, () throws -> Void, SessionRestartIntent?)
            throws -> SessionAudioEngine
    ) {
        control = PlaybackControl(audioSession: audioSession, restart: restart, factory: factory)
        control.setReceiver { [weak self] snapshot in
            guard let self else { return }
            self.state = snapshot.state
            self.isInterrupted = snapshot.interrupted
            self.mediaServicesAvailable = snapshot.mediaServicesAvailable
            self.lastError = snapshot.error
            self.audioSessionError = snapshot.audioSessionError
            self.position = snapshot.position
            self.requestedPlayback = snapshot.requestedPlayback
            self.listeningSnapshot = snapshot.listening
            self.sourceStatus = snapshot.source
            self.preparationStatus = snapshot.preparation
        }
    }

    deinit { control.request(.stop) }

    /// Explicit Play also retries a failed startup or an interruption with no end event.
    /// After media reset, a fresh Play rebuilds audio objects from the factory. The last
    /// captured musical position feeds continuous reconstruction; prior effect history is absent.
    /// Activation may still fail if the session is unavailable; a retained graph is not rewound.
    public func play() { _ = commandInput.send(.play) }
    public func pause() { _ = commandInput.send(.pause) }
    public func next() { _ = commandInput.send(.next) }
    public func stop() {
        control.request(.stop)
        if state != .stopped { state = .stopping }
    }

    /// On-demand snapshots only: no timer, automatic EOF stop, or converter-drain claim.
    public func refresh() { control.request(.refresh) }
    public func requestCapture() { control.request(.capture) }

    /// Retry a latched successor error only; never creates a session or resumes output.
    public func retryPreparation() { control.request(.retry) }

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
    let interrupted: Bool
    let mediaServicesAvailable: Bool
    let error: (any Error)?
    let audioSessionError: (any Error)?
    let requestedPlayback: Bool
    let listening: SessionListeningSnapshot?
    let position: UInt64
    let source: SessionAudioSourceStatus
    let preparation: PreparationWorkerStatus
}

/// Only the mailbox/delivery fields cross threads, under lock. The engine, failure and
/// final diagnostics belong exclusively to queue. Neither callback nor main actor joins.
private final class PlaybackControl: @unchecked Sendable {
    enum Action { case play, pause, toggle, next, stop, refresh, capture, retry }
    private enum Intent { case play, pause, stop }
    private struct SupersededOutput: Error {}
    private struct Command {
        var intent = Intent.pause
        var revision: UInt64 = 0
        var playRequest: UInt64 = 0
        var interruption: UInt64 = 0
        var configuration: UInt64 = 0
        var mediaGeneration: UInt64 = 0
        var mediaServicesAvailable = true
        var interrupted = false
        var routePaused = false
        var retry = false
        var capture = false
        var nextSelection: UInt64?
    }
    private let queue = DispatchQueue(
        label: "Lowlight.SessionPlayback", qos: .default, autoreleaseFrequency: .workItem)
    private let factory:
        @Sendable (PreparationCancellation, () throws -> Void, SessionRestartIntent?) throws
            -> SessionAudioEngine
    private let audioSession: PlaybackAudioSession
    private let lock = NSLock()
    private var command = Command()
    private var drainScheduled = false
    private var startup: PreparationCancellation?
    private var receiver: (@MainActor @Sendable (PlaybackSnapshot) -> Void)?
    private var deliveryScheduled = false
    private var pendingSnapshot: PlaybackSnapshot?
    private var observedEngine: UInt64?
    private var completedStopRevision: UInt64?
    private var eligibleSelection: UInt64?
    private var engine: SessionAudioEngine?
    private var observation: PlaybackAudioSessionObservation?
    private var configurationObservation: PlaybackAudioSessionObservation?
    private var listeningObservation: PlaybackAudioSessionObservation?
    private var nextEngine: UInt64 = 0
    private var quiescedConfiguration: UInt64?
    private var preparedConfiguration: UInt64?
    private var appliedMediaGeneration: UInt64 = 0
    private var failure: (any Error)?
    private var failedPlayRequest: UInt64?
    private var appliedPlayRequest: UInt64?
    private var appliedPauseRequest: UInt64 = 0
    private var position: UInt64 = 0
    private var listening: SessionListeningSnapshot?
    private var latestRestart: SessionRestartIntent?
    private var source = SessionAudioSourceStatus.ready
    // This records an outstanding cleanup obligation, not the system's current activity.
    private var outputCleanupGeneration: UInt64?
    private var cleanupAttempt: UInt64?
    private var audioSessionError: (any Error)?

    init(
        audioSession: PlaybackAudioSession, restart: SessionRestartIntent?,
        factory:
            @escaping @Sendable (PreparationCancellation, () throws -> Void, SessionRestartIntent?)
            throws -> SessionAudioEngine
    ) {
        self.audioSession = audioSession
        self.factory = factory
        latestRestart = restart
    }

    func setReceiver(_ receiver: @escaping @MainActor @Sendable (PlaybackSnapshot) -> Void) {
        lock.withLock { self.receiver = receiver }
    }

    func submit(_ action: SessionPlaybackCommand) -> Bool {
        switch action {
        case .play: request(.play)
        case .pause: request(.pause)
        case .toggle: request(.toggle)
        case .next: request(.next)
        }
    }

    @discardableResult
    func request(_ action: Action) -> Bool {
        lock.withLock {
            guard command.intent != .stop || action == .stop else { return false }
            let action =
                action == .toggle ? (command.intent == .play ? Action.pause : .play) : action
            if action == .play && !command.mediaServicesAvailable { return false }
            if action == .next {
                guard command.mediaServicesAvailable, let selection = eligibleSelection,
                    observedEngine != nil
                else { return false }
                command.nextSelection = command.nextSelection ?? selection
            }
            command.revision &+= 1
            switch action {
            case .play:
                command.intent = .play
                command.playRequest &+= 1
                command.interrupted = false
                command.routePaused = false
            case .pause:
                command.intent = .pause
                command.interruption &+= 1
            case .stop:
                command.intent = .stop
                command.interruption &+= 1
                command.interrupted = false
                command.nextSelection = nil
            case .capture: command.capture = true
            case .retry: command.retry = true
            case .refresh, .next, .toggle: break
            }
            if command.intent != .play || command.interrupted || !command.mediaServicesAvailable {
                startup?.cancel()
            }
            scheduleDrain()
            return true
        }
    }

    // Runs synchronously on the notification's posting thread: invalidate setup before
    // returning, but perform no engine/session work or main-actor delivery here.
    private func receive(_ event: PlaybackAudioSessionEvent) {
        lock.withLock {
            guard command.intent != .stop || completedStopRevision != command.revision else {
                return
            }
            switch event {
            case .mediaServicesLost, .mediaServicesReset:
                let available: Bool
                if case .mediaServicesReset = event { available = true } else { available = false }
                guard available || command.mediaServicesAvailable else { return }
                command.mediaGeneration &+= 1
                command.mediaServicesAvailable = available
                startup?.cancel()
                observedEngine = nil
                // A notification racing terminal cleanup still invalidates old activation;
                // it cannot enqueue new work or resurrect the terminal owner.
                guard command.intent != .stop else { return }
                command.intent = .pause
                command.interrupted = false
                command.routePaused = false
                command.retry = false
                command.nextSelection = nil
                command.interruption &+= 1
            case .interruptionBegan:
                guard command.intent != .stop else { return }
                guard !command.interrupted else { return }
                command.interrupted = true
                // A route-disconnect begin can follow its route event synchronously.
                // That route already invalidated setup; do not retry the same cleanup.
                if !command.routePaused { command.interruption &+= 1 }
            case .interruptionEnded(let shouldResume):
                guard command.intent != .stop else { return }
                guard command.interrupted else { return }
                command.interrupted = false
                if !shouldResume { command.intent = .pause }
            case .oldDeviceUnavailable:
                guard command.intent != .stop else { return }
                guard !command.routePaused else { return }
                command.routePaused = true
                command.intent = .pause
                command.interruption &+= 1
            }
            command.revision &+= 1
            if command.intent != .play || command.interrupted || !command.mediaServicesAvailable {
                startup?.cancel()
            }
            scheduleDrain()
        }
    }

    private func receiveConfiguration(from generation: UInt64) {
        lock.withLock {
            guard command.intent != .stop, observedEngine == generation else { return }
            command.configuration &+= 1
            command.revision &+= 1
            scheduleDrain()
        }
    }

    private func receiveListening(from generation: UInt64) {
        lock.withLock {
            guard command.intent != .stop, observedEngine == generation else { return }
            command.revision &+= 1
            scheduleDrain()
        }
    }

    // Caller holds lock. One queued drain serves both controls and notification bursts.
    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        // Pins the backend through cleanup even if the main-actor facade dies.
        queue.async(qos: .default, flags: .enforceQoS) { self.drain() }
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
        if appliedMediaGeneration != current.mediaGeneration {
            disposeEngine()
            discardOutputObligation()
            appliedMediaGeneration = current.mediaGeneration
            appliedPlayRequest = nil
        }
        if current.intent == .stop {
            observation?.cancel()
            observation = nil
            disposeEngine()
            releaseOutput()
            lock.withLock {
                // Close the gap between deactivation's result check and terminal acknowledgment.
                if let generation = outputCleanupGeneration, generation != command.mediaGeneration {
                    discardOutputObligation()
                }
                completedStopRevision = current.revision
            }
            return snapshot(.stopped, current.revision)
        }
        if engine?.sourceStatus == .failed
            || (engine?.preparationError as? PreparationWorkerError) == .renderFailed
        {
            record(PreparationWorkerError.renderFailed, for: current)
            disposeEngine()
            releaseOutput()
            return snapshot(.failed, current.revision)
        }
        let requests = lock.withLock { () -> (Bool, UInt64?) in
            guard command.revision == current.revision else { return (false, nil) }
            let result = (command.capture, command.nextSelection)
            command.capture = false
            command.nextSelection = nil
            return result
        }
        if requests.0 { engine?.requestCapture() }
        if let selection = requests.1, engine?.listeningSnapshot?.selectionID == selection {
            engine?.requestNext()
        }
        if observation == nil, current.intent == .play {
            observation = audioSession.observe { [weak self] in self?.receive($0) }
        }
        // Quiesce every new pause generation even if begin/end or Pause/Play coalesced.
        if appliedPauseRequest != current.interruption {
            engine?.pause()
            releaseOutput()
            appliedPauseRequest = current.interruption
            appliedPlayRequest = nil
        }
        if engine != nil, quiescedConfiguration != current.configuration {
            engine?.pause()
            quiescedConfiguration = current.configuration
        }
        let retry =
            current.retry
            && lock.withLock {
                guard command.revision == current.revision else { return false }
                command.retry = false
                return true
            }
        if current.intent == .pause || current.interrupted || !current.mediaServicesAvailable {
            let state: SessionPlaybackState =
                engine?.state == .playing
                ? .playing
                : (current.playRequest == 0 && current.interruption == 0 ? .idle : .paused)
            return snapshot(state, current.revision)
        }
        // Configuration notifications and matched interruption ends do not retry errors.
        // A retained owner with unavailable output can recover on a new explicit Play.
        if failedPlayRequest == current.playRequest {
            return snapshot(.failed, current.revision)
        }
        var freshOutput = false
        if engine == nil {
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
                let candidate = try factory(
                    token, { try self.prepareOutput(for: current, token: token) }, latestRestart)
                let cancelled = lock.withLock {
                    startup = nil
                    return token.isCancelled
                }
                if cancelled {
                    candidate.stop()
                    retainListening(from: candidate)
                    releaseOutput()
                    return nil
                }
                engine = candidate
                nextEngine &+= 1
                let generation = nextEngine
                lock.withLock { observedEngine = generation }
                quiescedConfiguration = current.configuration
                configurationObservation = candidate.observeConfigurationChanges { [weak self] in
                    self?.receiveConfiguration(from: generation)
                }
                listeningObservation = candidate.observeListeningChanges { [weak self] in
                    self?.receiveListening(from: generation)
                }
                // Re-read the current output after registration, covering changes between
                // graph construction and installation of its engine-specific observer.
                preparedConfiguration = nil
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
        guard latest.intent == .play, !latest.interrupted, latest.mediaServicesAvailable,
            latest.mediaGeneration == appliedMediaGeneration,
            latest.interruption == appliedPauseRequest,
            latest.configuration == quiescedConfiguration
        else { return nil }
        do {
            // Refresh/retry alone cannot authorize a start. An eligible configuration
            // recovery preserves the same user intent and never advances playRequest.
            let reconfigure = preparedConfiguration != latest.configuration
            if appliedPlayRequest != latest.playRequest || reconfigure {
                appliedPlayRequest = latest.playRequest
                failure = nil
                if !freshOutput, engine?.state != .playing {
                    try prepareOutput(for: latest)
                }
                try checkOutputIntent(latest)
                if reconfigure {
                    do {
                        try engine?.reconfigureOutput()
                        preparedConfiguration = latest.configuration
                    } catch SessionAudioEngineError.outputUnavailable {
                        record(SessionAudioEngineError.outputUnavailable, for: latest)
                        releaseOutput()
                        return snapshot(.failed, latest.revision)
                    }
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
                command.intent == .play && !command.interrupted && command.mediaServicesAvailable
                    && command.mediaGeneration == operation.mediaGeneration
                    && command.interruption == operation.interruption
                    && command.configuration == operation.configuration
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
        outputCleanupGeneration = operation.mediaGeneration
        try audioSession.activate()
        audioSessionError = nil
        try checkOutputIntent(operation, token: token)
    }

    private func releaseOutput() {
        let current = lock.withLock { command }
        guard let generation = outputCleanupGeneration else { return }
        guard generation == current.mediaGeneration else {
            discardOutputObligation()
            return
        }
        guard cleanupAttempt != current.interruption else { return }
        cleanupAttempt = current.interruption
        var deactivationError: (any Error)?
        do { try audioSession.deactivate() } catch { deactivationError = error }
        // A reset may arrive inside an already-admitted deactivation, including during Stop.
        guard generation == lock.withLock({ command.mediaGeneration }) else {
            discardOutputObligation()
            return
        }
        if let deactivationError {
            audioSessionError = deactivationError
        } else {
            outputCleanupGeneration = nil
            audioSessionError = nil
        }
    }

    private func discardOutputObligation() {
        // The old media server's activation is obsolete, not successfully deactivated.
        outputCleanupGeneration = nil
        cleanupAttempt = nil
        audioSessionError = nil
    }

    private func record(_ error: any Error, for operation: Command) {
        let latest = lock.withLock { command }
        guard latest.mediaGeneration == operation.mediaGeneration else { return }
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
        lock.withLock {
            observedEngine = nil
            eligibleSelection = nil
        }
        listeningObservation?.cancel()
        listeningObservation = nil
        configurationObservation?.cancel()
        configurationObservation = nil
        quiescedConfiguration = nil
        preparedConfiguration = nil
        if let engine {
            engine.stop()
            position = engine.position
            source = engine.sourceStatus
            retainListening(from: engine)
            failure =
                failure ?? engine.preparationError
                ?? (source == .failed ? PreparationWorkerError.renderFailed : nil)
        }
        engine = nil
    }

    private func retainListening(from engine: SessionAudioEngine) {
        if let value = engine.listeningSnapshot {
            listening = value
            latestRestart = value.restart
        }
    }

    private func snapshot(_ state: SessionPlaybackState, _ revision: UInt64) -> PlaybackSnapshot {
        if let engine { retainListening(from: engine) }
        lock.withLock { eligibleSelection = engine != nil ? listening?.selectionID : nil }
        return PlaybackSnapshot(
            revision: revision, state: state,
            interrupted: lock.withLock { command.interrupted },
            mediaServicesAvailable: lock.withLock { command.mediaServicesAvailable },
            error: failure ?? engine?.preparationError
                ?? (engine?.sourceStatus == .failed ? PreparationWorkerError.renderFailed : nil),
            audioSessionError: audioSessionError,
            requestedPlayback: lock.withLock { command.intent == .play }, listening: listening,
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
                    let receiver = value?.revision == self.command.revision ? self.receiver : nil
                    return (value, receiver)
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
