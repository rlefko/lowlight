// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let poolRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized)
struct SongPreparationPoolTests {
    @Test func inclusiveVoiceBudgetAndRackLimitReleaseOnDestruction() throws {
        let pool = SongPreparationPool()
        let preparer = try bank()
        #expect(SongPreparationPool.maximumRacks == 2)
        #expect(SongPreparationPool.maximumVoiceSlots == 64)
        #expect(SongPreparationPool.pcmBytesPerRack == 32 * 1024 * 1024)
        check(pool, racks: 0, voices: 0, bytes: 0)
        var first: PreparedSong? = try make(pool, preparer, voices: 32)
        weak let firstLifetime = first
        #expect(first?.requiredVoiceSlots == 32 && first?.preparedBytes == 51_200)
        check(pool, racks: 1, voices: 32, bytes: 51_200)
        var second: PreparedSong? = try make(pool, preparer, voices: 32)
        try withExtendedLifetime((first, second)) {
            #expect(second?.requiredVoiceSlots == 32 && second?.preparedBytes == 51_200)
            check(pool, racks: 2, voices: 64, bytes: 102_400)
            do {
                _ = try make(pool, preparer)
                Issue.record("A third rack was admitted")
            } catch SongPreparationPoolError.rackCapacityExceeded {}
            var output = [Float](repeating: .nan, count: 512)
            #expect(output.withUnsafeMutableBufferPointer { first?.render(into: $0) } == 256)
            first?.reset()
            #expect(first?.position == 0 && first?.stolenVoices == 0)
            check(pool, racks: 2, voices: 64, bytes: 102_400)
        }
        first = nil
        #expect(firstLifetime == nil)
        withExtendedLifetime(second) { check(pool, racks: 1, voices: 32, bytes: 51_200) }
        second = nil
        check(pool, racks: 0, voices: 0, bytes: 0)
        let reused = try make(pool, preparer)
        withExtendedLifetime(reused) { check(pool, racks: 1, voices: 1, bytes: 51_200) }
    }

    @Test func voiceAndPreparationFailuresRestoreEveryReservation() throws {
        let pool = SongPreparationPool()
        let preparer = try bank()
        let retained = try make(pool, preparer, voices: 32)
        try withExtendedLifetime(retained) {
            do {
                _ = try make(pool, preparer, voices: 33, silent: true)
                Issue.record("A rack exceeding the remaining voice budget was admitted")
            } catch SongPreparationPoolError.voiceCapacityExceeded {}
            check(pool, racks: 1, voices: 32, bytes: 51_200)
            do {
                // One real reader and its PCM are claimed, but the incoming fade silences the body.
                _ = try make(pool, preparer, silent: true)
                Issue.record("An unmeasurable admitted body prepared a song")
            } catch PreparedSongError.unmeasurableBody {}
            check(pool, racks: 1, voices: 32, bytes: 51_200)

            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
                try FileManager.default.copyItem(
                    at: poolRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                    to: temporary.appendingPathComponent(name))
            }
            let missing = try TonalSamplePreparer(bankURL: temporary)
            do {
                _ = try make(pool, missing)
                Issue.record("Missing sample assets prepared an admitted song")
            } catch {
                #expect(!(error is SongPreparationPoolError))
            }
            check(pool, racks: 1, voices: 32, bytes: 51_200)
            let replacement = try make(pool, preparer, voices: 32)
            try withExtendedLifetime(replacement) {
                check(pool, racks: 2, voices: 64, bytes: 102_400)
                do {
                    _ = try make(pool, missing)
                    Issue.record("A third rack reached missing sample assets")
                } catch SongPreparationPoolError.rackCapacityExceeded {}
            }
        }
    }

    @Test func standaloneOverloadRemainsAvailableOutsideThePool() throws {
        let preparer = try bank()
        let pool = SongPreparationPool()
        do {
            _ = try make(pool, preparer, voices: 129)
            Issue.record("Standalone overload demand was admitted to the shared pool")
        } catch SongPreparationPoolError.voiceCapacityExceeded {}
        check(pool, racks: 0, voices: 0, bytes: 0)
        let standalone = try make(nil, preparer, voices: 129)
        #expect(standalone.requiredVoiceSlots == 129 && standalone.preparedBytes == 51_200)
        var output = [Float](repeating: .nan, count: 512)
        #expect(output.withUnsafeMutableBufferPointer { standalone.render(into: $0) } == 256)
        #expect(standalone.stolenVoices == 64 && standalone.droppedEvents == 1)
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite && !standalone.isFaulted)
        check(pool, racks: 0, voices: 0, bytes: 0)
    }

    private func check(_ pool: SongPreparationPool, racks: Int, voices: Int, bytes: Int) {
        #expect(pool.reservedRacks == racks && pool.reservedVoiceSlots == voices)
        #expect(pool.preparedPCMBytes == bytes)
        #expect(pool.reservedPCMBytes == racks * SongPreparationPool.pcmBytesPerRack)
    }

    private func bank() throws -> TonalSamplePreparer {
        try TonalSamplePreparer(bankURL: poolRoot.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func make(
        _ pool: SongPreparationPool?, _ preparer: TonalSamplePreparer,
        voices: Int = 1, silent: Bool = false
    ) throws -> PreparedSong {
        let record: [String: Any] = [
            "formatVersion": 1, "instrument": "guitar", "role": "chord", "articulation": "normal",
            "note": 60, "roundRobin": 0, "beat": 0, "velocity": 0.5, "pan": -0.25,
            "startFrame": 0, "gateEndFrame": 12_800, "releaseEndFrame": 12_800,
        ]
        let note = try JSONDecoder().decode(
            NoteEvent.self, from: JSONSerialization.data(withJSONObject: record))
        let events = Array(repeating: note, count: voices)
        let layout = try SongRenderLayout(
            frameOrigin: 0, inputFrames: 12_800, bodyFrames: 0..<12_800)
        let fades = SongRackFades(
            tonalInStartFrame: silent ? 20_000 : 0, tonalInEndFrame: silent ? 24_000 : 0,
            tonalOutStartFrame: 30_000, tonalOutEndFrame: 34_000, rhythmOutFrame: 32_000)
        if let pool {
            return try pool.prepare(
                layout: layout, preparer: preparer, events: events, takeSeed: 1, focus: .guitar,
                warmth: 0.78, energy: 0.35, space: 0.44, texture: 0, rackFades: fades)
        }
        return try PreparedSong(
            layout: layout, preparer: preparer, events: events, takeSeed: 1, focus: .guitar,
            warmth: 0.78, energy: 0.35, space: 0.44, texture: 0, rackFades: fades)
    }
}
