// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

public enum CompositionEdition: Int, Codable, Sendable {
    case classic = 1
    case evolving = 2
}

public enum SongEnsemble: String, Codable, CaseIterable, Sendable {
    case pocket, mallets, reed

    var next: Self {
        switch self {
        case .pocket: .mallets
        case .mallets: .reed
        case .reed: .pocket
        }
    }
}

extension SongPlan {
    // In the evolving score, motif onsets are integer sixteenths within a bar.
    static func validMotifTicks(_ ticks: [Int]) -> Bool {
        (1...4).contains(ticks.count) && ticks.allSatisfy { (0..<16).contains($0) }
            && zip(ticks, ticks.dropFirst()).allSatisfy(<)
    }

    /// Choose a two-bar rhythmic identity; later phrases remember its pickup and
    /// contour even when their harmony or register changes.
    mutating func develop(following previous: SongEnsemble?, rng: inout SeededGenerator) {
        // Rotate a trio through each group of three pieces. At a group boundary a
        // seeded change may reverse direction without repeating the departing band.
        if let previous {
            let step = id.isMultiple(of: 3) ? 1 + rng.index(2) : 1
            ensemble = step == 1 ? previous.next : previous.next.next
        } else {
            ensemble = SongEnsemble.allCases[rng.index(SongEnsemble.allCases.count)]
        }

        let calls = [[0, 6, 10], [2, 8, 14], [0, 3, 8], [4, 10, 12], [0, 7, 12], [2, 6, 12]]
        let replies = [[2, 10], [0, 6, 12], [4, 11], [0, 9], [2, 8, 13]]
        let directions = [[0, 4, 2, -2], [0, -2, 3, 5], [0, 2, 7, 4], [0, -4, -2, 2]]
        let call = calls[rng.index(calls.count)]
        let reply = replies[rng.index(replies.count)]
        let steps = directions[rng.index(directions.count)]
        let register = 59 + rng.index(5)
        let lift = controls.variation >= 0.45 ? 4 : 2
        for bar in 0..<8 {
            let isCall = bar.isMultiple(of: 2)
            var ticks = isCall ? call : reply
            if bar == 3 { ticks = [reply[0], 12] }
            if bar == 6 && energy > 0.58 { ticks = [0, 4, 10, 14] }
            if bar == 7 { ticks = energy < 0.4 ? [4] : [2, 8] }
            if energy < 0.42 && bar % 4 == 2 { ticks.removeLast() }
            let base = register + (bar == 4 || bar == 6 ? lift : 0)
            let chord = chords[bar]
            melodyTimes[bar] = ticks
            melody[bar] = ticks.indices.map { index in
                let interval = isCall ? steps[index] : -steps[index] + 2
                return Self.melodyPitch(near: base + interval, chord: chord)
            }
        }
    }

    static func melodyPitch(near target: Int, chord: Chord) -> Int {
        (55...69).filter { chord.pcs.contains($0 % 12) }
            .min { abs($0 - target) < abs($1 - target) } ?? chord.voices[0]
    }
}
