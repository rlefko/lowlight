// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

/// Worker-only transaction owner. Native acknowledgment precedes every pointer release,
/// canonical-plan commit, and rollback; the callback never owns or reclaims Swift objects.
final class PreparedSessionControls {
    private enum Phase {
        case idle, requested, withdrawing, building, published, rollback, restoring
    }
    private struct Stamp: Equatable {
        let revision: UInt64
        let retry: UInt64
        let selection: UInt64?
        let first: UInt64?
        let second: UInt64?
        let pivot: UInt64?
    }
    private final class Transaction {
        let plan: SessionControlsPlan
        let offer: LLSongChangeOffer
        let patch: PreparedSongControlChange
        let original: SessionListeningSequence.Record
        var retained = false
        var releasedOriginal = false
        var rollbackAttempted = false

        init(
            plan: SessionControlsPlan, offer: LLSongChangeOffer,
            patch: PreparedSongControlChange, original: SessionListeningSequence.Record
        ) {
            self.plan = plan
            self.offer = offer
            self.patch = patch
            self.original = original
        }
    }
    private unowned let owner: PreparedSession
    private let mailbox: SessionControlsMailbox
    private var phase = Phase.idle
    private var pendingPlan: SessionControlsPlan?
    private var transaction: Transaction?
    private var evaluated: Stamp?
    private var committed: (revision: UInt64, selection: UInt64, boundary: UInt64)?
    private var appliedRevision: UInt64
    private var appliedControls: Controls

    init(owner: PreparedSession, mailbox: SessionControlsMailbox) {
        self.owner = owner
        self.mailbox = mailbox
        appliedRevision = mailbox.snapshot.appliedRevision
        appliedControls = mailbox.snapshot.applied
    }

    var isActive: Bool { phase != .idle }
    var blocksCapture: Bool { phase == .published }
    var isRestoring: Bool { phase == .rollback || phase == .restoring }
    var allowsNext: Bool { !isActive && (!hasWork || !mailbox.canAttempt) }
    var hasWork: Bool {
        if phase == .rollback {
            return transaction?.rollbackAttempted == false || mailbox.canAttempt
        }
        if phase == .withdrawing || phase == .published || phase == .restoring { return false }
        if isActive { return true }
        return mailbox.canAttempt && evaluated != stamp
    }
    private var stamp: Stamp {
        makeStamp(mailbox.attempt)
    }

    private func makeStamp(_ attempt: SessionControlsMailbox.Attempt) -> Stamp {
        Stamp(
            revision: attempt.request.revision, retry: attempt.retry,
            selection: owner.listeningSelectionID,
            first: owner.sequence?.records.first?.schedule.song.id,
            second: owner.sequence?.records.dropFirst().first?.schedule.song.id,
            pivot: owner.sequence?.records.first?.pivot)
    }

    func receive() throws {
        var result = LLSongChangeResult()
        if ll_song_pair_change_result(owner.handle, &result) {
            switch result.status {
            case 1:
                guard phase == .published, let transaction, let sequence = owner.sequence,
                    result.revision == transaction.plan.request.revision,
                    result.target_origin == transaction.offer.target_origin,
                    result.boundary_frames == transaction.patch.boundaryFrames,
                    result.input_frames == transaction.patch.inputFrames,
                    result.following_origin
                        == transaction.plan.followingOrigin
                        - UInt64(transaction.patch.advancedFrames)
                else { throw SessionControlsError.stalePlan }
                try sequence.acceptControls(
                    transaction.plan, expectedRevision: result.revision,
                    boundary: result.boundary_frames, delta: transaction.patch.advancedFrames)
                committed = (
                    result.revision, transaction.plan.successor.schedule.song.id,
                    result.target_origin + UInt64(result.boundary_frames)
                )
                owner.controlsSatisfiedNext(selectionID: transaction.plan.current.schedule.song.id)
                finish()
            case 2:
                guard let transaction else { throw SessionControlsError.stalePlan }
                // A missed damping deadline is temporary. After rollback, a fresh physical
                // offer excludes that boundary and can select a later phrase in this song.
                // Native deferral or no remaining boundary still stops repeated attempts.
                evaluated = nil
                if result.withdrawn != 0 {
                    discardCandidate(transaction)
                    phase = .rollback
                } else {
                    finish()
                }
            case 3:
                let attempt = mailbox.captureAttempt()
                // Only the request/retry that produced this result was evaluated. A newer
                // send or retry racing this snapshot must remain eligible for another turn.
                evaluated =
                    result.revision == attempt.request.revision
                        && evaluated?.revision == result.revision
                        && evaluated?.retry == attempt.retry
                    ? makeStamp(attempt) : nil
                finish()
            case 4:
                guard phase == .restoring else { throw SessionControlsError.stalePlan }
                finish()
            default: throw SessionControlsError.stalePlan
            }
        }
        if phase == .withdrawing {
            var retired: OpaquePointer?
            if ll_song_pair_claim_withdrawn_change(owner.handle, &retired) {
                guard retired == owner.second?.borrowedHandle else {
                    throw SessionControlsError.stalePlan
                }
                phase = .building
            }
        }
        if !blocksCapture { publishState() }
    }

