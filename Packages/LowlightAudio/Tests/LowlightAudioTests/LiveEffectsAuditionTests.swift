// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct LiveEffectsAuditionTests {
    /// Six takes of the same native performance. All passes use Focus until four
    /// seconds into the excerpt, audition one effect, then return to Focus at 16 s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOWLIGHT_EFFECT_AUDITIONS"] != nil))
    func isolatedEffects() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = try #require(ProcessInfo.processInfo.environment["LOWLIGHT_EFFECT_AUDITIONS"])
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let build = root.appendingPathComponent(".build").resolvingSymlinksInPath()
        try #require(directory.path.hasPrefix(build.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let fields: [(String, WritableKeyPath<SessionEffects, Double>)] = [
            ("warmth", \.warmth), ("space", \.space), ("texture", \.texture),
        ]
        let initial = try Controls.preset(.focus)
        var referencePrefix: Data?
        for (field, key) in fields {
            for level in 0...1 {
                let session = try PreparedSession(seed: 1, controls: initial, preparer: preparer)
                let effects = try #require(session.makeEffectsEndpoint())
                let render = try session.makeRenderEndpoint()
                var target = SessionEffects(initial)
                target[keyPath: key] = Double(level)
                let url = directory.appendingPathComponent("\(field)-\(level).f32")
                try Data().write(to: url)
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                var buffer = [Float](repeating: 0, count: 512)
                var prefix = Data()
                try buffer.withUnsafeMutableBufferPointer { block in
                    for second in 0..<48 {
                        if second == 28 || second == 40 {
                            let setting = second == 28 ? target : SessionEffects(initial)
                            try #require(
                                effects.send(
                                    revision: second == 28 ? 2 : 3,
                                    warmth: setting.warmth, space: setting.space,
                                    texture: setting.texture))
                        }
                        for _ in 0..<125 {
                            try #require(render.render(into: block) == 256)
                            if second >= 24 {
                                let bytes = UnsafeRawBufferPointer(block)
                                if second < 28 { prefix.append(contentsOf: bytes) }
                                try file.write(contentsOf: bytes)
                            }
                        }
                        if second == 28 || second == 40 {
                            try #require(effects.progress.settledRevision == (second == 28 ? 2 : 3))
                        }
                    }
                }
                if let referencePrefix {
                    try #require(referencePrefix == prefix)
                } else {
                    referencePrefix = prefix
                }
                try #require(render.position == 48 * 32_000 && !render.isFaulted)
            }
        }
    }
}
