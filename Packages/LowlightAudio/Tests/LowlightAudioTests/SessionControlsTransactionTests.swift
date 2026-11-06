// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private final class ControlsAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable (SessionControlsMailbox.Attempt) -> Void)?
    private var count = 0

    var fired: Bool { lock.withLock { count > 0 } }

    func arm(_ action: @escaping @Sendable (SessionControlsMailbox.Attempt) -> Void) {
        lock.withLock { self.action = action }
    }

    func capture(_ attempt: SessionControlsMailbox.Attempt) {
        let action = lock.withLock {
            let action = self.action
            self.action = nil
            if action != nil { count += 1 }
            return action
        }
        action?(attempt)
    }
}

/// These tests drive the production worker-only protocol between render calls. Every rack,
/// analysis, patch, withdrawal, and acknowledgment is real; only scheduling is deterministic.
struct SessionControlsTransactionTests {
    private func preparer() throws -> TonalSamplePreparer {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try TonalSamplePreparer(bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func setup(
        attemptCaptured: (@Sendable (SessionControlsMailbox.Attempt) -> Void)? = nil
    ) throws -> (
        PreparedSession, SessionControlsMailbox, PreparedSession.RenderEndpoint
    ) {
        let controls = Controls(energy: 0.2, tempo: 90)
        let session = try PreparedSession(controls: controls, preparer: preparer())
        let mailbox = try SessionControlsMailbox(
            desired: controls, applied: controls, attemptCaptured: attemptCaptured
        ) { _ in }
        session.installControls(mailbox)
        return (session, mailbox, try session.makeRenderEndpoint())
    }

    private func render(
        _ session: PreparedSession, endpoint: PreparedSession.RenderEndpoint, frames: Int = 256
    ) throws {
        var output = [Float](repeating: .nan, count: 2 * frames)
        let written = try #require(
            output.withUnsafeMutableBufferPointer { endpoint.render(into: $0) })
        #expect(written == frames)
        #expect(output.allSatisfy { $0.isFinite })
        #expect(!session.isFaulted)
        #expect(session.pool.reservedRacks <= 2)
        #expect(session.requiredVoiceSlots <= 64)
        #expect(session.reservedPCMBytes <= 64 * 1024 * 1024)
    }

    private func service(_ session: PreparedSession) throws {
        try session.receiveControlsResult()
        try session.receiveNextResult()
        if session.hasControlsWork {
            _ = try session.prepareControls(cancellation: PreparationCancellation())
        }
    }

    @Test func requestArrivingAfterAttemptCaptureCannotBeMarkedAlreadyEvaluated() throws {
        let gate = ControlsAttemptGate()
        let (session, mailbox, endpoint) = try setup(attemptCaptured: gate.capture)
        let sequence = try #require(session.sequence)
        let obsolete = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        let latest = try SessionControlsRequest(
            revision: 3, controls: Controls(energy: 0.25, mood: -0.4, tempo: 95))
        #expect(mailbox.send(obsolete))
        gate.arm { [weak mailbox] attempt in
            #expect(attempt.request == obsolete && attempt.retry == 0 && attempt.canAttempt)
            #expect(mailbox?.send(latest) == true)
        }
        // The native revision rejects the old request after its immutable snapshot was read.
        #expect(try !session.prepareControls(cancellation: PreparationCancellation()))
        #expect(gate.fired && session.hasControlsWork)
        #expect(sequence.acceptedControlsRevision == 0 && mailbox.lastError == nil)
        for _ in 0..<12 {
            try service(session)
            try render(session, endpoint: endpoint)
        }
        #expect(sequence.acceptedControlsRevision == latest.revision)
        #expect(sequence.records[1].schedule.song.controls == latest.controls)
        #expect(mailbox.snapshot.requested == latest.controls && mailbox.lastError == nil)
    }

    @Test func deferredAcknowledgmentCannotConsumeANewerRequestOrRetry() throws {
        enum Failure: Error { case injected }
        for retry in [false, true] {
            let gate = ControlsAttemptGate()
            let (session, mailbox, endpoint) = try setup(attemptCaptured: gate.capture)
            let sequence = try #require(session.sequence)
            let original = sequence.records
            let request = try SessionControlsRequest(
                revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
            let latest = try SessionControlsRequest(
                revision: 3, controls: Controls(energy: 0.25, mood: -0.4, tempo: 95))
            #expect(mailbox.send(request))
            // An already-started B makes the native request defer at the current selection.
            let afterOutro = original[1].placement + 512
            while session.position < afterOutro {
                try render(
                    session, endpoint: endpoint,
                    frames: min(8192, Int(afterOutro - session.position)))
            }
            try service(session)
            try render(session, endpoint: endpoint)
            gate.arm { [weak mailbox] attempt in
                #expect(attempt.request == request && attempt.retry == 0 && attempt.canAttempt)
                if retry {
                    mailbox?.fail(request, error: Failure.injected)
                    #expect(mailbox?.retry() == true)
                } else {
                    #expect(mailbox?.send(latest) == true)
                }
            }
            try session.receiveControlsResult()
            #expect(gate.fired && session.hasControlsWork)
            #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
            #expect(mailbox.lastError == nil && mailbox.retryGeneration == (retry ? 1 : 0))
            // The new attempt is evaluated once; its own natural deferral remains bounded.
            try service(session)
            try render(session, endpoint: endpoint)
            try session.receiveControlsResult()
            #expect(!session.hasControlsWork && session.pool.reservedRacks == 2)
            #expect(mailbox.snapshot.requested == (retry ? request.controls : latest.controls))
        }
    }

    @Test func adoptedChangeCommitsOneCanonicalPlanAndSharesQueuedNext() throws {
        let (session, mailbox, endpoint) = try setup()
        let sequence = try #require(session.sequence)
        let original = sequence.records
        let request = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        let expected = try #require(
            try sequence.planControls(request, selectionID: original[0].schedule.song.id))
        #expect(session.requestNext(selectionID: original[0].schedule.song.id))
        #expect(mailbox.send(request))
        for _ in 0..<12 {
            try service(session)
            try render(session, endpoint: endpoint)
            if sequence.acceptedControlsRevision == 2 { break }
        }
        try service(session)
        #expect(mailbox.lastError == nil)
        try #require(sequence.acceptedControlsRevision == 2)
        #expect(sequence.records[1].schedule == expected.successor.schedule)
        #expect(sequence.records[0].checkpoint == expected.current.checkpoint)
        #expect(session.listeningNextState == .transitioning)
        #expect(mailbox.snapshot.appliedRevision == 1 && mailbox.snapshot.state == .queued)
        let pivot = try #require(sequence.records[0].pivot)
        let handoff = sequence.records[1].handoff
        while session.position < pivot + 512 {
            try render(
                session, endpoint: endpoint, frames: min(8192, Int(pivot + 512 - session.position)))
        }
        try service(session)
        #expect(mailbox.snapshot.state == .transitioning)
        while session.position < handoff + 512 {
            try render(
                session, endpoint: endpoint,
                frames: min(8192, Int(handoff + 512 - session.position)))
        }
        try service(session)
        #expect(mailbox.snapshot.applied == request.controls)
        #expect(mailbox.snapshot.appliedRevision == request.revision)
        #expect(mailbox.snapshot.state == .none)
        #expect(session.listeningNextState == .none)
        #expect(session.stolenVoices == 0 && session.droppedEvents == 0)
        let captured = try #require(try session.captureListeningSnapshot())
        let restarted = try SessionRestartIntent.restore(captured.restart.encoded())
        #expect(restarted.currentSong.controls == request.controls)
        #expect(restarted.planningAnchor != nil)
    }

    @Test func newerRevisionAfterWithdrawalRestoresExactOriginalThenRetriesFromSameAnchor() throws {
        let (session, mailbox, endpoint) = try setup()
        let sequence = try #require(session.sequence)
        let original = sequence.records
        let firstRequest = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        #expect(mailbox.send(firstRequest))
        try service(session)  // Request an offer.
        try render(session, endpoint: endpoint)
        try service(session)  // Build A's patch and request B's withdrawal.
        try render(session, endpoint: endpoint)
        // Acknowledge withdrawal, retaining B until work starts.
        try session.receiveControlsResult()
        let newest = try SessionControlsRequest(
            revision: 3, controls: Controls(energy: 0.25, mood: -0.4, tempo: 95))
        let expected = try #require(
            try sequence.planControls(newest, selectionID: original[0].schedule.song.id))
        #expect(mailbox.send(newest))
        try service(session)  // Cancellation starts deterministic rollback without releasing old B.
        #expect(sequence.records == original)
        #expect(session.pool.reservedRacks == 2)
        for _ in 0..<16 {
            try service(session)
            try render(session, endpoint: endpoint)
            if sequence.acceptedControlsRevision == 3 { break }
        }
        try service(session)
        #expect(mailbox.lastError == nil)
        try #require(sequence.acceptedControlsRevision == 3)
        #expect(sequence.records[1].schedule == expected.successor.schedule)
        #expect(sequence.records[0].checkpoint == expected.current.checkpoint)
        #expect(mailbox.snapshot.requested == newest.controls)
        #expect(session.pool.reservedRacks == 2)
    }