    private func publishState() {
        guard let sequence = owner.sequence, let selection = owner.listeningSelectionID,
            let record = sequence.record(for: selection)
        else { return }
        let request = mailbox.request
        var state = SessionControlChangeState.queued
        if let committed {
            if selection >= committed.selection {
                appliedRevision = committed.revision
                appliedControls = record.schedule.song.controls
                self.committed = nil
            } else if request.revision == committed.revision,
                owner.listeningPosition >= committed.boundary
            {
                state = .transitioning
            }
        }
        if record.schedule.song.controls != appliedControls {
            appliedControls = record.schedule.song.controls
            appliedRevision = 0
        }
        if appliedRevision == request.revision, record.schedule.song.controls == request.controls,
            !isActive, committed == nil
        {
            state = .none
        }
        mailbox.publish(
            applied: record.schedule.song.controls, appliedRevision: appliedRevision,
            phase: state, revision: request.revision)
    }

    @discardableResult
    func service(cancellation: PreparationCancellation) throws -> Bool {
        try cancellation.check()
        switch phase {
        case .idle: return try begin()
        case .requested: return try preparePatch(cancellation)
        case .building: return try buildReplacement(cancellation)
        case .rollback: return try restoreOriginal(cancellation)
        case .withdrawing, .published, .restoring: return false
        }
    }

    private func begin() throws -> Bool {
        let attempt = mailbox.captureAttempt()
        guard attempt.canAttempt, let sequence = owner.sequence,
            let selection = owner.listeningSelectionID
        else { return false }
        let request = attempt.request
        evaluated = makeStamp(attempt)
        do {
            guard let plan = try sequence.planControls(request, selectionID: selection) else {
                if sequence.records.allSatisfy({ $0.schedule.song.controls == request.controls }) {
                    appliedRevision = request.revision
                    appliedControls = request.controls
                }
                publishState()
                return false
            }
            if plan.current.schedule == sequence.records[0].schedule,
                plan.successor.checkpoint == sequence.records[1].checkpoint
            {
                if plan.current.schedule.song.controls == request.controls {
                    appliedRevision = request.revision
                    appliedControls = request.controls
                } else {
                    // The prepared successor already realizes this request. Preserve its
                    // transition and acknowledge the request at its actual rhythm handoff.
                    committed = (
                        request.revision, plan.successor.schedule.song.id,
                        plan.successor.placement
                    )
                }
                publishState()
                return false
            }
            guard
                ll_song_pair_request_change(
                    owner.handle, plan.current.placement, request.revision, mailbox.intent.handle)
            else { return false }
            pendingPlan = plan
            phase = .requested
            return true
        } catch {
            mailbox.fail(request, error: error)
            return false
        }
    }

