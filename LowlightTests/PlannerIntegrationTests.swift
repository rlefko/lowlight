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
}
