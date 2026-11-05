// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import LowlightAudio
import LowlightPlanning

enum ListeningRecordError: Error { case invalidRecord, unsupportedVersion }

/// App preferences can exist before a song does. A restart remains musical intent only.
struct ListeningRecord: Equatable, Sendable {
    static let formatVersion = 2
    static let maximumEncodedByteCount = 1_048_576
    static let initial = Self(validated: Controls(), restart: nil)
    let controls: Controls
    let restart: SessionRestartIntent?

    private struct Envelope: Codable {
        let formatVersion: Int
        let controls: Controls
        let restartData: Data?
    }

    private struct Header: Decodable {
        let formatVersion: Int
        let hasWrapperFields, hasCheckpoint, hasPlanningAnchor: Bool

        private enum CodingKeys: String, CodingKey {
            case formatVersion, controls, restartData, checkpoint, planningAnchor
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try container.decode(Int.self, forKey: .formatVersion)
            hasWrapperFields = container.contains(.controls) || container.contains(.restartData)
            hasCheckpoint = container.contains(.checkpoint)
            hasPlanningAnchor = container.contains(.planningAnchor)
        }
    }

    init(controls: Controls, restart: SessionRestartIntent? = nil) throws {
        self.init(validated: try controls.normalized(), restart: restart)
    }

    private init(validated controls: Controls, restart: SessionRestartIntent?) {
        self.controls = controls
        self.restart = restart
    }

    func capturing(_ restart: SessionRestartIntent) -> Self {
        Self(validated: controls, restart: restart)
    }

    func discardingRestart() -> Self { Self(validated: controls, restart: nil) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            Envelope(
                formatVersion: Self.formatVersion, controls: controls,
                restartData: restart?.encoded()))
        guard data.count <= Self.maximumEncodedByteCount else {
            throw ListeningRecordError.invalidRecord
        }
        return data
    }

    static func restore(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedByteCount else {
            throw ListeningRecordError.invalidRecord
        }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        if !header.hasWrapperFields, header.hasCheckpoint {
            // Both standalone restart formats preceded app preferences. The restart
            // decoder validates their version, checkpoint, and optional planning anchor.
            let restart = try SessionRestartIntent.restore(data)
            return try Self(controls: restart.currentSong.controls, restart: restart)
        }
        guard header.hasWrapperFields, !header.hasCheckpoint, !header.hasPlanningAnchor else {
            throw ListeningRecordError.invalidRecord
        }
        guard header.formatVersion == formatVersion else {
            throw ListeningRecordError.unsupportedVersion
        }
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard try envelope.controls.normalized() == envelope.controls else {
            throw ListeningRecordError.invalidRecord
        }
        return Self(
            validated: envelope.controls,
            restart: try envelope.restartData.map(SessionRestartIntent.restore))
    }
}

struct ListeningPersistence: Sendable {
    let load: @Sendable () async throws -> ListeningRecord?
    let save: @Sendable (ListeningRecord) async throws -> Void

    static func disk(at url: URL? = nil) -> Self {
        let file = ListeningCheckpointFile(url: url)
        return Self(load: { try await file.load() }, save: { try await file.save($0) })
    }
}

/// Serial file ownership. Neither reading, encoding nor atomic replacement runs on main.
actor ListeningCheckpointFile {
    private let suppliedURL: URL?

    init(url: URL? = nil) { suppliedURL = url }

    private func location() throws -> URL {
        if let suppliedURL { return suppliedURL }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return support.appendingPathComponent("Lowlight", isDirectory: true)
            .appendingPathComponent("listening.json")
    }

    func load() throws -> ListeningRecord? {
        try Task.checkCancellation()
        let url = try location()
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            let result = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if result < 0, errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return result
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = ListeningRecord.maximumEncodedByteCount
        var data = Data()
        while data.count <= limit {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: limit + 1 - data.count), !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        return try ListeningRecord.restore(data)
    }

    func save(_ intent: ListeningRecord) throws {
        try Task.checkCancellation()
        let url = try location()
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let data = try intent.encoded()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