    private func preparePatch(_ cancellation: PreparationCancellation) throws -> Bool {
        var offer = LLSongChangeOffer()
        guard ll_song_pair_claim_change(owner.handle, &offer) else { return false }
        do {
            try cancellation.check()
            guard let plan = pendingPlan, let sequence = owner.sequence, let first = owner.first,
                plan.request == mailbox.request, offer.first == first.borrowedHandle,
                offer.second == owner.second?.borrowedHandle
            else { throw CancellationError() }
            guard let boundary = try Self.boundary(plan, offer: offer) else {
                guard ll_song_pair_abandon_change(owner.handle) else {
                    throw SessionControlsError.stalePlan
                }
                finish()
                return false
            }
            let patch = try first.makeControlChange(
                offer: offer, revisedSchedule: plan.current.schedule, boundaryFrames: boundary,
                preparer: sequence.preparer, cancellation: cancellation)
            try cancellation.check()
            let change = Transaction(
                plan: plan, offer: offer, patch: patch, original: sequence.records[1])
            transaction = change
            guard ll_song_pair_withdraw_change(owner.handle, patch.handle) else {
                throw CancellationError()
            }
            phase = .withdrawing
            return true
        } catch {
            guard ll_song_pair_abandon_change(owner.handle) else {
                throw SessionControlsError.stalePlan
            }
            if !(error is CancellationError), let request = pendingPlan?.request {
                mailbox.fail(request, error: error)
            }
            if error is CancellationError { evaluated = nil }
            finish()
            return false
        }
    }

    private static func boundary(_ plan: SessionControlsPlan, offer: LLSongChangeOffer) throws
        -> UInt32?
    {
        try PreparationMode.perform {
            let layout = try SongRenderLayout(schedule: plan.current.schedule)
            let end = plan.current.schedule.song.bars * 4 - 16
            for beat in stride(from: 32, through: end, by: 32) {
                let frame = UInt64(try plan.current.schedule.frame(at: Double(beat)))
                let local = frame - plan.current.canonicalOrigin
                guard local <= offer.outro_start_frames else { continue }
                let delta = UInt64(offer.outro_start_frames) - local
                if local >= UInt64(offer.source_input_frames) + 3520,
                    UInt64(layout.inputFrames) >= delta,
                    UInt64(layout.inputFrames) - delta <= offer.original_frames
                {
                    return UInt32(local)
                }
            }
            return nil
        }
    }

    private func buildReplacement(_ cancellation: PreparationCancellation) throws -> Bool {
        guard let transaction, let sequence = owner.sequence, let first = owner.first else {
            throw SessionControlsError.stalePlan
        }
        do {
            guard transaction.plan.request == mailbox.request else { throw CancellationError() }
            try cancellation.check()
            owner.second = nil  // Withdrawal was acknowledged; release the old pool reservation.
            transaction.releasedOriginal = true
            try first.retainControlChange(transaction.patch)
            transaction.retained = true
            let replacement = try owner.pool.prepare(
                schedule: transaction.plan.successor.schedule, preparer: sequence.preparer,
                cancellation: cancellation)
            try cancellation.check()
            owner.second = replacement
            let following =
                transaction.plan.followingOrigin - UInt64(transaction.patch.advancedFrames)
            guard
                ll_song_pair_publish_change(
                    owner.handle, transaction.patch.handle, replacement.borrowedHandle, following)
            else { throw PreparedSessionError.preparationFailed }
            phase = .published
            return true
        } catch {
            if !(error is CancellationError) {
                mailbox.fail(transaction.plan.request, error: error)
            } else {
                evaluated = nil
            }
            discardCandidate(transaction)
            phase = .rollback
            return false
        }
    }

    private func discardCandidate(_ transaction: Transaction) {
        if transaction.releasedOriginal { owner.second = nil }
        if transaction.retained {
            owner.first?.discardControlChange()
            transaction.retained = false
        }
    }

    private func restoreOriginal(_ cancellation: PreparationCancellation) throws -> Bool {
        guard let transaction, let sequence = owner.sequence else {
            throw SessionControlsError.stalePlan
        }
        guard !transaction.rollbackAttempted || mailbox.canAttempt else { return false }
        transaction.rollbackAttempted = true
        do {
            try cancellation.check()
            if owner.second == nil {
                owner.second = try owner.pool.prepare(
                    schedule: transaction.original.schedule, preparer: sequence.preparer,
                    cancellation: cancellation)
            }
            try cancellation.check()
            guard let original = owner.second,
                ll_song_pair_restore_change(owner.handle, original.borrowedHandle)
            else { throw PreparedSessionError.preparationFailed }
            phase = .restoring
            return true
        } catch {
            owner.second = nil
            if error is CancellationError {
                transaction.rollbackAttempted = false
            } else {
                mailbox.fail(mailbox.request, error: error)
            }
            return false
        }
    }

    private func finish() {
        transaction = nil
        pendingPlan = nil
        phase = .idle
    }
}
