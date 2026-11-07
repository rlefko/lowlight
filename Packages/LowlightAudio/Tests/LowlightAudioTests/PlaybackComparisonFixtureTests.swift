// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

/// Opt-in host export through the continuous production transport. Service its preparation
/// requests on this thread so accelerated rendering never inserts a scheduling gap.
struct PlaybackComparisonFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOWLIGHT_COMPARISON_OUTPUT"] != nil))
    func exportFocus() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(
            fileURLWithPath: try #require(environment["LOWLIGHT_COMPARISON_OUTPUT"]),
            isDirectory: true
        ).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = root.appendingPathComponent(".build").resolvingSymlinksInPath()
        try #require(directory.path.hasPrefix(build.path + "/"))
        let seconds = try #require(Int(environment["LOWLIGHT_COMPARISON_SECONDS"] ?? ""))
        try #require((1...3600).contains(seconds))
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let session = try PreparedSession(
            seed: 91_031, controls: .preset(.focus), edition: .evolving, preparer: preparer)
        try NativePCMExport.write(
            session: session, frames: UInt64(seconds) * 32_000,
            to: directory.appendingPathComponent("source.f32"))
    }
}
