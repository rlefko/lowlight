// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
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
        object["formatVersion"] = 2
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
