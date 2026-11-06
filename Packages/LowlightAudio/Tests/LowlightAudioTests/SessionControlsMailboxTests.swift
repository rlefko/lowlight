// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private final class ControlsNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Bool] = []
    func record(_ value: Bool) { lock.withLock { received.append(value) } }
    var values: [Bool] { lock.withLock { received } }
}

struct SessionControlsMailboxTests {
    enum Failure: Error { case capacity }

    @Test func requestInvalidatesNativeRevisionSynchronouslyAndIdenticalSendIsSilent() throws {
        let notifications = ControlsNotifications()
        let mailbox = try SessionControlsMailbox(
            desired: Controls(), applied: Controls(), changed: notifications.record)
        let request = try SessionControlsRequest(revision: 2, controls: Controls.preset(.relax))
        #expect(mailbox.send(request))
        #expect(ll_song_revision_get(mailbox.intent.handle) == 2)
        #expect(mailbox.snapshot.requested == request.controls)
        #expect(mailbox.snapshot.applied == Controls() && mailbox.snapshot.appliedRevision == 1)
        #expect(mailbox.snapshot.state == .queued)
        for _ in 0..<100 { #expect(mailbox.send(request)) }
        #expect(!mailbox.send(try SessionControlsRequest(revision: 2, controls: Controls())))
        #expect(!mailbox.send(try SessionControlsRequest(revision: 1, controls: Controls())))
        #expect(notifications.values == [true])
        mailbox.close()
        #expect(!mailbox.send(try SessionControlsRequest(revision: 3, controls: Controls())))
        #expect(!mailbox.retry())
        #expect(ll_song_revision_get(mailbox.intent.handle) == 2)
    }

    @Test func concurrentOutOfOrderSubmissionsRetainOnlyTheLargestWholeRequest() throws {
        let notifications = ControlsNotifications()
        let mailbox = try SessionControlsMailbox(
            desired: Controls(), applied: Controls(), changed: notifications.record)
        let requests = try (2...129).map { revision in
            try SessionControlsRequest(
                revision: UInt64(revision), controls: Controls(energy: Double(revision % 100) / 100)
            )
        }
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            _ = mailbox.send(requests[index])
        }
        let latest = try #require(requests.last)
        #expect(mailbox.request == latest)
        #expect(ll_song_revision_get(mailbox.intent.handle) == latest.revision)
        #expect(mailbox.snapshot.requested == latest.controls)
        #expect(!notifications.values.isEmpty && notifications.values.count <= requests.count)
        #expect(notifications.values.allSatisfy { $0 })
    }

    @Test func lateAcknowledgmentCannotReplaceNewerDesiredSettings() throws {
        let notifications = ControlsNotifications()
        let mailbox = try SessionControlsMailbox(
            desired: Controls(), applied: Controls(), changed: notifications.record)
        let first = try SessionControlsRequest(revision: 2, controls: Controls.preset(.relax))
        let latest = try SessionControlsRequest(revision: 3, controls: Controls.preset(.reflective))
        #expect(mailbox.send(first) && mailbox.send(latest))
        mailbox.publish(
            applied: first.controls, appliedRevision: 2, phase: .none, revision: 2)
        #expect(mailbox.snapshot.requested == latest.controls && mailbox.snapshot.revision == 3)
        #expect(mailbox.snapshot.applied == first.controls && mailbox.snapshot.appliedRevision == 2)
        #expect(mailbox.snapshot.state == .queued)
        mailbox.fail(first, error: Failure.capacity)
        #expect(mailbox.lastError == nil && mailbox.canAttempt)
        mailbox.publish(
            applied: latest.controls, appliedRevision: 3, phase: .none, revision: 3)
        #expect(mailbox.snapshot.state == .none && mailbox.snapshot.applied == latest.controls)
    }

    @Test func failureIsLatchedUntilOneRetryOrNewerRequestWithoutLosingIntent() throws {
        let notifications = ControlsNotifications()
        let mailbox = try SessionControlsMailbox(
            desired: Controls(), applied: Controls(), changed: notifications.record)
        let request = try SessionControlsRequest(revision: 2, controls: Controls.preset(.workout))
        #expect(mailbox.send(request))
        mailbox.fail(request, error: Failure.capacity)
        #expect(mailbox.snapshot.state == .failed && !mailbox.canAttempt)
        #expect(
            mailbox.snapshot.requested == request.controls && mailbox.snapshot.applied == Controls()
        )
        #expect(mailbox.retry() && !mailbox.retry())
        #expect(mailbox.request == request && mailbox.canAttempt && mailbox.retryGeneration == 1)
        #expect(mailbox.snapshot.state == .queued && mailbox.lastError == nil)
        #expect(ll_song_revision_get(mailbox.intent.handle) == request.revision)
        mailbox.fail(request, error: Failure.capacity)
        let next = try SessionControlsRequest(revision: 3, controls: Controls.preset(.relax))
        #expect(mailbox.send(next))
        #expect(mailbox.lastError == nil && mailbox.canAttempt && mailbox.request == next)
    }
}
