// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct SessionControlsPlanningTests {
    private func sequence(restart: SessionRestartIntent? = nil) throws -> SessionListeningSequence {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let result = try SessionListeningSequence(
            seed: 91_031, controls: Controls(), restart: restart,
            preparer: TonalSamplePreparer(
                bankURL: root.appendingPathComponent("Lowlight/SoundBank")))
        _ = try result.pendingRecord()
        result.accepted()
        _ = try result.pendingRecord()
        result.accepted()
        return result
    }

    private func request(_ revision: UInt64, _ preset: Preset = .workout) throws
        -> SessionControlsRequest
    {
        try SessionControlsRequest(revision: revision, controls: Controls.preset(preset))
    }

    private func boundary(_ plan: SessionControlsPlan) throws -> (UInt32, UInt32) {
        let start = plan.current.canonicalOrigin
        let frame = UInt64(try plan.current.schedule.frame(at: 32)) - start
        let outro = plan.successor.placement - plan.current.placement
        return (UInt32(frame), UInt32(outro - frame))
    }

    @Test func completeControlRequestsNormalizeBeforeAdmission() throws {
        let value = try SessionControlsRequest(
            revision: .max,
            controls: Controls(
                energy: -2, mood: 2, warmth: 2, space: -2, texture: 2, variation: 2, tempo: 200))
        #expect(value.revision == .max)
        #expect(
            value.controls
                == Controls(
                    energy: 0, mood: 1, warmth: 1, space: 0, texture: 1, variation: 1, tempo: 100))
        #expect(throws: SessionControlsError.invalidRevision) {
            try SessionControlsRequest(revision: 0, controls: Controls())
        }
        for invalid in [
            Controls(energy: .nan), Controls(mood: .infinity), Controls(warmth: -.infinity),
            Controls(space: .nan), Controls(texture: .infinity), Controls(variation: .nan),
            Controls(tempo: .infinity),
        ] {
            #expect(throws: PlanningError.invalidControls) {
                try SessionControlsRequest(revision: 1, controls: invalid)
            }
        }
    }

    @Test func discardedPreviewsPreserveCanonicalHistoryAndRetryTheSameAnchor() throws {
        let sequence = try sequence()
        let original = sequence.records
        let capture = try sequence.capture(at: 12_345)
        for revision in UInt64(1)...20 {
            let preset = Preset.allCases[Int(revision) % Preset.allCases.count]
            _ = try #require(try sequence.planControls(request(revision, preset), selectionID: 0))
            #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
            #expect(try sequence.capture(at: 12_345) == capture)
        }
        let latest = try request(21, .reflective)
        let candidate = try #require(try sequence.planControls(latest, selectionID: 0))
        let retry = try #require(try sequence.planControls(latest, selectionID: 0))
        #expect(candidate.current == retry.current && candidate.successor == retry.successor)

        // Existing planning APIs independently generate the one requested branch. They
        // never saw the discarded default successor or any intermediate control previews.
        let reference = try SessionPlanning()
        try reference.setControls(latest.controls)
        let expectedAnchor = try reference.checkpoint()
        let expectedCurrent = try reference.next()
        let expectedCurrentCheckpoint = try reference.checkpoint()
        let expectedSuccessor = try reference.next()
        #expect(candidate.current.planningAnchor == expectedAnchor)
        #expect(candidate.current.schedule == expectedCurrent)
        #expect(candidate.current.checkpoint == expectedCurrentCheckpoint)
        #expect(candidate.current.schedule.song == original[0].schedule.song)
        #expect(candidate.successor.schedule == expectedSuccessor)
        #expect(candidate.successor.checkpoint == (try reference.checkpoint()))
        #expect(candidate.successor.planningAnchor == expectedCurrentCheckpoint)
        #expect(candidate.successor.schedule.song.controls == latest.controls)
        #expect(candidate.current.schedule.outgoing == candidate.successor.schedule.incoming)
    }

    @Test func onlyMatchingAdoptionCommitsHistoryAndSharedPlacement() throws {
        let sequence = try sequence()
        let original = sequence.records
        let old = try #require(try sequence.planControls(request(1, .relax), selectionID: 0))
        let plan = try #require(try sequence.planControls(request(2), selectionID: 0))
        let (boundary, delta) = try boundary(plan)
        #expect(throws: SessionControlsError.stalePlan) {
            try sequence.acceptControls(old, expectedRevision: 2, boundary: boundary, delta: delta)
        }
        #expect(throws: SessionControlsError.stalePlan) {
            try sequence.acceptControls(
                plan, expectedRevision: 2, boundary: boundary, delta: delta + 1)
        }
        #expect(sequence.records == original && sequence.acceptedControlsRevision == 0)
        try sequence.acceptControls(plan, expectedRevision: 2, boundary: boundary, delta: delta)
        #expect(sequence.acceptedControlsRevision == 2)
        let accepted = sequence.records
        #expect(accepted[0].schedule.song == original[0].schedule.song)
        #expect(accepted[1].placement == UInt64(boundary))
        #expect(accepted[1].handoff == plan.successor.handoff - UInt64(delta))
        let before = try #require(try sequence.capture(at: UInt64(boundary) - 1))
        #expect(before.canonicalFrame == UInt64(boundary) - 1)
        let bridge = try #require(try sequence.capture(at: UInt64(boundary)))
        #expect(bridge.canonicalFrame == plan.successor.canonicalOrigin)
        #expect(try SessionRestartIntent.restore(bridge.restart.encoded()) == bridge.restart)
        let selected = try #require(try sequence.capture(at: accepted[1].handoff))
        #expect(selected.currentSong.controls == plan.request.controls)
        #expect(selected.currentSong.id == 1 && selected.restart.planningAnchor != nil)
        #expect(try SessionRestartIntent.restore(selected.restart.encoded()) == selected.restart)
        #expect(throws: SessionControlsError.stalePlan) {
            try sequence.acceptControls(old, expectedRevision: 1, boundary: boundary, delta: delta)
        }
        #expect(throws: SessionControlsError.stalePlan) {
            try sequence.acceptControls(plan, expectedRevision: 2, boundary: boundary, delta: delta)
        }
        #expect(sequence.records == accepted)
        #expect(try sequence.planControls(request(3), selectionID: 0) == nil)
        #expect(try sequence.planControls(request(3), selectionID: 1) == nil)

        let reference = try SessionPlanning.restore(plan.successor.checkpoint)
        let expectedFollowing = try reference.next()
        sequence.retired()
        let following = try sequence.pendingRecord()
        #expect(following.schedule == expectedFollowing)
        #expect(following.placement == plan.followingOrigin - UInt64(delta))
        #expect(following.checkpoint == (try reference.checkpoint()))
        sequence.accepted()
        #expect(try sequence.planControls(request(3, .relax), selectionID: 1) != nil)
    }

    @Test func acceptedNextAndRetirementInvalidateSpeculation() throws {
        let sequence = try sequence()
        let plan = try #require(try sequence.planControls(request(1), selectionID: 0))
        let (boundary, delta) = try boundary(plan)
        try sequence.advanced(targetOrigin: 0, boundary: boundary, delta: delta)
        let advanced = sequence.records
        #expect(throws: SessionControlsError.stalePlan) {
            try sequence.acceptControls(plan, expectedRevision: 1, boundary: boundary, delta: delta)
        }
        #expect(sequence.records == advanced && sequence.acceptedControlsRevision == 0)
        sequence.retired()
        _ = try sequence.pendingRecord()
        sequence.accepted()
        #expect(throws: SessionControlsError.stalePlan) {
            try sequence.acceptControls(plan, expectedRevision: 1, boundary: boundary, delta: delta)
        }
    }

    @Test func legacyRestoreKeepsOriginalSuccessorUntilAnAnchoredSongIsSelected() throws {
        let sequence = try sequence()
        let captured = try #require(try sequence.capture(at: 1234))
        let legacy = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "checkpoint": captured.restart.checkpoint.base64EncodedString(),
        ])
        let restored = try SessionRestartIntent.restore(legacy)
        #expect(restored.planningAnchor == nil && restored.currentSong == captured.currentSong)
        let resumed = try self.sequence(restart: restored)
        #expect(resumed.warmFrames == 1234)
        #expect(resumed.records.map(\.schedule) == sequence.records.map(\.schedule))
        #expect(resumed.records[0].planningAnchor == nil)
        #expect(try resumed.planControls(request(1), selectionID: 0) == nil)
        #expect(resumed.records[1].planningAnchor != nil)
        resumed.retired()
        _ = try resumed.pendingRecord()
        resumed.accepted()
        #expect(try resumed.planControls(request(1), selectionID: 1) != nil)
    }

    @Test func anchorsSurviveNumericModesAndRequireExactCheckpointReproduction() throws {
        let sequence = try sequence()
        let record = sequence.records[0]
        let anchor = try #require(record.planningAnchor)
        let expected = try SessionRestartIntent(
            checkpoint: record.checkpoint, canonicalFrame: 548_000, planningAnchor: anchor)
        for mode in UInt32(0)..<4 {
            let restored = try PreparationModeTests().environment(
                mode, ll_test_flush_modes() - 1, true
            ) {
                try SessionRestartIntent.restore(expected.encoded())
            }
            #expect(restored == expected)
            #expect(try restored.encoded() == expected.encoded())
        }
        let other = try SessionPlanning(seed: 111)
        for wrong in [
            record.checkpoint, try other.checkpoint(), anchor.dropLast(),
            Data(repeating: 0, count: SessionTimeline.maximumCheckpointByteCount + 1),
        ] {
            #expect(throws: (any Error).self) {
                try SessionRestartIntent(
                    checkpoint: record.checkpoint, canonicalFrame: 548_000, planningAnchor: wrong)
            }
        }
        var object = try #require(
            JSONSerialization.jsonObject(with: expected.encoded()) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 2)
        #expect(SessionRestartIntent.maximumEncodedByteCount == 524_288)
        object["formatVersion"] = 1
        #expect(throws: SessionRestartError.invalidIntent) {
            try SessionRestartIntent.restore(JSONSerialization.data(withJSONObject: object))
        }
        let resumed = try self.sequence(restart: expected)
        #expect(resumed.records[0].planningAnchor == anchor)
        #expect(try resumed.planControls(request(1), selectionID: 0) != nil)
    }
}
