// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

/// Writes the entire finite score on the preparation worker before admitting a rack.
struct BandArrangement {
    private enum Section { case opening, theme, development, contrast, breakdown, reprise, pivot }

    private let song: SongPlan
    private let schedule: SongSchedule
    private let ensemble: SongEnsemble
    private let origin: Double
    private var rng: SeededGenerator
    private var drafts: [EventDraft] = []
    private var harmony: [SongPlan.Chord] = []

    init(schedule: SongSchedule, ensemble: SongEnsemble) throws {
        self.schedule = schedule
        self.song = schedule.song
        self.ensemble = ensemble
        self.origin = try schedule.seconds(at: 0)
        self.rng = SeededGenerator(seed: song.takeSeed)
    }

    mutating func events() throws -> [NoteEvent] {
        for bar in 0..<song.bars {
            let section = section(at: bar)
            // Start the body on the first bar of the motif after the incoming four-bar pivot.
            let measure =
                switch section {
                case .opening: bar
                case .reprise: bar - (song.bars - 12)
                default: (bar + 4) % 8
                }
            let chord: SongPlan.Chord
            if section == .opening, let incoming = schedule.incoming {
                chord = incoming.pivot
            } else if section == .pivot {
                chord = schedule.outgoing.pivot
            } else {
                chord = song.chords[measure]
            }
            harmony.append(chord)
            try accompaniment(bar: bar, section: section, chord: chord)
            try phrase(bar: bar, measure: measure, section: section, chord: chord)
            if (schedule.incoming == nil || bar >= 2) && bar < song.bars - 2 {
                try rhythmSection(bar: bar, section: section, chord: chord)
            }
        }
        // Preserve distinct offbeat retriggers. When comp and lead strike the same
        // key together keep the melodic attack; the bank may share their sample.
        let sorted = drafts.sorted { $0.time < $1.time }
        var cleaned: [EventDraft] = []
        for event in sorted {
            if event.instrument.harmonic,
                let slot = cleaned.indices.reversed().prefix(while: {
                    event.beat - cleaned[$0].beat < 0.15
                })
                .first(where: {
                    cleaned[$0].instrument == event.instrument && cleaned[$0].color == event.color
                        && cleaned[$0].note == event.note
                })
            {
                if event.role == .melody || event.role == .answer {
                    cleaned.remove(at: slot)
                    cleaned.append(event)
                }
            } else {
                cleaned.append(event)
            }
        }
        return try EventPlanner.finish(cleaned, schedule: schedule, barChords: harmony)
    }

    private func section(at bar: Int) -> Section {
        if bar < 4 { return .opening }
        if bar < 12 { return .theme }
        if bar >= song.bars - 4 { return .pivot }
        if bar >= song.bars - 12 { return .reprise }
        if song.bars == 44 && bar < 20 { return .development }
        let middle = song.bars == 44 ? 20 : 12
        if song.bars >= 36 && (middle..<(middle + 4)).contains(bar) { return .breakdown }
        return .contrast
    }

    private mutating func emit(
        _ instrument: NoteEvent.Instrument, _ note: Int, _ bar: Int, _ at: Double, _ length: Double,
        _ velocity: Double, _ role: NoteEvent.Role, _ pan: Double, release: Double = 0.22,
        articulation: NoteEvent.Articulation = .normal, color: BandColor? = nil
    ) throws {
        guard drafts.count < NoteEvent.capacity else { throw EventError.capacityExceeded }
        let beat = Double(bar * 4) + at
        let start = try schedule.seconds(at: beat)
        let end = try schedule.seconds(at: beat + length)
        let variation = 0.95 + 0.05 * rng.unit()
        drafts.append(
            EventDraft(
                instrument: instrument, note: note, beat: beat, time: start,
                localTime: start - origin,
                duration: end - start, velocity: velocity * variation, role: role, pan: pan,
                roundRobin: rng.index(4), release: release, articulation: articulation, color: color
            ))
    }

