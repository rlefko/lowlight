// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
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
        let first = try intent(frame: 1234)
        try await store.save(first)
        #expect(try await store.load() == first)
        let second = try intent(frame: 9876)
        try await store.save(second)
        #expect(try await store.load() == second)
        #expect(try Data(contentsOf: url) == second.encoded())
        let entries = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == ["listening.json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object.keys.sorted() == ["checkpoint", "formatVersion"])
    }

    @Test func unreadableOrInvalidFilesArePreservedForAnExplicitFreshStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let store = ListeningPersistence.disk(at: url)
        let invalid: [Data] = [
            Data(), Data("{unfinished".utf8),
            Data(repeating: 32, count: SessionRestartIntent.maximumEncodedByteCount + 1),
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
        await #expect(throws: (any Error).self) { try await store.save(intent(frame: 1)) }
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func aFailedReplacementLeavesThePreviouslySavedFileIntact() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json")
        let store = ListeningPersistence.disk(at: url)
        let saved = try intent(frame: 321)
        try await store.save(saved)
        // A regular file cannot be used as the parent directory of a replacement.
        let blocked = ListeningPersistence.disk(at: url.appendingPathComponent("child"))
        await #expect(throws: (any Error).self) { try await blocked.save(intent(frame: 456)) }
        #expect(try await store.load() == saved)
    }

    @Test func invalidLocationsFailAndDoNotBecomeAnEmptySession() async throws {
        let remote = try #require(URL(string: "https://example.invalid/listening.json"))
        let store = ListeningPersistence.disk(at: remote)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save(intent(frame: 0)) }
    }
}
