// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private final class ControlsAnalysisGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    // Worker-owned, read only after joining the worker.
    var fired = false
    var timedOut = false
    weak var session: PreparedSession?
    var pool: SongPreparationPool?
    var firstFrames: UInt32 = 0

    func observe(_ frame: UInt32) {
        if frame == 256 && !fired {
            fired = true
            entered.signal()
            timedOut = resume.wait(timeout: .now() + 600) != .success
        }
    }
}

struct SessionControlsWorkerTests {
    private func preparer() throws -> TonalSamplePreparer {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try TonalSamplePreparer(bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func until(_ predicate: () -> Bool) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while !predicate() {
            try #require(ContinuousClock.now < deadline)
            usleep(1000)
        }
    }

    // These tests exercise ownership and cancellation. Keep callback time bounded while
    // preparation is busy, then retain the full real render through the applied handoff.
    private func awaitAdoption(
        _ worker: SessionPreparationWorker, endpoint: PreparedSession.RenderEndpoint,
        controls: Controls, deadline: ContinuousClock.Instant
    ) throws {
        var tick = [Float](repeating: .nan, count: 2)
        while worker.listeningSnapshot?.nextSong?.controls != controls {
            try #require(ContinuousClock.now < deadline)
            worker.requestCapture()
            try #require(tick.withUnsafeMutableBufferPointer { endpoint.render(into: $0) } == 1)
            try #require(worker.lastError == nil && worker.controlsError == nil)
            usleep(10_000)
        }
    }

    @Test func supersedingRealReplacementAnalysisWhilePausedRollsBackThenAppliesLatest() throws {
        let initial = Controls(energy: 0.2, tempo: 90)
        let preparer = try preparer()
        let gate = ControlsAnalysisGate()
        var worker: SessionPreparationWorker? = try SessionPreparationWorker(
            initialControls: initial,
            makeCancellation: {
                PreparationCancellation(analysisCheckpoint: { gate.observe($0) })
            },
            prepare: { token in
                let session = try PreparedSession(
                    controls: initial, preparer: preparer, cancellation: token)
                gate.session = session
                gate.pool = session.pool
                gate.firstFrames = try #require(session.first?.layout.inputFrames)
                return session
            })
        defer {
            gate.resume.signal()
            worker?.requestStop()
            worker?.join()
        }
        var endpoint = try worker?.makeRenderEndpoint()
        let input = try #require(worker?.controlsInput)
        let obsolete = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        #expect(input.send(obsolete))
        var output = [Float](repeating: .nan, count: 512)
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while gate.entered.wait(timeout: .now()) != .success {
            try #require(ContinuousClock.now < deadline)
            let count = try #require(
                output.withUnsafeMutableBufferPointer {
                    endpoint?.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<2]))
                })
            try #require(count == 1)
            usleep(10_000)
        }
        let gatePosition = try #require(endpoint?.position)
        try #require(gatePosition + 4096 < UInt64(gate.firstFrames))
        #expect(worker?.suspend() == true)
        let newest = try SessionControlsRequest(
            revision: 3, controls: Controls(energy: 0.25, mood: -0.4, tempo: 95))
        try #require(worker?.listeningSnapshot?.nextSong?.controls != newest.controls)
        #expect(input.send(newest))
        gate.resume.signal()
        try until { worker?.status == .suspended }
        let pausedPosition = endpoint?.position
        #expect(worker?.controlsSnapshot.requested == newest.controls)
        #expect(worker?.controlsSnapshot.applied == initial)
        #expect(worker?.controlsSnapshot.state == .queued)
        #expect(worker?.lastError == nil && worker?.controlsError == nil)
        #expect(endpoint?.position == pausedPosition)
        #expect(worker?.resume() == true)
        let completion = ContinuousClock.now.advanced(by: .seconds(600))
        do {
            let active = try #require(worker)
            let render = try #require(endpoint)
            try awaitAdoption(
                active, endpoint: render, controls: newest.controls, deadline: completion)
        }
        while worker?.controlsSnapshot.appliedRevision != newest.revision {
            try #require(ContinuousClock.now < completion)
            let count = try #require(
                output.withUnsafeMutableBufferPointer { endpoint?.render(into: $0) })
            #expect(count >= 0 && count <= 256)
            #expect(output.allSatisfy { $0.isFinite })
            try #require(worker?.controlsError == nil)
            try #require(worker?.lastError == nil)
            usleep(1000)
        }
        #expect(worker?.controlsSnapshot.applied == newest.controls)
        #expect(worker?.controlsSnapshot.state == SessionControlChangeState.none)
        worker?.requestStop()
        worker?.join()
        #expect(gate.fired && !gate.timedOut)
        #expect(gate.pool?.reservedRacks == 2)
        #expect(gate.session?.sequence?.acceptedControlsRevision == 3)
        #expect(gate.session?.stolenVoices == 0 && gate.session?.droppedEvents == 0)
        worker = nil
        #expect(!input.send(newest) && !input.retry())
        #expect(gate.session != nil)  // Endpoint pins the revision owner after worker teardown.
        _ = try endpoint?.captureAfterWorkerStopped()
        endpoint = nil
        #expect(gate.session == nil && gate.pool?.reservedRacks == 0)
    }

    @Test func finiteWorkerReportsKnownSettingsWithoutClaimingLiveControlSupport() throws {
        let controls = Controls(energy: 0.2, mood: -0.5, tempo: 90)
        // Metadata does not require full native songs. Keep the real finite worker and
        // pool/source ownership, using the existing short-score preparation fixture.
        let score = WorkerScore(try preparer())
        let worker = try SessionPreparationWorker(initialControls: controls) { token in
            try score.make(token)
        }
        defer {
            worker.requestStop()
            worker.join()
        }
        #expect(worker.controlsSnapshot.requested == controls)
        #expect(worker.controlsSnapshot.applied == controls)
        #expect(worker.controlsSnapshot.revision == 0 && worker.effectsInput == nil)
        #expect(worker.controlsSnapshot.state == .none)
        #expect(!worker.setControls(try SessionControlsRequest(revision: 2, controls: Controls())))
        #expect(!worker.retryControls())
    }

    @Test func stopDuringWithdrawnReplacementAnalysisKeepsNativePointersPinnedUntilEndpointRelease()
        throws
    {
        let initial = Controls(energy: 0.2, tempo: 90)
        let preparer = try preparer()
        let gate = ControlsAnalysisGate()
        var worker: SessionPreparationWorker? = try SessionPreparationWorker(
            initialControls: initial,
            makeCancellation: {
                PreparationCancellation(analysisCheckpoint: { gate.observe($0) })
            },
            prepare: { token in
                let session = try PreparedSession(
                    controls: initial, preparer: preparer, cancellation: token)
                gate.session = session
                gate.pool = session.pool
                gate.firstFrames = try #require(session.first?.layout.inputFrames)
                return session
            })
        defer {
            gate.resume.signal()
            worker?.requestStop()
            worker?.join()
        }
        var endpoint = try worker?.makeRenderEndpoint()
        let input = try #require(worker?.controlsInput)
        #expect(
            input.send(
                try SessionControlsRequest(
                    revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))))
        var output = [Float](repeating: .nan, count: 512)
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while gate.entered.wait(timeout: .now()) != .success {
            try #require(ContinuousClock.now < deadline)
            let count = try #require(
                output.withUnsafeMutableBufferPointer {
                    endpoint?.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<2]))
                })
            try #require(count == 1)
            usleep(10_000)
        }
        let gatePosition = try #require(endpoint?.position)
        try #require(gatePosition + 4096 < UInt64(gate.firstFrames))
        // The sole preparation worker is blocked inside B′ analysis. Effects can still
        // settle on real A audio and a full effect-only commit keeps its musical request.
        let effects = try #require(worker?.effectsInput)
        let target = SessionEffects(warmth: 0.18, space: 0.92, texture: 1)
        #expect(effects.send(SessionEffects(warmth: 1, space: 0, texture: 0), revision: 2))
        #expect(effects.send(target, revision: 3))
        #expect(!effects.send(SessionEffects(initial), revision: 2))
        var heardSignal = false
        for _ in 0..<48 {
            try #require(
                output.withUnsafeMutableBufferPointer { endpoint?.render(into: $0) } == 256)
            heardSignal = heardSignal || output.contains { abs($0) > 1e-6 }
        }
        #expect(heardSignal && effects.snapshot?.settled == target)
        #expect(effects.snapshot?.adoptedRevision == 3 && effects.snapshot?.settledRevision == 3)
        let music = try #require(worker?.controlsSnapshot)
        let commit = try SessionControlsRequest(
            revision: 3, controls: target.applying(to: music.requested))
        #expect(input.send(commit))
        #expect(worker?.controlsSnapshot.revision == music.revision)
        #expect(worker?.controlsSnapshot.requested == commit.controls)
        #expect(effects.snapshot?.revision == 3)
        worker?.requestStop()
        gate.resume.signal()
        worker?.join()
        #expect(worker?.status == .stopped && worker?.lastError == nil)
        #expect(gate.pool?.reservedRacks == 1)
        #expect(gate.session?.sequence?.acceptedControlsRevision == 0)
        worker = nil
        #expect(!input.retry() && !effects.send(target, revision: 4))
        #expect(effects.snapshot == nil)
        #expect(gate.session != nil)
        #expect(output.withUnsafeMutableBufferPointer { endpoint?.render(into: $0) } == 256)
        #expect(try endpoint?.captureAfterWorkerStopped() != nil)
        #expect(endpoint?.isFaulted == false)
        endpoint = nil
        #expect(gate.session == nil && gate.pool?.reservedRacks == 0)
        #expect(!gate.timedOut)
    }

    @Test func controlsCancelOrdinaryRollingAnalysisThenReplaceTheNextEligibleSuccessor() throws {
        let initial = Controls(energy: 0.2, tempo: 90)
        let preparer = try preparer()
        let gate = ControlsAnalysisGate()
        let worker = try SessionPreparationWorker(
            initialControls: initial,
            makeCancellation: {
                PreparationCancellation(analysisCheckpoint: { gate.observe($0) })
            },
            prepare: { token in
                let session = try PreparedSession(
                    controls: initial, preparer: preparer, cancellation: token)
                gate.session = session
                gate.pool = session.pool
                gate.firstFrames = try #require(session.first?.layout.inputFrames)
                return session
            })
        defer {
            gate.resume.signal()
            worker.requestStop()
            worker.join()
        }
        let endpoint = try worker.makeRenderEndpoint()
        let firstSelection = try #require(worker.listeningSnapshot?.selectionID)
        // A real prepared Next retires A after its earliest eligible phrase. The subsequent
        // prepareNext remains ordinary rolling work, with the same cancellation/ownership.
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
        let retirement = UInt64(gate.firstFrames) - advance + 1024
        while gate.entered.wait(timeout: .now()) != .success {
            try #require(ContinuousClock.now < deadline)
            if endpoint.position < retirement {
                let frames = min(8192, Int(retirement - endpoint.position))
                _ = try #require(
                    output.withUnsafeMutableBufferPointer {
                        endpoint.render(
                            into: UnsafeMutableBufferPointer(rebasing: $0[..<(frames * 2)]))
                    })
            }
            usleep(1000)
        }
        #expect(worker.listeningSnapshot?.selectionID == firstSelection + 1)
        #expect(endpoint.position < UInt64(gate.firstFrames))
        let request = try SessionControlsRequest(
            revision: 2, controls: Controls(energy: 0.3, mood: 0.5, tempo: 100))
        try #require(worker.listeningSnapshot?.nextSong?.controls != request.controls)
        #expect(worker.setControls(request))
        gate.resume.signal()
        let completion = ContinuousClock.now.advanced(by: .seconds(600))
        try awaitAdoption(
            worker, endpoint: endpoint, controls: request.controls, deadline: completion)
        while worker.controlsSnapshot.appliedRevision != 2 {
            try #require(ContinuousClock.now < completion)
            _ = try #require(
                output.withUnsafeMutableBufferPointer {
                    endpoint.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<512]))
                })
            try #require(worker.lastError == nil && worker.controlsError == nil)
            usleep(1000)
        }
        #expect(worker.controlsSnapshot.applied == request.controls)
        worker.requestStop()
        worker.join()
        #expect(gate.fired && !gate.timedOut)
        #expect(gate.session?.sequence?.acceptedControlsRevision == 2)
        #expect(gate.pool?.reservedRacks == 2)
        #expect(gate.session?.stolenVoices == 0 && gate.session?.droppedEvents == 0)
    }

}