    private mutating func accompaniment(bar: Int, section: Section, chord: SongPlan.Chord) throws {
        let sparse = section == .breakdown || section == .opening || section == .pivot
        // Rootless inner voices leave the low register to the bass. A pivot sustains;
        // the contrasting section answers the lead from the offbeat.
        let color: BandColor? = ensemble == .mallets ? nil : .electricPiano
        let guitar =
            (ensemble == .pocket && section == .contrast)
            || (ensemble == .reed && section == .breakdown)
        var tones = chord.voices
        if sparse || !bar.isMultiple(of: 2) { tones = Array(tones.suffix(3)) }
        let pedal = section == .breakdown && bar % 4 == 1
        if pedal {
            // Rearticulate one quiet guide tone through the second bar. A single
            // eight-beat gate can outlast the acoustic recording at a slow tempo.
            let previous = harmony[bar - 1].voices.suffix(3)
            let target = previous.last ?? tones[0]
            let common = previous.reversed().first { chord.pcs.contains($0 % 12) }
            tones = [common ?? tones.min { abs($0 - target) < abs($1 - target) } ?? tones[0]]
        }
        var strikes: [Double]
        switch section {
        case .opening, .pivot: strikes = [0]
        case .breakdown: strikes = bar.isMultiple(of: 2) || pedal ? [0] : []
        case .contrast: strikes = bar.isMultiple(of: 2) ? [0.5, 2.75] : [1.5]
        default:
            strikes = bar.isMultiple(of: 2) ? [0] : [0.5]
            if song.energy > 0.55 && bar % 4 == 3 { strikes.append(2.75) }
        }
        let level = pedal ? 0.23 : sparse ? 0.31 : 0.39
        for at in strikes {
            for (index, note) in tones.enumerated() {
                let strum = Double(index) * (guitar ? 0.023 : 0.012)
                let duration = section == .breakdown ? 3.8 : sparse ? 3.2 : min(2.1, 3.85 - at)
                try emit(
                    guitar ? .guitar : .piano, note, bar, at + strum, duration,
                    level * (index == tones.count - 1 ? 1 : 0.86),
                    pedal ? .support : .chord, guitar ? -0.19 : -0.14,
                    release: 0.4, articulation: .soft,
                    color: guitar ? nil : color)
            }
        }
    }

    private mutating func phrase(bar: Int, measure: Int, section: Section, chord: SongPlan.Chord)
        throws
    {
        let quiet = song.energy < 0.42
        let phraseEnd = measure == 3 || measure == 7
        // The secondary player answers only at phrase boundaries. Keep a real rest
        // on the other bars in the breakdown, including room for the held bass tail.
        if section == .opening && (bar < 2 || bar == 3) { return }
        if section == .pivot && !bar.isMultiple(of: 2) { return }
        if section == .breakdown && !phraseEnd { return }
        if (ensemble == .reed || quiet) && section == .contrast && measure == 1 { return }

        let answer = section == .breakdown || (phraseEnd && section != .theme)
        let secondary: NoteEvent.Instrument = ensemble == .mallets ? .piano : .guitar
        let color: BandColor?
        switch ensemble {
        case .pocket: color = .electricPiano
        case .mallets: color = .vibraphone
        case .reed: color = .tenor
        }
        let offsetMeasure = section == .contrast ? (measure + 3) % 8 : measure
        let notes = song.melody[offsetMeasure]
        var ticks = song.melodyTimes[offsetMeasure]
        if section == .opening || section == .pivot {
            ticks = [2, 9]
        } else if section == .contrast && measure.isMultiple(of: 2) {
            ticks = quiet ? [4, 11] : [2, 7, 10]
        } else if section == .reprise && measure == 7 {
            // Resolve the original hook with a longer cadence; more adventurous
            // settings add the pickup and an extra answer before the pivot.
            ticks = song.controls.variation < 0.3 ? [2, 10] : [2, 6, 12]
        } else if section == .reprise && measure == 5 && song.controls.variation >= 0.6 {
            ticks = [4, 9, 14]
        } else if section == .development && !measure.isMultiple(of: 2) {
            ticks = ticks.map { min(15, $0 + 1) }
        }
        let level = (section == .opening || section == .pivot) ? 0.38 : 0.54
        let layback = 0.018 * song.tempo / 60
        for (index, tick) in ticks.enumerated() {
            var target = notes[min(index, notes.count - 1)]
            if section == .contrast { target += measure.isMultiple(of: 2) ? 5 : -3 }
            if section == .reprise && measure >= 4 {
                // Keep the head literal, then lift the last answer into a new register.
                let lift = Int((song.controls.variation * 7).rounded())
                target += phraseEnd && index > 0 ? lift : lift / 2
            }
            let note = SongPlan.melodyPitch(near: target, chord: chord)
            let next = index + 1 < ticks.count ? ticks[index + 1] : 16
            let space = Double(next - tick) / 4
            let reed = ensemble == .reed && !answer
            let length = min(reed ? 1.35 : 2.0, space * (answer || reed ? 0.65 : 0.82))
            try emit(
                answer ? secondary : .piano, note, bar, Double(tick) / 4 + layback, length,
                level * (index == 0 ? 1 : 0.86), answer ? .answer : .melody,
                answer ? 0.17 : 0.06, release: reed ? 0.12 : 0.28,
                articulation: .connected, color: answer ? nil : color)
        }
    }

