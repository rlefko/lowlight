// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import LowlightPlanning

extension SessionPlanning {
    /// Atomically replaces one file with the existing versioned musical-intent checkpoint.
    /// Serialize access to this owner and file off the audio callback. The parent directory
    /// must exist. Replacement is atomic, not a promise of power-loss durability.
    public func writeCheckpoint(to url: URL) throws {
        try PreparationMode.perform { try writeCheckpointFile(to: url) }
    }

    /// Returns nil only when opening a missing file; invalid checkpoints and other I/O
    /// errors propagate without changing the file. Restores planning intent, not playback.
    /// Serialize access to the file off the audio callback.
    public static func readCheckpoint(from url: URL) throws -> SessionPlanning? {
        try PreparationMode.perform { try readCheckpointFile(from: url) }
    }

    @inline(never)
    private func writeCheckpointFile(to url: URL) throws {
        try Self.validateCheckpointURL(url, writing: true)
        let data = try checkpoint()
        guard data.count <= SessionTimeline.maximumCheckpointByteCount else {
            throw TimelineError.invalidCheckpoint
        }
        try data.write(to: url, options: .atomic)
    }

    @inline(never)
    private static func readCheckpointFile(from url: URL) throws -> SessionPlanning? {
        try validateCheckpointURL(url, writing: false)
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if descriptor < 0 {
                let code = errno
                if code != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            }
            return descriptor
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var data = Data()
        do {
            // A read can be short before EOF. One extra byte distinguishes an exact-limit
            // checkpoint from a larger file without relying on racy file-size metadata.
            let limit = SessionTimeline.maximumCheckpointByteCount
            while data.count <= limit {
                guard let chunk = try handle.read(upToCount: limit + 1 - data.count),
                    !chunk.isEmpty
                else { break }
                data.append(chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return try restore(data)
    }

    private static func validateCheckpointURL(_ url: URL, writing: Bool) throws {
        guard url.isFileURL else {
            throw CocoaError(writing ? .fileWriteUnsupportedScheme : .fileReadUnsupportedScheme)
        }
        guard !url.path.utf8.contains(0), url.withUnsafeFileSystemRepresentation({ $0 != nil })
        else {
            throw CocoaError(writing ? .fileWriteInvalidFileName : .fileReadInvalidFileName)
        }
    }
}
