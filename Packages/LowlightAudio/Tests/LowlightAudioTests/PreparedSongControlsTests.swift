// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let controlsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized)
struct PreparedSongControlsTests {
    private func schedules() throws -> (SongSchedule, SongSchedule, SongSchedule, SongSchedule) {
        var old = try SongPlanner()
        var revised = old
        let first = try old.next()
        let firstSchedule = try SongSchedule(song: first, successor: old.pending)
        let second = try old.next()
        let secondSchedule = try SongSchedule(
            song: second, successor: old.pending, incoming: firstSchedule.outgoing)
        try revised.setControls(.preset(.reflective))
        #expect(try revised.next() == first)
        let newFirst = try SongSchedule(song: first, successor: revised.pending)
        let newSecondSong = try revised.next()
        let newSecond = try SongSchedule(
            song: newSecondSong, successor: revised.pending, incoming: newFirst.outgoing)
        return (firstSchedule, secondSchedule, newFirst, newSecond)
    }

    @Test func presetBridgeUsesExistingArenaAndReleasesOldSuccessorBeforeReplacement() throws {
        try PreparationMode.perform {
            let (a, b, revisedA, revisedB) = try schedules()
            let preparer = try TonalSamplePreparer(
                bankURL: controlsRoot.appendingPathComponent("Lowlight/SoundBank"))
            let pool = SongPreparationPool()
            let first = try pool.prepare(schedule: a, preparer: preparer)
            var second: PreparedSong? = try pool.prepare(schedule: b, preparer: preparer)
            weak let oldSuccessor = second
            let secondHandle = try #require(second?.borrowedHandle)
            let originalGain = first.linearMultiplier
            let originalBytes = first.preparedBytes
            let pair = try #require(
                ll_song_pair_create_transport(
                    first.borrowedHandle, secondHandle,
                    UInt64(try b.frame(at: 0)), 0,
                    UInt64(try b.outgoing.ramp.frame(at: 0))))
            let token = try #require(ll_song_revision_create())
            var change: PreparedSongControlChange?
            defer {
                ll_song_pair_destroy(pair)
                // first retains an accepted patch through native source destruction.
                withExtendedLifetime((first, second, change)) {}
                ll_song_revision_destroy(token)
            }
            #expect(ll_song_revision_set(token, 1))
            #expect(ll_song_pair_request_change(pair, 0, 1, token))
            try pull(pair, count: 1)
            var offer = LLSongChangeOffer()
            #expect(ll_song_pair_claim_change(pair, &offer))
            let boundary = UInt32(try a.frame(at: 32))
            let prepared = try first.makeControlChange(
                offer: offer, revisedSchedule: revisedA, boundaryFrames: boundary,
                preparer: preparer)
            change = prepared
            #expect(prepared.preparedBytes >= originalBytes)
            #expect(prepared.preparedBytes <= SongPreparationPool.pcmBytesPerRack)
            #expect(pool.reservedRacks == 2)
            #expect(ll_song_pair_withdraw_change(pair, prepared.handle))
            try pull(pair, count: 1)
            var retired: OpaquePointer?
            #expect(ll_song_pair_claim_withdrawn_change(pair, &retired))
            #expect(retired == secondHandle)
            second = nil
            #expect(oldSuccessor == nil && pool.reservedRacks == 1)
            try first.retainControlChange(prepared)
            second = try pool.prepare(schedule: revisedB, preparer: preparer)
            #expect(pool.reservedRacks == 2 && pool.reservedVoiceSlots <= 64)
            let replacement = try #require(second?.borrowedHandle)
            let following =
                UInt64(try revisedB.outgoing.ramp.frame(at: 0))
                - UInt64(prepared.advancedFrames)
            #expect(ll_song_pair_publish_change(pair, prepared.handle, replacement, following))
            try pull(pair, count: 1)
            var result = LLSongChangeResult()
            #expect(ll_song_pair_change_result(pair, &result))
            #expect(result.status == 1 && result.boundary_frames == boundary)
            #expect(first.linearMultiplier == originalGain)
            #expect(first.preparedBytes == prepared.preparedBytes)
            #expect(pool.preparedPCMBytes == first.preparedBytes + (second?.preparedBytes ?? 0))
            try pull(pair, count: Int(boundary) + 32_000)
            #expect(!ll_song_pair_faulted(pair))
        }
    }

    @Test func staleIntentAndNonShorteningRampLeaveOriginalRackUnchanged() throws {
        try PreparationMode.perform {
            let (a, b, revisedA, _) = try schedules()
            let preparer = try TonalSamplePreparer(
                bankURL: controlsRoot.appendingPathComponent("Lowlight/SoundBank"))
            let first = try PreparedSong(schedule: a, preparer: preparer)
            let second = try PreparedSong(schedule: b, preparer: preparer)
            let originalBytes = first.preparedBytes
            let token = try #require(ll_song_revision_create())
            defer { ll_song_revision_destroy(token) }
            #expect(ll_song_revision_set(token, 1))
            let oldOutro = UInt32(try a.outgoing.ramp.frame(at: 0))
            var offer = LLSongChangeOffer()
            offer.first = first.borrowedHandle
            offer.second = second.borrowedHandle
            offer.intent = token
            offer.revision = 1
            offer.outro_start_frames = oldOutro
            offer.original_frames = first.layout.inputFrames
            #expect(try SongRenderLayout(schedule: revisedA).inputFrames > first.layout.inputFrames)
            #expect(throws: PreparedSessionError.self) {
                try first.makeControlChange(
                    offer: offer, revisedSchedule: revisedA, boundaryFrames: oldOutro,
                    preparer: preparer)
            }
            #expect(ll_song_revision_set(token, 2))
            #expect(throws: PreparedSessionError.self) {
                try first.makeControlChange(
                    offer: offer, revisedSchedule: revisedA,
                    boundaryFrames: UInt32(a.frame(at: 32)), preparer: preparer)
            }
            #expect(first.preparedBytes == originalBytes && first.position == 0)
        }
    }

    private func pull(_ pair: OpaquePointer, count: Int) throws {
        var scratch = [Float](repeating: .nan, count: 2 * 4096)
        var remaining = count
        while remaining > 0 {
            var written: UInt32 = 0
            let requested = min(remaining, 4096)
            #expect(
                scratch.withUnsafeMutableBufferPointer {
                    ll_song_pair_render(pair, $0.baseAddress, UInt32(requested), &written)
                })
            try #require(written > 0 && written <= requested)
            #expect(scratch[..<(2 * Int(written))].allSatisfy { $0.isFinite })
            remaining -= Int(written)
        }
    }
}
