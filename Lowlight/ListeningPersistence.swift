// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import LowlightAudio

struct ListeningPersistence: Sendable {
    let load: @Sendable () async throws -> SessionRestartIntent?
    let save: @Sendable (SessionRestartIntent) async throws -> Void

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

    func load() throws -> SessionRestartIntent? {
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
        let limit = SessionRestartIntent.maximumEncodedByteCount
        var data = Data()
        while data.count <= limit {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: limit + 1 - data.count), !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        return try SessionRestartIntent.restore(data)
    }

    func save(_ intent: SessionRestartIntent) throws {
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
