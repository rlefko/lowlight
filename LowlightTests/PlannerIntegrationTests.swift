// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

struct PlannerIntegrationTests {
    @Test func planningIntentPersistsInTheAppContainerOnIOS() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SessionPlanning.readCheckpoint(from: url) == nil)
        let planning = try SessionPlanning(seed: 91_031)
        _ = try planning.next()
        try planning.setPosition(frame: planning.frame(at: 17.125))
        try planning.writeCheckpoint(to: url)
        let restored = try #require(try SessionPlanning.readCheckpoint(from: url))
        #expect(try Data(contentsOf: url) == planning.checkpoint())
        #expect(restored.positionFrame == planning.positionFrame)
        #expect(try restored.next() == planning.next())
    }

    @Test func bundledGrammarPlansAndRestoresOnIOS() throws {
        var planner = try SongPlanner(seed: 91_031)
        var restored = try SongPlanner.restore(planner.checkpoint())
        #expect(try planner.next() == restored.next())
    }

    @Test func eventsAndSharedClockRestoreOnIOS() throws {
        var timeline = try SessionTimeline(seed: 91_031)
        let outgoing = try timeline.next()
        let incoming = try timeline.next()
        #expect(outgoing.outgoing == incoming.incoming)
        for quarter in 0...64 {
            let beat = Double(quarter) / 4
            #expect(
                try outgoing.frame(at: Double(outgoing.song.bars * 4 - 16) + beat)
                    == incoming.frame(at: beat))
        }
        let events = try EventPlanner.events(for: incoming)
        #expect(!events.isEmpty && events.count <= NoteEvent.capacity)
        var restored = try SessionTimeline.restore(timeline.checkpoint())
        #expect(try EventPlanner.events(for: #require(restored.current)) == events)
        #expect(try timeline.next() == restored.next())
    }
}
