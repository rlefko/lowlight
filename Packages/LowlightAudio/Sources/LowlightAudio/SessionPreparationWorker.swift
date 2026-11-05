// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

public enum PreparationWorkerStatus: Sendable {
    case running, preparing, waitingForRetry, suspended, stopped
}
public enum PreparationWorkerError: Error, Equatable {
    case threadUnavailable(Int32)
    case renderEndpointUnavailable, renderFailed
}

/// One dedicated preparation thread; rendering uses the existing independent endpoint.
/// Construction blocks until the initial pair is ready: call off the main/audio threads.
/// All control calls and final release belong off the callback. Stop/join only preparation;
/// separately stop/join the consumer and release its endpoint off the callback.
public final class SessionPreparationWorker: @unchecked Sendable {
    private final class Shared: @unchecked Sendable {
        let condition = NSCondition()
        // Every mutable field, including the owner's thread handle, uses this condition.
        var status = PreparationWorkerStatus.preparing
        var error: (any Error)?
        var initialFinished = false
        var stop = false
        var suspend = false
        var retry = false
        var joining = false
        var issued = false
        var token: PreparationCancellation?
        var cancelOnControls = false
        var controls: SessionControlsMailbox?
        var renderFailed: (@Sendable () -> Bool)?
        var captureRequested = false
        var nextSelection: UInt64?
        var listening: SessionListeningSnapshot?
        var observer: (@Sendable () -> Void)?
        var observation: UInt64 = 0
        var change: UInt64 = 0
        var delivered: UInt64 = 0

        func setStatus(_ value: PreparationWorkerStatus) {
            if status != value {
                status = value
                change &+= 1
            }
        }
        // Pins the session even after EOF/worker exit; those are not render-quiescence proofs.
        var endpoint: PreparedSession.RenderEndpoint?

        init(token: PreparationCancellation) { self.token = token }
    }

    private final class Invocation {
        let shared: Shared
        let prepare: @Sendable (PreparationCancellation) throws -> PreparedSession
        let makeCancellation: @Sendable () -> PreparationCancellation
        let initialControls: Controls?

        init(
            shared: Shared, makeCancellation: @escaping @Sendable () -> PreparationCancellation,
            initialControls: Controls?,
            prepare: @escaping @Sendable (PreparationCancellation) throws -> PreparedSession
        ) {
            self.shared = shared
            self.makeCancellation = makeCancellation
            self.initialControls = initialControls
            self.prepare = prepare
        }
    }

