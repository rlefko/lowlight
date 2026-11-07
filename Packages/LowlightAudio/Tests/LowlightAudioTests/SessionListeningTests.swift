// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import CryptoKit
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct SessionListeningTests {
    private var controls: Controls {
        Controls(
            energy: 0.58, mood: 0.35, warmth: 0.86, space: 0.42, texture: 0.08,
            variation: 0.60, tempo: 60)
    }

    private func preparer() throws -> TonalSamplePreparer {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try TonalSamplePreparer(bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
    }

    @Test func restartUsesCurrentCheckpointAndPreservesFuturePlanningAcrossCallerModes() throws {
        let planning = try SessionPlanning(controls: controls)
        var checkpoints: [Data] = []
        var schedules: [SongSchedule] = []
        for index in 0..<6 {
            if index == 1 {
                var value = controls
                value.tempo = 100
                try planning.setControls(value)
            }
            if index == 3 { try planning.setControls(controls) }
            schedules.append(try planning.next())
            checkpoints.append(try planning.checkpoint())
        }
        // PR35's independently frozen canonical clock probes, unchanged by transport.
        let frame: UInt64 = 7_581_914
        for rounding in UInt32(0)..<4 {
            let restart = try PreparationModeTests().environment(
                rounding, ll_test_flush_modes() - 1, true
            ) {
                try SessionRestartIntent(checkpoint: checkpoints[2], canonicalFrame: frame)
            }
            #expect(restart.currentSong == schedules[2].song)
            let encoded = try restart.encoded()
            #expect(try SessionRestartIntent.restore(encoded) == restart)
            #expect(try SessionRestartIntent.restore(encoded).encoded() == encoded)
            let restored = try SessionPlanning.restore(restart.checkpoint)
            #expect(restored.current == schedules[2] && restored.positionFrame == Int64(frame))
            try restored.setControls(controls)
            for expected in schedules.dropFirst(3) { #expect(try restored.next() == expected) }
            // The ahead-of-render cursor remains independent and unchanged.
            #expect(try planning.checkpoint() == checkpoints[5])
        }
    }

    @Test(arguments: [false, true])
    func oldRestartsKeepTheirExactSongAndFrameUntilAnEvolvingSuccessor(anchored: Bool) throws {
        let classic = try SessionPlanning(controls: controls, edition: .classic)
        _ = try classic.next()
        let anchor = try classic.checkpoint()
        let selected = try classic.next()
        let frame = UInt64(try selected.frame(at: 5))
        let old = try SessionRestartIntent(
            checkpoint: classic.checkpoint(), canonicalFrame: frame,
            planningAnchor: anchored ? anchor : nil)
        // Digests were produced independently by the merged PR 52 binary at 3bb95d9.
        let expectedDigest =
            anchored
            ? "475bc6d8c5f39c04cb36209aae2f77c948c9b70c530b6675fb844c3b9779a69b"
            : "8a445ca33f2cc31b4a4c3af0c4dde64e187192cb71e9456c6ee68842797ae6f7"
        let digest = SHA256.hash(data: try old.encoded()).map { String(format: "%02x", $0) }
            .joined()
        #expect(digest == expectedDigest)
        let oldSuccessor = try classic.next()

        let sequence = try SessionListeningSequence(
            seed: 42, controls: Controls(), edition: .evolving, restart: old, preparer: preparer())
        let first = try sequence.pendingRecord()
        sequence.accepted()
        let second = try sequence.pendingRecord()
        sequence.accepted()
        #expect(first.schedule == selected && first.checkpoint == old.checkpoint)
        #expect(UInt64(sequence.warmFrames) + first.canonicalOrigin == frame)
        #expect(try sequence.capture(at: UInt64(sequence.warmFrames))?.restart == old)
        #expect(try sequence.capture(at: second.handoff - 1)?.currentSong == selected.song)
        #expect(second.schedule.song.id == oldSuccessor.song.id)
        #expect(
            second.schedule.incoming == selected.outgoing && second.schedule.song.ensemble != nil)
        let handoff = try #require(try sequence.capture(at: second.handoff))
        #expect(handoff.currentSong == second.schedule.song)
        #expect(try SessionRestartIntent.restore(handoff.restart.encoded()) == handoff.restart)

        let request = try SessionControlsRequest(revision: 1, controls: .preset(.workout))
        let plan = try sequence.planControls(request, selectionID: selected.song.id)
        guard anchored else {
            #expect(plan == nil)
            return
        }
        let revised = try #require(plan)
        #expect(revised.current.schedule.song == selected.song)
        #expect(revised.successor.schedule.song.ensemble != nil)
        #expect(revised.successor.schedule.incoming == revised.current.schedule.outgoing)
        // Both candidate anchors must independently reproduce the exact checkpoint that
        // would be saved on their side of the handoff.
        _ = try SessionRestartIntent(
            checkpoint: revised.current.checkpoint, canonicalFrame: frame,
            planningAnchor: revised.current.planningAnchor)
        _ = try SessionRestartIntent(
            checkpoint: revised.successor.checkpoint,
            canonicalFrame: revised.successor.canonicalOrigin,
            planningAnchor: revised.successor.planningAnchor)
    }

    @Test func anOlderCrossfadeKeepsEachAlreadyStartedSongAndPromotesTheNextUnheardOne() throws {
        let classic = try SessionListeningSequence(
            seed: 91_031, controls: controls, edition: .classic, restart: nil, preparer: preparer())
        let a = try classic.pendingRecord()
        classic.accepted()
        let b = try classic.pendingRecord()
        classic.accepted()
        let request = try SessionControlsRequest(revision: 1, controls: .preset(.workout))
        let frames = [b.placement - 1, b.placement, b.handoff - 1, b.handoff, b.handoff + 1]
        for frame in frames {
            let saved = try #require(try classic.capture(at: frame))
            let resumed = try SessionListeningSequence(
                seed: 0, controls: controls, edition: .evolving, restart: saved.restart,
                preparer: preparer())
            let selected = try resumed.pendingRecord()
            resumed.accepted()
            let incoming = try resumed.pendingRecord()
            resumed.accepted()
            #expect(try resumed.capture(at: UInt64(resumed.warmFrames))?.restart == saved.restart)
            if (b.placement..<b.handoff).contains(frame) {
                #expect(selected.schedule == a.schedule && incoming.schedule == b.schedule)
                #expect(try resumed.planControls(request, selectionID: a.schedule.song.id) == nil)
                let handed = try #require(try resumed.capture(at: incoming.handoff))
                #expect(handed.currentSong == b.schedule.song)
                resumed.retired()
                let unheard = try resumed.pendingRecord()
                resumed.accepted()
                #expect(unheard.schedule.song.ensemble != nil)
                #expect(unheard.schedule.incoming == b.schedule.outgoing)
                let revised = try #require(
                    try resumed.planControls(request, selectionID: b.schedule.song.id))
                #expect(revised.current.schedule.song == b.schedule.song)
                #expect(revised.successor.schedule.song.ensemble != nil)
            } else {
                #expect(selected.schedule == (frame < b.placement ? a.schedule : b.schedule))
                #expect(incoming.schedule.song.ensemble != nil)
            }
        }
    }

    @Test func freshSeedsChooseRepeatableEvolvingSongsAndSuccessors() throws {
        let first = try SessionPlanning(seed: 191, controls: controls, edition: .evolving)
        let retry = try SessionPlanning(seed: 191, controls: controls, edition: .evolving)
        let separate = try SessionPlanning(seed: 192, controls: controls, edition: .evolving)
        let start = try first.next()
        #expect(start.song.ensemble != nil)
        #expect(try retry.next() == start)
        #expect(try separate.next().song.signature != start.song.signature)
        let next = try first.next()
        #expect(next.song.ensemble != nil && next.song.ensemble != start.song.ensemble)
        #expect(try retry.next() == next)
    }

    @Test func malformedAndOutOfSongIntentsCannotBecomePlaybackOrUnboundedWarmup() throws {
        let planning = try SessionPlanning(controls: controls)
        #expect(throws: SessionRestartError.invalidIntent) {
            try SessionRestartIntent(checkpoint: planning.checkpoint(), canonicalFrame: 0)
        }
        let current = try planning.next()
        let checkpoint = try planning.checkpoint()
        let end = try planning.frame(at: Double(current.song.bars * 4))
        for value in [UInt64(end + 1), UInt64.max] {
            #expect(throws: (any Error).self) {
                try SessionRestartIntent(checkpoint: checkpoint, canonicalFrame: value)
            }
        }
        let valid = try SessionRestartIntent(checkpoint: checkpoint, canonicalFrame: 548_000)
        var object = try #require(
            JSONSerialization.jsonObject(with: valid.encoded()) as? [String: Any])
        object["formatVersion"] = 99
        #expect(throws: SessionRestartError.unsupportedVersion) {
            try SessionRestartIntent.restore(JSONSerialization.data(withJSONObject: object))
        }
        for data in [
            Data("{".utf8), Data(),
            Data(repeating: 32, count: SessionRestartIntent.maximumEncodedByteCount + 1),
        ] {
            #expect(throws: SessionRestartError.invalidIntent) {
                try SessionRestartIntent.restore(data)
            }
        }
        #expect(try planning.checkpoint() == checkpoint)
    }

    @Test func admittedMetadataSwitchesAtRhythmHandoffAndMovesOnlyOnAcceptedAdvance() throws {
        let sequence = try SessionListeningSequence(
            seed: 91_031, controls: controls, restart: nil, preparer: preparer())
        let first = try sequence.pendingRecord()
        sequence.accepted()
        let second = try sequence.pendingRecord()
        sequence.accepted()
        #expect(try sequence.capture(at: second.handoff - 1)?.selectionID == first.schedule.song.id)
        let handed = try #require(try sequence.capture(at: second.handoff))
        #expect(handed.selectionID == second.schedule.song.id)
        #expect(handed.canonicalFrame == second.handoff)
        let boundary = try #require(
            try sequence.advanceBoundary(
                for: first.schedule.song.id, after: 0, before: UInt32(second.placement)))
        #expect(boundary.0 == 1_024_000)
        let delta = UInt32(second.placement) - boundary.0
        let before = try #require(try sequence.capture(at: UInt64(boundary.0) - 1))
        try sequence.advanced(targetOrigin: 0, boundary: boundary.0, delta: delta)
        #expect(try sequence.capture(at: UInt64(boundary.0) - 1) == before)
        #expect(try sequence.capture(at: UInt64(boundary.0))?.canonicalFrame == second.placement)
        let shifted = second.handoff - UInt64(delta)
        #expect(try sequence.capture(at: shifted - 1)?.selectionID == first.schedule.song.id)
        let captured = try #require(try sequence.capture(at: shifted))
        #expect(captured.selectionID == second.schedule.song.id)
        #expect(captured.canonicalFrame == second.handoff)
        sequence.retired()
        let third = try sequence.pendingRecord()
        #expect(third.placement == UInt64(try third.schedule.frame(at: 0)) - UInt64(delta))
        let restored = try SessionListeningSequence(
            seed: 1, controls: Controls(), restart: captured.restart, preparer: preparer())
        let local = try restored.pendingRecord()
        #expect(local.schedule == second.schedule && local.placement == 0)
        #expect(restored.warmFrames == second.handoff - second.canonicalOrigin)
        #expect(
            try sequence.advanceBoundary(
                for: second.schedule.song.id, after: UInt32.max, before: UInt32.max) == nil)
    }
}
