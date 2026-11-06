// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import Foundation
import LowlightPlanning

/// A weak, synchronous capability. Submission invalidates obsolete native work before
/// returning, without waiting for the engine queue, preparing music, or granting playback.
public struct SessionControlsInput: Sendable {
    private let submit: @Sendable (SessionControlsRequest) -> Bool
    private let retryRequest: @Sendable () -> Bool

    init(
        submit: @escaping @Sendable (SessionControlsRequest) -> Bool,
        retry: @escaping @Sendable () -> Bool
    ) {
        self.submit = submit
        retryRequest = retry
    }

    @discardableResult public func send(_ request: SessionControlsRequest) -> Bool {
        submit(request)
    }
    @discardableResult public func retry() -> Bool { retryRequest() }
}

/// The pair borrows this immutable handle. The owning session pins it through native
/// destruction, independently of the worker/control capability's lifetime.
final class SessionControlsRevision: @unchecked Sendable {
    let handle: OpaquePointer

    init() throws {
        guard let handle = ll_song_revision_create() else {
            throw PreparedSessionError.preparationFailed
        }
        self.handle = handle
    }

    deinit { ll_song_revision_destroy(handle) }
    func set(_ revision: UInt64) -> Bool { ll_song_revision_set(handle, revision) }
}

/// Only this small mailbox crosses the worker boundary. Its callback runs after unlocking;
/// no observer or engine operation may execute while either mailbox lock is held.
final class SessionControlsMailbox: @unchecked Sendable {
    struct Attempt: Sendable {
        let request: SessionControlsRequest
        let retry: UInt64
        let canAttempt: Bool
    }

    let intent: SessionControlsRevision
    private let lock = NSLock()
    private let changed: @Sendable (Bool) -> Void
    private let attemptCaptured: (@Sendable (Attempt) -> Void)?
    private var desired: SessionControlsRequest
    private var lastSubmission: SessionControlsRequest
    private var applied: Controls
    private var appliedRevision: UInt64
    private var phase = SessionControlChangeState.none
    private var phaseRevision: UInt64 = 1
    private var failure: (revision: UInt64, error: any Error)?
    private var retryCount: UInt64 = 0
    private var stopped = false

    init(
        desired: Controls, applied: Controls,
        attemptCaptured: (@Sendable (Attempt) -> Void)? = nil,
        changed: @escaping @Sendable (Bool) -> Void
    ) throws {
        self.desired = try SessionControlsRequest(revision: 1, controls: desired)
        lastSubmission = self.desired
        self.applied = applied
        appliedRevision = desired.hasSameMusic(as: applied) ? 1 : 0
        phase = desired.hasSameMusic(as: applied) ? .none : .queued
        self.changed = changed
        self.attemptCaptured = attemptCaptured
        intent = try SessionControlsRevision()
        guard intent.set(1) else { throw PreparedSessionError.preparationFailed }
    }

    var request: SessionControlsRequest { lock.withLock { desired } }
    var lastError: (any Error)? { lock.withLock { failure?.error } }
    var canAttempt: Bool { lock.withLock { !stopped && failure == nil } }
    var retryGeneration: UInt64 { lock.withLock { retryCount } }
    var snapshot: SessionControlsSnapshot { lock.withLock { value } }

    var attempt: Attempt {
        lock.withLock {
            Attempt(request: desired, retry: retryCount, canAttempt: !stopped && failure == nil)
        }
    }

    func captureAttempt() -> Attempt {
        let captured = attempt
        // Internal race-test seam, invoked by worker service outside owner/mailbox locks.
        attemptCaptured?(captured)
        return captured
    }

    private var value: SessionControlsSnapshot {
        SessionControlsSnapshot(
            requested: lastSubmission.controls, applied: applied, revision: desired.revision,
            appliedRevision: appliedRevision,
            state: failure?.revision == desired.revision
                ? .failed : (phaseRevision == desired.revision ? phase : .queued))
    }

    func send(
        _ request: SessionControlsRequest, committingEffects effects: SessionEffectsMailbox? = nil,
        musicalOnly: Bool = false
    )
        -> Bool
    {
        lock.lock()
        guard !stopped, request.revision >= lastSubmission.revision else {
            lock.unlock()
            return false
        }
        if request.revision == lastSubmission.revision {
            let same =
                musicalOnly
                ? request.controls.hasSameMusic(as: lastSubmission.controls)
                : request == lastSubmission
            lock.unlock()
            return same
        }
        if let effects {
            guard effects.commit(SessionEffects(request.controls)) else {
                lock.unlock()
                return false
            }
            if request.controls.hasSameMusic(as: desired.controls) {
                lastSubmission = request
                lock.unlock()
                changed(false)
                return true
            }
        }
        guard intent.set(request.revision) else {
            lock.unlock()
            return false
        }
        desired = request
        lastSubmission = request
        failure = nil
        phase = .queued
        phaseRevision = request.revision
        lock.unlock()
        changed(true)
        return true
    }

    func retry() -> Bool {
        lock.lock()
        guard !stopped, failure != nil, retryCount < UInt64.max else {
            lock.unlock()
            return false
        }
        failure = nil
        retryCount += 1
        phase = .queued
        phaseRevision = desired.revision
        lock.unlock()
        changed(false)
        return true
    }

    func fail(_ request: SessionControlsRequest, error: any Error) {
        lock.lock()
        guard !stopped, request == desired else {
            lock.unlock()
            return
        }
        failure = (request.revision, error)
        lock.unlock()
        changed(false)
    }

    func publish(
        applied: Controls, appliedRevision: UInt64, phase: SessionControlChangeState,
        revision: UInt64
    ) {
        lock.lock()
        let before = value
        self.applied = applied
        self.appliedRevision = appliedRevision
        if revision == desired.revision {
            self.phase = phase
            phaseRevision = revision
        }
        let differs = value != before
        lock.unlock()
        if differs { changed(false) }
    }

    func close() { lock.withLock { stopped = true } }
}
