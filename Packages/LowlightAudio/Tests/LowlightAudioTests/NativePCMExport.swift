// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import Testing

/// Accelerate only the consumer clock. Each successor still goes through production preparation.
enum NativePCMExport {
    static func write(session: PreparedSession, frames: UInt64, to destination: URL) throws {
        let endpoint = try session.makeRenderEndpoint()
        try Data().write(to: destination, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        var samples = [Float](repeating: 0, count: 8192)
        while endpoint.position < frames {
            if session.needsPreparation { try session.prepareNext() }
            let start = endpoint.position
            let count = min(samples.count / 2, Int(frames - start))
            let written = try #require(
                samples.withUnsafeMutableBufferPointer {
                    endpoint.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
                })
            try #require(written > 0 && endpoint.position == start + UInt64(written))
            try #require(!endpoint.isFaulted)
            try samples.withUnsafeBytes {
                try file.write(contentsOf: $0.prefix(written * 2 * MemoryLayout<Float>.size))
            }
        }
        try #require(endpoint.position == frames)
    }
}
