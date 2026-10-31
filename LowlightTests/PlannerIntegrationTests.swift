// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightPlanning
import Testing

struct PlannerIntegrationTests {
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