    private mutating func rhythmSection(bar: Int, section: Section, chord: SongPlan.Chord) throws {
        let quiet = song.energy < 0.42
        if section == .opening && bar < (ensemble == .pocket ? 1 : 2) { return }
        if section == .breakdown && !bar.isMultiple(of: 4) { return }
        let sparse = section == .opening || section == .pivot || section == .breakdown
        let halfTime = section == .contrast && (quiet || ensemble == .reed)
        let kicks: [[Double]] = [
            [0, 2.5], [0, 1.75], [0, 2.75], [0.5, 2], [0, 2.25], [0, 3.5],
        ]
        let pocket = (song.drumCell + bar % 2 + (section == .contrast ? 2 : 0)) % kicks.count
        let onsets = sparse ? [0] : kicks[pocket]
        let bassAt = section == .contrast && !bar.isMultiple(of: 2) ? 0.75 : onsets[0]
        try emit(.bass, chord.root, bar, bassAt, sparse ? 2.85 : 1.7, 0.55, .bass, 0, release: 0.13)
        if !sparse && (bar + song.bassCell).isMultiple(of: quiet ? 2 : 1) {
            let at = max(bassAt + 1.85, onsets.last ?? 2)
            // A pickup either locks with the kick or answers it half a beat later.
            let pickup = min(3.5, at + (bar.isMultiple(of: 2) ? 0 : 0.5))
            let degree = chord.pcs.filter { $0 != chord.root % 12 }
            let tone = degree.isEmpty ? chord.root : degree[(song.bassCell + bar) % degree.count]
            let pitch = chord.root + (tone - chord.root % 12 + 12) % 12
            try emit(
                .bass, pitch, bar, pickup, min(0.62, 3.95 - pickup), 0.40, .bass, 0, release: 0.10)
        }
        if section == .breakdown { return }
        for (index, at) in onsets.enumerated() {
            try emit(.kick, 0, bar, at, 0.32, index == 0 ? 0.61 : 0.42, .drum, 0)
        }
        for at in halfTime ? [2.0] : [1.0, 3.0] {
            if sparse && at == 3 && !bar.isMultiple(of: 2) { continue }
            try emit(.snare, 1, bar, at + 0.014 * song.tempo / 60, 0.16, 0.31, .drum, 0.04)
        }
        let offbeat = [0.52, 0.55, 0.54][song.drumCell % 3]
        for eighth in 0..<8 {
            let upbeat = !eighth.isMultiple(of: 2)
            if upbeat && (sparse || halfTime || (quiet && eighth != 3)) { continue }
            if section == .contrast && eighth == 4 { continue }
            let at = Double(eighth / 2) + (upbeat ? offbeat : 0)
            try emit(.hat, 0, bar, at, 0.1, upbeat ? 0.09 : 0.17, .drum, 0.17)
        }
        if !sparse && song.energy > 0.45 && bar % 4 == 3 {
            try emit(.snare, 1, bar, 3.68, 0.1, 0.075, .ghost, -0.07)
        }
        if !sparse && song.energy > 0.55 && !bar.isMultiple(of: 2) {
            try emit(.shaker, 0, bar, 1.52, 0.16, 0.1, .drum, -0.27)
        }
    }
}
