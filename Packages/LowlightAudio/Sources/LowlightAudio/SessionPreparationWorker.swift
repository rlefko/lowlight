// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

public enum PreparationWorkerStatus: Sendable { case running, preparing, waitingForRetry, stopped }
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
        var retry = false
        var joining = false
        var issued = false
        var token: PreparationCancellation?
        // Pins the session even after EOF/worker exit; those are not render-quiescence proofs.
        var endpoint: PreparedSession.RenderEndpoint?

        init(token: PreparationCancellation) { self.token = token }
    }

    private final class Invocation {
        let shared: Shared
        let prepare: @Sendable (PreparationCancellation) throws -> PreparedSession
        let makeCancellation: @Sendable () -> PreparationCancellation

        init(
            shared: Shared, makeCancellation: @escaping @Sendable () -> PreparationCancellation,
            prepare: @escaping @Sendable (PreparationCancellation) throws -> PreparedSession
        ) {
            self.shared = shared
            self.makeCancellation = makeCancellation
            self.prepare = prepare
        }
    }

    private let shared: Shared
    private var thread: pthread_t?

    public convenience init(
        seed: UInt64 = 91_031, controls: Controls = Controls(), frameCount: UInt32,
        preparer: TonalSamplePreparer, cancellation: PreparationCancellation? = nil
    ) throws {
        try self.init(cancellation: cancellation) { token in
            try PreparedSession(
                seed: seed, controls: controls, frameCount: frameCount,
                preparation: .concurrent, preparer: preparer, cancellation: token)
        }
    }

    // Short-source/token-observer seams. Factories run only on the worker; token creation
    // must not block or call controls because it occurs inside the control lock.
    init(
        cancellation: PreparationCancellation? = nil,
        makeCancellation: @escaping @Sendable () -> PreparationCancellation = {
            PreparationCancellation()
        },
        prepare: @escaping @Sendable (PreparationCancellation) throws -> PreparedSession
    ) throws {
        let token = cancellation ?? PreparationCancellation()
        shared = Shared(token: token)
        try token.check()
        let invocation = Unmanaged.passRetained(
            Invocation(shared: shared, makeCancellation: makeCancellation, prepare: prepare))
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

    /// Coalesces to one retry, and only while a failed successor attempt is latched.
    @discardableResult
    public func retry() -> Bool {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        guard !shared.stop, shared.status == .waitingForRetry, !shared.retry else { return false }
        shared.retry = true
        shared.condition.signal()
        return true
    }

    /// Terminal, cooperative request. A successor that passed its final check may be admitted.
    public func requestStop() {
        shared.condition.lock()
        shared.stop = true
        shared.token?.cancel()
        shared.condition.broadcast()
        shared.condition.unlock()
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
            state.condition.lock()
            let cancelled = state.stop || token.isCancelled
            if !cancelled {
                state.endpoint = endpoint
                state.token = nil
                state.status = .running
                state.initialFinished = true
                state.condition.broadcast()
            }
            state.condition.unlock()
            if cancelled { throw CancellationError() }
            service(session, work: work)
        } catch {
            state.condition.lock()
            state.error = error
            state.condition.unlock()
        }
        state.condition.lock()
        state.stop = true
        state.status = .stopped
        state.token = nil
        state.initialFinished = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    private static func service(_ session: PreparedSession, work: Invocation) {
        let state = work.shared
        while true {
            state.condition.lock()
            if state.stop || session.isFaulted || session.position == session.frameCount {
                if session.isFaulted { state.error = PreparationWorkerError.renderFailed }
                state.condition.unlock()
                return
            }
            if state.status == .waitingForRetry && state.retry {
                state.retry = false
                state.error = nil
                state.status = .running
            }
            if state.status == .waitingForRetry || !session.needsPreparation {
                _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                state.condition.unlock()
                continue
            }
            // Installing the token and observing stop are one control transaction.
            let token = work.makeCancellation()
            state.token = token
            state.status = .preparing
            state.condition.unlock()
            do {
                try autoreleasepool { try session.prepareNext(cancellation: token) }
                state.condition.lock()
                state.token = nil
                state.status = .running
                state.condition.unlock()
            } catch {
                state.condition.lock()
                state.token = nil
                if !state.stop {
                    state.error = error
                    state.status = .waitingForRetry
                }
                state.condition.unlock()
            }
        }
    }
}
