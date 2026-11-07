// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

/// Fixed seeds, presets and start frames allow the same tests to run against two revisions.
struct WritingEvidenceTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct Bar {
        var melody: [[Int]] = []
        var bass: [[Int]] = []
        var players: Set<String> = []
    }

    private struct SongAudit: Encodable {
        let seed: UInt64
        let preset: String
        let index, bars, events, comparisons: Int
        let sameLeadAtEightBars, sameBassAtEightBars, distinctLeadRhythms: Int
        let silentLeadBars, returningPlayers, ascendingSecondNotes, multiNoteBars: Int
    }

    private func audit(_ schedule: SongSchedule, seed: UInt64, preset: Preset, index: Int) throws
        -> SongAudit
    {
        let events = try EventPlanner.events(for: schedule)
        var bars = Array(repeating: Bar(), count: schedule.song.bars)
        for event in events {
            // Assign laid-back attacks to their written bar; quantize away tiny performance offsets.
            let bar = Int(event.beat / 4)
            let tick = Int(((event.beat - Double(bar * 4)) * 4).rounded())
            let note = [tick, event.note]
            if event.role == .melody { bars[bar].melody.append(note) }
            if event.role == .bass { bars[bar].bass.append(note) }
            bars[bar].players.insert(event.color?.rawValue ?? event.instrument.rawValue)
        }
        let pairs = zip(bars, bars.dropFirst(8))
        let poly = bars.filter { $0.melody.count >= 2 }
        let rhythms = bars.map { $0.melody.map { $0[0] } }.filter { !$0.isEmpty }
        let entrances = zip(bars, bars.dropFirst()).reduce(0) {
            $0 + $1.1.players.subtracting($1.0.players).count
        }
        return SongAudit(
            seed: seed, preset: preset.rawValue, index: index, bars: bars.count,
            events: events.count, comparisons: bars.count - 8,
            sameLeadAtEightBars: pairs.filter { $0.melody == $1.melody && !$0.melody.isEmpty }
                .count,
            sameBassAtEightBars: pairs.filter { $0.bass == $1.bass && !$0.bass.isEmpty }.count,
            distinctLeadRhythms: Set(rhythms).count,
            silentLeadBars: bars.filter { $0.melody.isEmpty }.count,
            returningPlayers: entrances,
            ascendingSecondNotes: poly.filter { $0.melody[1][1] > $0.melody[0][1] }.count,
            multiNoteBars: poly.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOWLIGHT_WRITING_CAPTURE"] != nil))
    func capture() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(env["LOWLIGHT_WRITING_CAPTURE"]))
            .resolvingSymlinksInPath().standardizedFileURL
        let build = root.appendingPathComponent(".build").resolvingSymlinksInPath()
        try #require(directory.path.hasPrefix(build.path + "/"))
        let edition = try #require(
            CompositionEdition(rawValue: Int(env["LOWLIGHT_WRITING_EDITION"] ?? "") ?? -1))
        var records: [SongAudit] = []
        for preset in Preset.allCases {
            for seed: UInt64 in [91_031, 17, 509, 8_731] {
                var timeline = try SessionTimeline(
                    seed: seed, controls: .preset(preset), edition: edition)
                for index in 0..<16 {
                    try records.append(
                        audit(timeline.next(), seed: seed, preset: preset, index: index))
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(
            to: directory.appendingPathComponent("scores.json"), options: .withoutOverwriting)
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        var passages: [(String, Preset, UInt64, Int)] = [
            ("focus", .focus, 91_031, 600), ("reflective", .reflective, 17, 120),
            ("commute", .commute, 509, 120),
        ]
        if edition == .evolving { passages.append(("original-palette", .focus, 91_031, 105)) }
        let original = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"), bandColors: false)
        for (name, preset, seed, seconds) in passages {
            let session = try PreparedSession(
                seed: seed, controls: .preset(preset), edition: edition,
                preparer: name == "original-palette" ? original : preparer)
            try NativePCMExport.write(
                session: session, frames: UInt64(seconds * 32_000),
                to: directory.appendingPathComponent(name + ".f32"))
        }
    }
}