    @Test func legacyRestartDefersStructuralEditAndNilWorkerControlsPreserveSavedSettings() throws {
        let (session, _, _) = try setup()
        let initial = try #require(try session.captureListeningSnapshot())
        let legacy = try SessionRestartIntent(
            checkpoint: initial.restart.checkpoint, canonicalFrame: initial.canonicalFrame)
        let worker = try SessionPreparationWorker(restart: legacy, preparer: preparer())
        defer {
            worker.requestStop()
            worker.join()
        }
        let input = worker.controlsInput
        #expect(worker.controlsSnapshot.requested == legacy.currentSong.controls)
        #expect(worker.controlsSnapshot.applied == legacy.currentSong.controls)
        #expect(worker.controlsSnapshot.state == .none)
        _ = worker.suspend()
        let request = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, tempo: 100))
        #expect(input.send(request))
        #expect(worker.controlsSnapshot.state == .queued)
        #expect(worker.listeningSnapshot?.currentSong == initial.currentSong)
        worker.requestStop()
        worker.join()
        #expect(!input.send(request))
    }

    @Test func resourceFailureKeepsOriginalPlanAndRequiresExactlyOneExplicitRetry() throws {
        let dense = Controls(energy: 1, variation: 1, tempo: 60)
        let safe = Controls(energy: 0.2, tempo: 90)
        let planning = try SessionPlanning(controls: dense)
        for _ in 0..<3 { _ = try planning.next() }
        try planning.setControls(safe)
        let anchor = try planning.checkpoint()
        let current = try planning.next()
        let restart = try SessionRestartIntent(
            checkpoint: planning.checkpoint(), canonicalFrame: UInt64(current.frame(at: 0)),
            planningAnchor: anchor)
        let session = try PreparedSession(restart: restart, preparer: preparer())
        let endpoint = try session.makeRenderEndpoint()
        let mailbox = try SessionControlsMailbox(desired: safe, applied: dense) { _ in }
        session.installControls(mailbox)
        let sequence = try #require(session.sequence)
        let original = sequence.records
        let requested = try SessionControlsRequest(revision: 2, controls: dense)
        #expect(mailbox.send(requested))
        for _ in 0..<16 {
            try service(session)
            try render(session, endpoint: endpoint)
        }
        try #require(mailbox.lastError != nil)
        #expect(mailbox.snapshot.state == .failed)
        #expect(mailbox.snapshot.requested == requested.controls)
        #expect(mailbox.snapshot.applied == original[0].schedule.song.controls)
        #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
        #expect(session.pool.reservedRacks == 2 && !session.hasControlsWork)
        let effects = SessionEffectsMailbox(try #require(session.makeEffectsEndpoint()))
        let liveOnly = try SessionControlsRequest(
            revision: 3,
            controls: SessionEffects(warmth: 0, space: 1, texture: 0).applying(
                to: requested.controls))
        #expect(mailbox.send(liveOnly, committingEffects: effects))
        #expect(mailbox.snapshot.requested == liveOnly.controls)
        #expect(
            mailbox.snapshot.revision == requested.revision && mailbox.snapshot.state == .failed)
        #expect(mailbox.lastError != nil && !session.hasControlsWork)
        #expect(effects.snapshot.requested == SessionEffects(liveOnly.controls))
        #expect(mailbox.retry() && !mailbox.retry())
        for _ in 0..<16 {
            try service(session)
            try render(session, endpoint: endpoint)
        }
        #expect(mailbox.snapshot.state == .failed)
        #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
        #expect(session.pool.reservedRacks == 2 && !session.hasControlsWork)
        let recover = try SessionControlsRequest(
            revision: 4, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        #expect(mailbox.send(recover))
        for _ in 0..<12 {
            try service(session)
            try render(session, endpoint: endpoint)
        }
        #expect(mailbox.lastError == nil && sequence.acceptedControlsRevision == 4)
    }

    @Test func acceptedNativeRevisionCommitsEvenWhenNewerRequestPrecedesWorkerAcknowledgment()
        throws
    {
        let (session, mailbox, endpoint) = try setup()
        let sequence = try #require(session.sequence)
        let request = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        #expect(mailbox.send(request))
        for _ in 0..<3 {  // Request, withdrawal, and replacement publication.
            try service(session)
            try render(session, endpoint: endpoint)
        }
        #expect(sequence.acceptedControlsRevision == 0)
        let newer = try SessionControlsRequest(
            revision: 3, controls: Controls(energy: 0.25, mood: -0.4, tempo: 95))
        #expect(mailbox.send(newer))
        try service(session)
        #expect(sequence.acceptedControlsRevision == 2)
        #expect(sequence.records[1].schedule.song.controls == request.controls)
        #expect(mailbox.snapshot.revision == 3 && mailbox.snapshot.requested == newer.controls)
        #expect(mailbox.snapshot.state == .queued && mailbox.lastError == nil)
        #expect(try session.captureListeningSnapshot() != nil)
        // A committed bridge stays intact. The queued edit targets the next selected song
        // only after its predecessor retires and its normal one-ahead rack is available.
        while !session.needsPreparation {
            try render(session, endpoint: endpoint, frames: 8192)
        }
        try session.prepareNext()
        let expected = try #require(
            try sequence.planControls(newer, selectionID: sequence.records[0].schedule.song.id))
        for _ in 0..<12 {
            try service(session)
            try render(session, endpoint: endpoint)
        }
        #expect(sequence.acceptedControlsRevision == 3)
        #expect(sequence.records[1].schedule == expected.successor.schedule)
        let handoff = sequence.records[1].handoff
        while session.position < handoff + 512 {
            try render(
                session, endpoint: endpoint,
                frames: min(8192, Int(handoff + 512 - session.position)))
        }
        try service(session)
        #expect(mailbox.snapshot.appliedRevision == 3 && mailbox.snapshot.state == .none)
        #expect(session.pool.reservedRacks == 2)
    }

    @Test func missedPublicationDeadlineRestoresOriginalThenAdoptsAtALaterBoundary() throws {
        let (session, mailbox, endpoint) = try setup()
        let sequence = try #require(session.sequence)
        let original = sequence.records
        let request = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        #expect(mailbox.send(request))
        try service(session)
        try render(session, endpoint: endpoint)
        try service(session)
        try render(session, endpoint: endpoint)
        try session.receiveControlsResult()
        let boundary = UInt64(try original[0].schedule.frame(at: 32))
        let late = boundary - 3000
        while session.position < late {
            try render(session, endpoint: endpoint, frames: min(8192, Int(late - session.position)))
        }
        try service(session)  // Finish replacement after its damping lead has already passed.
        try render(session, endpoint: endpoint)
        // Rejection requires deterministic original-B rollback.
        try session.receiveControlsResult()
        try service(session)
        try render(session, endpoint: endpoint)
        try session.receiveControlsResult()
        #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
        #expect(mailbox.snapshot.state == .queued && mailbox.lastError == nil)
        #expect(session.pool.reservedRacks == 2 && session.hasControlsWork)
        for _ in 0..<12 {
            try service(session)
            try render(session, endpoint: endpoint)
        }
        #expect(sequence.acceptedControlsRevision == request.revision)
        #expect(try #require(sequence.records[0].pivot) > boundary)
        #expect(sequence.records[1].schedule.song.controls == request.controls)
        #expect(mailbox.lastError == nil)
        #expect(session.stolenVoices == 0 && session.droppedEvents == 0)
    }

    @Test func publishedReplacementAndRevisionTokenOutlivePreparationOwnerUntilFinalCapture() throws
    {
        var session: PreparedSession?
        var mailbox: SessionControlsMailbox?
        var endpoint: PreparedSession.RenderEndpoint?
        (session, mailbox, endpoint) = try setup()
        weak let retained = session
        let pool = try #require(session?.pool)
        let request = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        #expect(mailbox?.send(request) == true)
        do {
            let owner = try #require(session)
            let renderEndpoint = try #require(endpoint)
            for _ in 0..<2 {
                try service(owner)
                try render(owner, endpoint: renderEndpoint)
            }
            try service(owner)  // Published but not yet consumed by the callback.
            #expect(!owner.canCaptureListeningSnapshot)
            #expect(owner.sequence?.acceptedControlsRevision == 0)
        }
        session = nil
        mailbox = nil
        #expect(retained != nil && pool.reservedRacks == 2)
        var output = [Float](repeating: .nan, count: 512)
        #expect(output.withUnsafeMutableBufferPointer { endpoint?.render(into: $0) } == 256)
        #expect(try endpoint?.captureAfterWorkerStopped() != nil)
        #expect(retained?.sequence?.acceptedControlsRevision == 2)
        endpoint = nil
        #expect(retained == nil && pool.reservedRacks == 0)
    }

    @Test func matchingPreparedSuccessorAcknowledgesOnlyAtItsExistingRhythmHandoff() throws {
        let initial = Controls(energy: 0.2, tempo: 90)
        let desired = Controls(energy: 0.3, mood: 0.5, tempo: 100)
        let planning = try SessionPlanning(controls: initial)
        try planning.setControls(desired)
        let anchor = try planning.checkpoint()
        let current = try planning.next()
        let restart = try SessionRestartIntent(
            checkpoint: planning.checkpoint(), canonicalFrame: UInt64(current.frame(at: 0)),
            planningAnchor: anchor)
        let session = try PreparedSession(restart: restart, preparer: preparer())
        let endpoint = try session.makeRenderEndpoint()
        let mailbox = try SessionControlsMailbox(desired: desired, applied: initial) { _ in }
        session.installControls(mailbox)
        let sequence = try #require(session.sequence)
        let original = sequence.records
        try service(session)
        #expect(mailbox.snapshot.appliedRevision == 0 && mailbox.snapshot.state == .queued)
        #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
        let handoff = original[1].handoff
        while session.position < handoff + 512 {
            try render(
                session, endpoint: endpoint,
                frames: min(8192, Int(handoff + 512 - session.position)))
        }
        try service(session)
        #expect(mailbox.snapshot.applied == desired && mailbox.snapshot.appliedRevision == 1)
        #expect(mailbox.snapshot.state == .none)
        #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
    }

}