    private let shared: Shared
    private let initialControls: Controls?
    private var thread: pthread_t?

    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32,
        preparer: TonalSamplePreparer, cancellation: PreparationCancellation? = nil
    ) throws {
        try self.init(initialControls: controls, cancellation: cancellation) { token in
            try PreparedSession(
                seed: seed, controls: controls, frameCount: frameCount,
                preparation: .concurrent, preparer: preparer, cancellation: token)
        }
    }

    public convenience init(
        seed: UInt64 = 91_031, controls: Controls? = nil,
        restart: SessionRestartIntent? = nil, preparer: TonalSamplePreparer,
        cancellation: PreparationCancellation? = nil
    ) throws {
        let desired = try (controls ?? restart?.currentSong.controls ?? Controls()).normalized()
        try self.init(initialControls: desired, cancellation: cancellation) { token in
            try PreparedSession(
                seed: seed, controls: desired, restart: restart,
                preparer: preparer, cancellation: token)
        }
    }

    // Short-source/token-observer seams. Factories run only on the worker; token creation
    // must not block or call controls because it occurs inside the control lock.
    init(
        initialControls: Controls? = nil,
        cancellation: PreparationCancellation? = nil,
        makeCancellation: @escaping @Sendable () -> PreparationCancellation = {
            PreparationCancellation()
        },
        prepare: @escaping @Sendable (PreparationCancellation) throws -> PreparedSession
    ) throws {
        let token = cancellation ?? PreparationCancellation()
        shared = Shared(token: token)
        try token.check()
        let controls = try initialControls?.normalized()
        self.initialControls = controls
        let invocation = Unmanaged.passRetained(
            Invocation(
                shared: shared, makeCancellation: makeCancellation, initialControls: controls,
                prepare: prepare))
        let result = pthread_create(
            &thread, nil,
            { pointer in
                let work = Unmanaged<Invocation>.fromOpaque(pointer).takeRetainedValue()
                SessionPreparationWorker.run(work)
                return nil
            }, invocation.toOpaque())
        guard result == 0 else {
            invocation.release()
            thread = nil
            throw PreparationWorkerError.threadUnavailable(result)
        }
        shared.condition.lock()
        while !shared.initialFinished { shared.condition.wait() }
        let error = shared.error
        shared.condition.unlock()
        if let error {
            join()
            throw error
        }
    }

    deinit {
        requestStop()
        join()
    }

    /// Issue once on the control thread, then pin this endpoint for one render consumer.
    public func makeRenderEndpoint() throws -> PreparedSession.RenderEndpoint {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        guard !shared.stop, !shared.issued, let endpoint = shared.endpoint else {
            throw PreparationWorkerError.renderEndpointUnavailable
        }
        shared.issued = true
        return endpoint
    }

    public var status: PreparationWorkerStatus {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        return shared.status
    }

    /// One bounded error snapshot; explicit retry clears it. Stop cancellation is not an error.
    public var lastError: (any Error)? {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        return shared.error
    }

    // Installed during source setup. The weak atomic-only probe adds no callback work or
    // ownership cycle. A busy preparation attempt observes failure at its service boundary.
    func setRenderFailureProbe(_ probe: @escaping @Sendable () -> Bool) {
        shared.condition.lock()
        precondition(shared.renderFailed == nil)
        shared.renderFailed = probe
        shared.condition.broadcast()
        shared.condition.unlock()
    }

    /// Immutable musical metadata generated by the preparation owner, never the callback.
    public var listeningSnapshot: SessionListeningSnapshot? {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        return shared.listening
    }

    /// Retaining this capability never retains the worker or grants playback permission.
    public var controlsInput: SessionControlsInput {
        shared.condition.lock()
        let controls = shared.controls
        shared.condition.unlock()
        return SessionControlsInput(
            submit: { [weak controls] in controls?.send($0) ?? false },
            retry: { [weak controls] in controls?.retry() ?? false })
    }

    /// Revision zero identifies a finite source without live controls. Its known initial
    /// settings remain accurate; input submission and retry return false for that source.
    public var controlsSnapshot: SessionControlsSnapshot {
        shared.condition.lock()
        let controls = shared.controls
        shared.condition.unlock()
        return controls?.snapshot
            ?? SessionControlsSnapshot(
                requested: initialControls ?? Controls(), applied: initialControls ?? Controls(),
                revision: 0, appliedRevision: 0,
                state: .none)
    }

    public var controlsError: (any Error)? {
        shared.condition.lock()
        let controls = shared.controls
        shared.condition.unlock()
        return controls?.lastError
    }

    @discardableResult public func setControls(_ request: SessionControlsRequest) -> Bool {
        controlsInput.send(request)
    }
    @discardableResult public func retryControls() -> Bool { controlsInput.retry() }

    // Engine-only final capture. Joining preparation alone does not establish this proof:
    // the caller has already stopped the graph and now owns the quiescent session state.
    func captureAfterRenderStopped() {
        shared.condition.lock()
        precondition(thread == nil && shared.status == .stopped)
        let endpoint = shared.endpoint
        shared.condition.unlock()
        do {
            let snapshot = try endpoint?.captureAfterWorkerStopped()
            shared.condition.lock()
            if let snapshot { shared.listening = snapshot }
            shared.condition.unlock()
        } catch {
            shared.condition.lock()
            shared.error = shared.error ?? error
            shared.condition.unlock()
        }
    }

    /// Coalesces one capture, including while preparation is suspended. Engine stop performs
    /// a final capture after both render quiescence and worker join; worker join alone does not.
    public func requestCapture() {
        shared.condition.lock()
        shared.captureRequested = true
        shared.condition.broadcast()
        shared.condition.unlock()
    }

    @discardableResult
    public func requestNext() -> Bool {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        guard !shared.stop, let snapshot = shared.listening else { return false }
        if let pending = shared.nextSelection { return pending == snapshot.selectionID }
        guard snapshot.nextState == .none else { return true }
        shared.nextSelection = snapshot.selectionID
        shared.condition.broadcast()
        return true
    }

    // One semantic observer. The callback only enqueues control work; no engine access or
    // worker join occurs on this thread. Cancellation removes only its own registration.
    func observeChanges(_ receive: @escaping @Sendable () -> Void)
        -> PlaybackAudioSessionObservation
    {
        shared.condition.lock()
        shared.observation &+= 1
        let identity = shared.observation
        shared.observer = receive
        shared.condition.unlock()
        receive()
        return PlaybackAudioSessionObservation { [weak self] in
            guard let self else { return }
            self.shared.condition.lock()
            if self.shared.observation == identity { self.shared.observer = nil }
            self.shared.condition.unlock()
        }
    }

    /// Coalesces to one retry, and only while a failed successor attempt is latched.
    @discardableResult
    public func retry() -> Bool {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        guard !shared.stop, !shared.suspend, shared.error != nil, !shared.retry else {
            return false
        }
        shared.retry = true
        shared.condition.signal()
        return true
    }

    /// Cooperatively suspend preparation, preserving the session and any latched error.
    /// Returns whether a new request was accepted. `.suspended` acknowledges that the active
    /// attempt has unwound; a candidate past its final cancellation check may still succeed.
    /// This does not pause rendering. The host must separately quiesce its audio consumer.
    @discardableResult
    public func suspend() -> Bool {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        guard !shared.stop, !shared.suspend else { return false }
        shared.suspend = true
        shared.token?.cancel()
        shared.condition.broadcast()
        return true
    }

    /// Resume preparation of the same pending schedule with a fresh token after cancellation.
    /// A genuine preparation failure still requires explicit retry. Stop remains terminal.
    @discardableResult
    public func resume() -> Bool {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        guard !shared.stop, shared.suspend else { return false }
        shared.suspend = false
        // Concurrent join callers wait on this condition too; wake the worker as well.
        shared.condition.broadcast()
        return true
    }

    /// Terminal, cooperative request. A successor that passed its final check may be admitted.
    public func requestStop() {
        shared.condition.lock()
        shared.stop = true
        shared.captureRequested = true
        shared.token?.cancel()
        let controls = shared.controls
        shared.condition.broadcast()
        shared.condition.unlock()
        controls?.close()
    }

    /// Waits for this preparation thread, not the render consumer. Request stop first unless
    /// waiting for finite EOF/fault. Concurrent join callers share one actual pthread join.
    public func join() {
        shared.condition.lock()
        while shared.joining { shared.condition.wait() }
        guard let thread else {
            shared.condition.unlock()
            return
        }
        shared.joining = true
        shared.condition.unlock()
        let result = pthread_join(thread, nil)
        shared.condition.lock()
        self.thread = nil
        shared.joining = false
        shared.condition.broadcast()
        shared.condition.unlock()
        precondition(result == 0, "Preparation worker join failed")
    }

    private static func run(_ work: Invocation) {
        let state = work.shared
        do {
            state.condition.lock()
            let initialToken = state.token
            state.condition.unlock()
            guard let token = initialToken else { throw CancellationError() }
            let session = try autoreleasepool { try work.prepare(token) }
            try token.check()
            let endpoint = try session.makeRenderEndpoint()
            let initialSnapshot = try session.captureListeningSnapshot()
            let controls: SessionControlsMailbox?
            if let initialSnapshot {
                controls = try SessionControlsMailbox(
                    desired: work.initialControls ?? initialSnapshot.currentSong.controls,
                    applied: initialSnapshot.currentSong.controls
                ) { [weak state] invalidates in
                    guard let state else { return }
                    state.condition.lock()
                    guard !state.stop else {
                        state.condition.unlock()
                        return
                    }
                    if invalidates && state.cancelOnControls { state.token?.cancel() }
                    state.change &+= 1
                    state.condition.broadcast()
                    state.condition.unlock()
                    notify(state)
                }
                if let controls { session.installControls(controls) }
            } else {
                controls = nil
            }
            state.condition.lock()
            let cancelled = state.stop || token.isCancelled
            if !cancelled {
                state.endpoint = endpoint
                state.token = nil
                state.listening = initialSnapshot
                state.controls = controls
                state.setStatus(.running)
                state.initialFinished = true
                state.condition.broadcast()
            }
            state.condition.unlock()
            if cancelled { throw CancellationError() }
            service(session, work: work)
            // The graph owner stops the render consumer before requesting terminal stop.
            // An endpoint may still pin this session; the snapshot is retained separately.
            capture(session, state: state, force: true)
        } catch {
            state.condition.lock()
            state.error = error
            state.change &+= 1
            state.condition.unlock()
        }
        state.condition.lock()
        state.stop = true
        state.setStatus(.stopped)
        state.token = nil
        state.initialFinished = true
        state.condition.broadcast()
        state.condition.unlock()
        state.controls?.close()
        notify(state)
    }

    private static func notify(_ state: Shared) {
        state.condition.lock()
        let receiver = state.change != state.delivered ? state.observer : nil
        if receiver != nil { state.delivered = state.change }
        state.condition.unlock()
        receiver?()
    }

    private static func capture(_ session: PreparedSession, state: Shared, force: Bool) {
        // A native accepted patch may still await its worker-side metadata update.
        guard session.canCaptureListeningSnapshot else { return }
        state.condition.lock()
        let needed =
            force || state.listening?.selectionID != session.listeningSelectionID
            || state.listening?.nextState != session.listeningNextState
        state.condition.unlock()
        guard needed else { return }
        do {
            let snapshot = try session.captureListeningSnapshot()
            state.condition.lock()
            if state.listening != snapshot {
                state.listening = snapshot
                state.change &+= 1
            }
            state.condition.unlock()
        } catch {
            state.condition.lock()
            state.error = error
            state.change &+= 1
            state.condition.unlock()
        }
    }

    private static func service(_ session: PreparedSession, work: Invocation) {
        let state = work.shared
        while true {
            do {
                try session.receiveControlsResult()
                try session.receiveNextResult()
            } catch {
                state.condition.lock()
                state.error = error
                state.change &+= 1
                state.condition.unlock()
            }
            state.condition.lock()
            let requestedCapture = state.captureRequested
            state.captureRequested = false
            let nextSelection = state.nextSelection
            state.nextSelection = nil
            state.condition.unlock()
            if let nextSelection { _ = session.requestNext(selectionID: nextSelection) }
            capture(session, state: state, force: requestedCapture)
            notify(state)
            state.condition.lock()
            let renderFailed = session.isFaulted || state.renderFailed?() == true
            if state.stop || renderFailed || session.isFinished {
                if renderFailed {
                    state.error = PreparationWorkerError.renderFailed
                    state.change &+= 1
                }
                state.condition.unlock()
                return
            }
            if state.suspend {
                state.setStatus(.suspended)
                state.condition.unlock()
                notify(state)
                state.condition.lock()
                // Recheck after delivery: captures/resume/stop may have raced the unlock.
                if state.suspend && !state.stop && !state.captureRequested
                    && state.nextSelection == nil
                {
                    state.condition.wait()
                }
                state.condition.unlock()
                continue
            }
            if state.error != nil && state.retry {
                state.retry = false
                state.error = nil
                state.change &+= 1
            }
            state.setStatus(state.error == nil ? .running : .waitingForRetry)
            let shouldPrepare = session.needsPreparation && session.canPrepareSuccessor
            if state.error != nil
                || (!shouldPrepare && !session.hasNextWork && !session.hasControlsWork)
            {
                state.condition.unlock()
                notify(state)
                state.condition.lock()
                if !state.stop && !state.suspend && !state.captureRequested
                    && state.nextSelection == nil && !state.retry
                {
                    _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                }
                state.condition.unlock()
                continue
            }
            // Installing the token and observing stop are one control transaction.
            let token = work.makeCancellation()
            state.token = token
            state.cancelOnControls = !session.isRestoringControls
            if shouldPrepare { state.setStatus(.preparing) }
            state.condition.unlock()
            notify(state)
            do {
                let changed = try autoreleasepool {
                    var changed = try session.prepareControls(cancellation: token)
                    changed = try session.prepareAdvance(cancellation: token) || changed
                    if session.needsPreparation && session.canPrepareSuccessor {
                        try session.prepareNext(cancellation: token)
                        changed = true
                    }
                    return changed
                }
                state.condition.lock()
                state.token = nil
                state.cancelOnControls = false
                state.setStatus(.running)
                state.condition.unlock()
                capture(session, state: state, force: changed)
            } catch {
                state.condition.lock()
                state.token = nil
                state.cancelOnControls = false
                // Classify this attempt's token, not a newer suspension/resume intent.
                if !state.stop, !(error is CancellationError && token.isCancelled) {
                    state.error = error
                    state.change &+= 1
                    state.setStatus(.waitingForRetry)
                }
                state.condition.unlock()
            }
            notify(state)
            // A requested offer needs a consumer turn. Poll at the same bounded worker
            // cadence rather than spinning while output is paused or the callback is late.
            state.condition.lock()
            if !state.stop && !state.suspend && !state.captureRequested
                && state.nextSelection == nil
            {
                _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
            state.condition.unlock()
        }
    }
}
