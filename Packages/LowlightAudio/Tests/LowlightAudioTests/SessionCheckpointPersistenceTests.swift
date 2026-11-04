// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CPreparationTestSupport
import Darwin
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct SessionCheckpointPersistenceTests {
    private let low = Controls(
        energy: 0.58, mood: 0.35, warmth: 0.86, space: 0.42, texture: 0.08,
        variation: 0.60, tempo: 60)
    private var high: Controls {
        var value = low
        value.tempo = 100
        return value
    }

    @Test func atomicReplacementPreservesV1BytesAndPlanningContinuation() throws {
        try directory { root in
            let file = root.appendingPathComponent("saved intent 🎵.json")
            let previous = root.appendingPathComponent("previous.json")
            var planning = try SessionPlanning(controls: low)
            var reference = try SessionTimeline(controls: low)
            let pristine = try reference.checkpoint()
            try planning.writeCheckpoint(to: file)
            #expect(try Data(contentsOf: file) == pristine)
            planning = try #require(try SessionPlanning.readCheckpoint(from: file))
            #expect(planning.current == nil && planning.positionFrame == nil)
            try FileManager.default.linkItem(at: file, to: previous)

            for index in 0..<6 {
                if index == 1 || index == 3 {
                    let controls = index == 1 ? high : low
                    try planning.setControls(controls)
                    try reference.setControls(controls)
                }
                let expected = try reference.next()
                #expect(try planning.next() == expected)
                let position = try expected.frame(at: 17.125)
                // Independent pre-owner PR35 clock probes, unchanged by persistence.
                if index == 0 { #expect(position == 548_000) }
                if index == 2 { #expect(position == 7_581_914) }
                try reference.setPosition(frame: position)
                try planning.setPosition(frame: position)
                let bytes = try reference.checkpoint()
                try planning.writeCheckpoint(to: file)
                #expect(try Data(contentsOf: file) == bytes)
                // An in-place rewrite would also change the retained hard link.
                #expect(try Data(contentsOf: previous) == pristine)
                planning = try #require(try SessionPlanning.readCheckpoint(from: file))
                #expect(planning.current == expected && planning.positionFrame == position)
                #expect(try planning.checkpoint() == bytes)
            }
            for _ in 0..<3 {
                #expect(try planning.next() == reference.next())
                #expect(planning.positionFrame == reference.positionFrame)
            }
            #expect(try planning.checkpoint() == reference.checkpoint())
            #expect(
                try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
                    == Set([file.lastPathComponent, previous.lastPathComponent]))
        }
    }

    @Test func boundedReadsRejectInvalidStateWithoutChangingStoredBytes() throws {
        try directory { root in
            let file = root.appendingPathComponent("checkpoint.json")
            let planning = try SessionPlanning(controls: low)
            _ = try planning.next()
            let valid = try planning.checkpoint()
            let limit = SessionTimeline.maximumCheckpointByteCount
            #expect(limit == 131_072)
            let padded = valid + Data(repeating: 32, count: limit - valid.count)
            try padded.write(to: file)
            let restored = try #require(try SessionPlanning.readCheckpoint(from: file))
            #expect(try restored.checkpoint() == valid)
            #expect(try Data(contentsOf: file) == padded)

            for bytes in [Data(), Data("{".utf8), Data(valid.dropLast()), padded + Data([32])] {
                try bytes.write(to: file)
                #expect(throws: TimelineError.invalidCheckpoint) {
                    _ = try SessionPlanning.readCheckpoint(from: file)
                }
                #expect(try Data(contentsOf: file) == bytes)
            }
            var object = try #require(
                try JSONSerialization.jsonObject(with: valid) as? [String: Any])
            object["version"] = -1
            let unsupported = try JSONSerialization.data(withJSONObject: object)
            try unsupported.write(to: file)
            #expect(throws: TimelineError.unsupportedVersion) {
                _ = try SessionPlanning.readCheckpoint(from: file)
            }
            #expect(try Data(contentsOf: file) == unsupported)
            object["version"] = SessionTimeline.version
            object["positionFrame"] = -1
            let inconsistent = try JSONSerialization.data(withJSONObject: object)
            try inconsistent.write(to: file)
            #expect(throws: TimelineError.invalidCheckpoint) {
                _ = try SessionPlanning.readCheckpoint(from: file)
            }
            #expect(try Data(contentsOf: file) == inconsistent)
            #expect(try planning.checkpoint() == valid)
        }
    }

    @Test func fileTransactionsRestoreCallerNumericStateOnSuccessAndFailure() throws {
        try directory { root in
            let file = root.appendingPathComponent("checkpoint.json")
            let malformed = root.appendingPathComponent("malformed.json")
            try Data("{".utf8).write(to: malformed)
            let planning = try SessionPlanning(controls: low)
            _ = try planning.next()
            try planning.setControls(high)
            _ = try planning.next()
            let canonical = try planning.checkpoint()
            for rounding in UInt32(0)..<4 {
                for flush in 0..<ll_test_flush_modes() {
                    for flags in [false, true] {
                        func scoped<Value>(_ body: () throws -> Value) throws -> Value {
                            try PreparationModeTests().environment(rounding, flush, flags, body)
                        }
                        try scoped { try planning.writeCheckpoint(to: file) }
                        #expect(try Data(contentsOf: file) == canonical)
                        let restored = try #require(
                            try scoped { try SessionPlanning.readCheckpoint(from: file) })
                        #expect(try restored.checkpoint() == canonical)
                        #expect(throws: TimelineError.invalidCheckpoint) {
                            _ = try scoped { try SessionPlanning.readCheckpoint(from: malformed) }
                        }
                        #expect(throws: (any Error).self) {
                            try scoped { try planning.writeCheckpoint(to: root) }
                        }
                    }
                }
            }
            #expect(try Data(contentsOf: file) == canonical)
        }
    }

    @Test func missingFilesDifferFromIOErrorsAndFailedWritesPreserveTheLastCheckpoint() throws {
        try directory { root in
            let storage = root.appendingPathComponent("storage")
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
            let file = storage.appendingPathComponent("checkpoint.json")
            #expect(try SessionPlanning.readCheckpoint(from: file) == nil)
            for staleError in [Int32(0), ENOENT, EACCES] {
                #expect(throws: (any Error).self) {
                    errno = staleError
                    _ = try SessionPlanning.readCheckpoint(from: storage)
                }
            }
            let remote = try #require(URL(string: "https://example.invalid/checkpoint.json"))
            let planning = try SessionPlanning(controls: low)
            #expect(throws: CocoaError(.fileReadUnsupportedScheme)) {
                _ = try SessionPlanning.readCheckpoint(from: remote)
            }
            #expect(throws: CocoaError(.fileWriteUnsupportedScheme)) {
                try planning.writeCheckpoint(to: remote)
            }
            try planning.writeCheckpoint(to: file)
            #expect(throws: (any Error).self) {
                _ = try SessionPlanning.readCheckpoint(from: file.appendingPathComponent("child"))
            }
            let original = try Data(contentsOf: file)
            let retained = root.appendingPathComponent("retained.json")
            try FileManager.default.linkItem(at: file, to: retained)
            _ = try planning.next()
            let changed = try planning.checkpoint()
            #expect(changed != original)
            // Foundation normalizes the NUL to a literal percent sequence in the
            // filesystem path. That distinct filename must never truncate to `file`.
            let normalized = URL(fileURLWithPath: file.path + "\0ignored")
            let literalPercent = URL(fileURLWithPath: file.path + "%00ignored")
            #expect(!normalized.path.utf8.contains(0) && normalized.path != file.path)
            #expect(try SessionPlanning.readCheckpoint(from: normalized) == nil)
            try planning.writeCheckpoint(to: normalized)
            let normalizedOwner = try #require(
                try SessionPlanning.readCheckpoint(from: normalized))
            #expect(try normalizedOwner.checkpoint() == changed)
            let literalOwner = try #require(
                try SessionPlanning.readCheckpoint(from: literalPercent))
            #expect(try literalOwner.checkpoint() == changed)
            #expect(try Data(contentsOf: file) == original)
            #expect(throws: (any Error).self) {
                try planning.writeCheckpoint(to: storage)
            }
            // Permission denial is meaningful for ordinary users; root bypasses these bits.
            if geteuid() != 0 {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500], ofItemAtPath: storage.path)
                defer {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: storage.path)
                }
                #expect(throws: (any Error).self) { try planning.writeCheckpoint(to: file) }
                #expect(try Data(contentsOf: file) == original)
                #expect(try Data(contentsOf: retained) == original)
            }
            #expect(try Data(contentsOf: file) == original)
            #expect(try planning.checkpoint() == changed)
        }
    }

    private func directory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
