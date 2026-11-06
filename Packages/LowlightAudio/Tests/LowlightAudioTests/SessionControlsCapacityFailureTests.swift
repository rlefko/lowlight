// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private final class CapacityPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    // Set by the worker before construction returns; inspect owners after worker join.
    var firstFrames: UInt32 = 0
    weak var session: PreparedSession?
    var pool: SongPreparationPool?

    var count: Int { lock.withLock { attempts } }
    func token() -> PreparationCancellation {
        lock.withLock { attempts += 1 }
        return PreparationCancellation()
    }
}

struct SessionControlsCapacityFailureTests {
    @Test
    func
        ordinaryCapacityFailureKeepsNewDesiredControlsQueuedWithoutPretendingChangeRetryRecoversIt()
        throws
    {
        let dense = Controls(energy: 1, variation: 1, tempo: 60)
        let planning = try SessionPlanning(controls: dense)
        for _ in 0..<2 { _ = try planning.next() }
        let anchor = try planning.checkpoint()
        let current = try planning.next()
        let restart = try SessionRestartIntent(
            checkpoint: planning.checkpoint(), canonicalFrame: UInt64(current.frame(at: 0)),
            planningAnchor: anchor)
        let fourth = try planning.next()
        let fifth = try planning.next()  // Frozen native score known to exceed its 32 MiB arena.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let probe = CapacityPreparationProbe()
        let worker = try SessionPreparationWorker(
            initialControls: dense, makeCancellation: { probe.token() },
            prepare: { token in
                let session = try PreparedSession(
                    restart: restart, preparer: preparer, cancellation: token)
                probe.firstFrames = try #require(session.first?.layout.inputFrames)
                probe.session = session
                probe.pool = session.pool
                return session
            })
        defer {
            worker.requestStop()
            worker.join()
        }
        let endpoint = try worker.makeRenderEndpoint()
        let firstSelection = try #require(worker.listeningSnapshot?.selectionID)
        // Keep the ordinary fifth-song capacity failure, but reach its predecessor through
        // the real musical Next path rather than rendering the entire current song.
        #expect(worker.requestNext())
        var output = [Float](repeating: .nan, count: 16_384)
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        // Admit Next with tiny real pulls before advancing musical time. This prevents an
        // accelerated test consumer from repeatedly overtaking the preparation deadline.
        while worker.listeningSnapshot?.nextState != .transitioning {
            try #require(ContinuousClock.now < deadline)
            #expect(
                output.withUnsafeMutableBufferPointer {
                    endpoint.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<2]))
                } == 1)
            usleep(1000)
        }
        let schedule = try #require(worker.listeningSnapshot?.restart.schedule)
        let advance = UInt64(try schedule.outgoing.ramp.frame(at: 0) - schedule.frame(at: 32))
        let retirement = UInt64(probe.firstFrames) - advance + 1024
        while worker.status != .waitingForRetry {
            try #require(ContinuousClock.now < deadline)
            if endpoint.position < retirement {
                let count = min(8192, Int(retirement - endpoint.position))
                _ = try #require(
                    output.withUnsafeMutableBufferPointer {
                        endpoint.render(
                            into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
                    })
            }
            usleep(1000)
        }
        #expect(worker.lastError is VoiceMixerError)
        #expect(worker.listeningSnapshot?.selectionID == firstSelection + 1)
        #expect(endpoint.position < UInt64(probe.firstFrames))
        let requested = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.2, tempo: 90))
        #expect(worker.setControls(requested))
        #expect(worker.controlsSnapshot.requested == requested.controls)
        #expect(worker.controlsSnapshot.applied == dense)
        #expect(worker.controlsSnapshot.appliedRevision != requested.revision)
        #expect(worker.controlsSnapshot.state == .queued && worker.controlsError == nil)
        #expect(!worker.retryControls())  // Ordinary preparation uses its existing retry path.
        let attempts = probe.count
        #expect(worker.retry() && !worker.retry())
        while probe.count == attempts || worker.status != .waitingForRetry {
            try #require(ContinuousClock.now < deadline)
            usleep(1000)
        }
        #expect(worker.lastError is VoiceMixerError && worker.controlsError == nil)
        #expect(worker.controlsSnapshot.requested == requested.controls)
        #expect(worker.controlsSnapshot.state == .queued)
        worker.requestStop()
        worker.join()
        let sequence = try #require(probe.session?.sequence)
        #expect(sequence.records.count == 1 && sequence.records[0].schedule == fourth)
        #expect(try sequence.pendingRecord().schedule == fifth)
        #expect(sequence.acceptedControlsRevision == 0)
        #expect(probe.pool?.reservedRacks == 1)
        #expect(probe.session?.stolenVoices == 0 && probe.session?.droppedEvents == 0)
    }
}
