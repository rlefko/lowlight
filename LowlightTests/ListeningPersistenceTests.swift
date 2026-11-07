// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

@testable import Lowlight

struct ListeningPersistenceTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func intent(frame: UInt64) throws -> SessionRestartIntent {
        let planning = try SessionPlanning()
        _ = try planning.next()
        return try SessionRestartIntent(checkpoint: planning.checkpoint(), canonicalFrame: frame)
    }

    @Test func missingIsSilentAndAtomicReplacementRestoresOnlyMusicalIntent() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/listening.json")
        let store = ListeningPersistence.disk(at: url)
        #expect(try await store.load() == nil)
        let first = try ListeningRecord(controls: .preset(.relax), restart: intent(frame: 1234))
        try await store.save(first)
        #expect(try await store.load() == first)
        let second = try ListeningRecord(controls: .preset(.workout), restart: intent(frame: 9876))
        try await store.save(second)
        #expect(try await store.load() == second)
        #expect(try Data(contentsOf: url) == second.encoded())
        let entries = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == ["listening.json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object.keys.sorted() == ["controls", "formatVersion", "restartData"])
    }

    @Test func unreadableOrInvalidFilesArePreservedForAnExplicitFreshStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let store = ListeningPersistence.disk(at: url)
        let invalid: [Data] = [
            Data(), Data("{unfinished".utf8),
            Data(repeating: 32, count: ListeningRecord.maximumEncodedByteCount + 1),
            Data("{\"formatVersion\":999,\"checkpoint\":\"\"}".utf8),
        ]
        for data in invalid {
            try data.write(to: url)
            await #expect(throws: (any Error).self) { try await store.load() }
            #expect(try Data(contentsOf: url) == data)
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) {
            try await store.save(ListeningRecord(controls: Controls(), restart: intent(frame: 1)))
        }
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func aFailedReplacementLeavesThePreviouslySavedFileIntact() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let store = ListeningPersistence.disk(at: url)
        let saved = try ListeningRecord(controls: Controls(), restart: intent(frame: 321))
        try await store.save(saved)
        // A regular file cannot be used as the parent directory of a replacement.
        let blocked = ListeningPersistence.disk(at: url.appendingPathComponent("child"))
        await #expect(throws: (any Error).self) {
            try await blocked.save(
                ListeningRecord(controls: Controls(), restart: intent(frame: 456)))
        }
        #expect(try await store.load() == saved)
    }

    @Test func invalidLocationsFailAndDoNotBecomeAnEmptySession() async throws {
        let remote = try #require(URL(string: "https://example.invalid/listening.json"))
        let store = ListeningPersistence.disk(at: remote)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) {
            try await store.save(ListeningRecord(controls: Controls(), restart: intent(frame: 0)))
        }
    }

    @Test func settingsOnlyRecordsRoundTripBeforeFirstPlay() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ListeningPersistence.disk(at: root.appendingPathComponent("listening.json"))
        let settings = try ListeningRecord(controls: .preset(.reflective), sessionSeed: .max)
        try await store.save(settings)
        #expect(try await store.load() == settings)
        #expect(try await store.load()?.restart == nil)
    }

    @Test func legacyIntentMigratesOnlyWhenASaveSucceeds() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let restart = try intent(frame: 789)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "checkpoint": restart.checkpoint.base64EncodedString(),
        ])
        try legacy.write(to: url)
        let store = ListeningPersistence.disk(at: url)
        let loaded = try #require(await store.load())
        #expect(loaded.restart == restart && loaded.controls == restart.currentSong.controls)
        #expect(try Data(contentsOf: url) == legacy)
        try await store.save(loaded)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(saved["formatVersion"] as? Int == 2)
        #expect(try await store.load() == loaded)
    }

    @Test func standaloneAnchoredRestartMigratesWithoutLosingItsPlanningBasis() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let planning = try SessionPlanning(controls: .preset(.relax))
        let anchor = try planning.checkpoint()
        _ = try planning.next()
        let restart = try SessionRestartIntent(
            checkpoint: planning.checkpoint(), canonicalFrame: 456)
        let standalone = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 2, "checkpoint": restart.checkpoint.base64EncodedString(),
            "planningAnchor": anchor.base64EncodedString(),
        ])
        try standalone.write(to: url)
        let store = ListeningPersistence.disk(at: url)
        let loaded = try #require(await store.load())
        let retained = try #require(loaded.restart)
        #expect(retained.checkpoint == restart.checkpoint && retained.canonicalFrame == 456)
        #expect(loaded.controls == (try Controls.preset(.relax)))
        let nested = try #require(
            JSONSerialization.jsonObject(with: retained.encoded()) as? [String: Any])
        #expect(nested["planningAnchor"] as? String == anchor.base64EncodedString())
        #expect(try Data(contentsOf: url) == standalone)
        try await store.save(loaded)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(saved.keys.sorted() == ["controls", "formatVersion", "restartData"])
        #expect(try await store.load() == loaded)
    }

    @Test func invalidSavedControlsAndNestedRestartsAreRejectedWithoutChangingTheFile() async throws
    {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let store = ListeningPersistence.disk(at: url)
        let valid = try ListeningRecord(controls: .preset(.focus)).encoded()
        var malformedControls = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var controls = try #require(malformedControls["controls"] as? [String: Any])
        controls["energy"] = 2
        malformedControls["controls"] = controls
        var malformedRestart = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        malformedRestart["restartData"] = Data("invalid".utf8).base64EncodedString()
        var missingControls = malformedRestart
        missingControls.removeValue(forKey: "controls")
        var ambiguous = missingControls
        ambiguous["checkpoint"] = try intent(frame: 0).checkpoint.base64EncodedString()
        let invalidStandalone: [String: Any] = [
            "formatVersion": 2, "checkpoint": Data("invalid".utf8).base64EncodedString(),
        ]
        for object in [
            malformedControls, malformedRestart, missingControls, ambiguous, invalidStandalone,
            ["formatVersion": 2],
        ] {
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: url)
            await #expect(throws: (any Error).self) { try await store.load() }
            #expect(try Data(contentsOf: url) == data)
        }
    }

}
