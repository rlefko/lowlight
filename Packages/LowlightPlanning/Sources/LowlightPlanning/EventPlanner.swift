// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

public enum EventPlanner {
    public static let algorithmVersion = 1

    /// Bounded preparation off the audio callback; percussion tails require rack-level fades.
    public static func events(for schedule: SongSchedule) throws -> [NoteEvent] {
        try schedule.validate()
        let song = schedule.song
        let origin = try schedule.seconds(at: 0)
        var rng = SeededGenerator(seed: song.takeSeed)
        var events: [EventDraft] = []
        var barChords: [SongPlan.Chord] = []
        func emit(
            _ instrument: NoteEvent.Instrument, _ note: Int, _ beat: Double, _ length: Double,
            _ velocity: Double, _ role: NoteEvent.Role, _ pan: Double = 0, _ rr: Int = 0,
            _ release: Double = 0.25, _ articulation: NoteEvent.Articulation = .normal
        ) throws {
            guard events.count < NoteEvent.capacity else { throw EventError.capacityExceeded }
            let start = try schedule.seconds(at: beat)
            let end = try schedule.seconds(at: beat + length)
            events.append(
                EventDraft(
                    instrument: instrument, note: note, beat: beat, time: start,
                    localTime: start - origin, duration: end - start, velocity: velocity,
                    role: role, pan: pan, roundRobin: rr, release: release,
                    articulation: articulation))
        }
        for bar in 0..<song.bars {
            let intro = schedule.incoming != nil && bar < 4
            let outro = bar >= song.bars - 4
            let chord =
                intro
                ? schedule.incoming?.pivot ?? song.chords[bar % 8]
                : outro ? schedule.outgoing.pivot : song.chords[bar % 8]
            barChords.append(chord)
            let phase = bar % 8
            let cycle = bar / 8
            let beat = Double(bar * 4)
            let quiet = song.bars >= 36 ? (16..<20).contains(bar) : (12..<16).contains(bar)
            let gain = quiet ? 0.74 : bar < 4 ? 0.86 : 1.0
            let contour = song.phraseArc[(bar / 2) % 4]
            let rr = (bar + rng.index(4)) % 4
            let main: NoteEvent.Instrument = song.focus == "guitar" ? .guitar : .piano
            let other: NoteEvent.Instrument = main == .guitar ? .piano : .guitar
            let pan = main == .guitar ? -0.13 : -0.05
            let refresh =
                bar == 0 || phase.isMultiple(of: 2)
                || chord.pcs != barChords[bar - 1].pcs || intro || outro
            let velocity = (main == .guitar ? 0.62 : 0.54) * gain * contour
            if refresh || !quiet {
                for (index, note) in chord.voices.enumerated() {
                    try emit(
                        main, note, beat + (0.012 + Double(index) * 0.012) * song.tempo / 60,
                        refresh ? 3.65 : 2.8,
                        velocity * [0.76, 0.92, 0.88, 1.0][min(index, 3)] * (refresh ? 1 : 0.64),
                        .chord, pan, rr + index, 0.55, .soft)
                }
            }
            if refresh {
                for (index, note) in [
                    chord.voices[0], chord.voices[min(2, chord.voices.count - 1)],
                ].enumerated() {
                    try emit(
                        other, note, beat + (0.042 + Double(index) * 0.014) * song.tempo / 60,
                        phase.isMultiple(of: 2) ? 6.8 : 3.3,
                        (main == .guitar ? 0.32 : 0.25) * gain, .support, 0.22, rr + index, 0.72,
                        .soft)
                }
            }
            var notes = intro || outro ? Array(chord.tops.suffix(2).reversed()) : song.melody[phase]
            var times =
                intro || outro ? Array([0, 2].prefix(notes.count)) : song.melodyTimes[phase]
            if quiet || (cycle % 3 == 1 && [3, 7].contains(phase)) {
                notes = Array(notes.prefix(1))
                times = Array(times.prefix(1))
            }
            if cycle % 3 == 2 && [4, 6].contains(phase) && notes.count > 1 && !(intro || outro) {
                let target = notes[notes.count - 1]
                notes[notes.count - 1] =
                    chord.tops.min { abs($0 - target) < abs($1 - target) } ?? target
            }
            for (index, pair) in zip(notes, times).enumerated() {
                if bar < 4 && !bar.isMultiple(of: 2) && index > 0 { continue }
                let (note, at) = pair
                let end = index + 1 < times.count ? times[index + 1] : 4
                try emit(
                    main, note, beat + Double(at) + 0.018 * song.tempo / 60,
                    max(0.55, Double(end - at) - 0.06),
                    (main == .guitar ? 0.57 : 0.48) * gain * contour
                        * [1.0, 0.83, 0.72, 0.68][index],
                    .melody, pan, rr + index, 0.30, index == 0 ? .soft : .connected)
            }
            if phase == 7 && !(intro || outro) && !quiet, let top = chord.tops.last {
                try emit(other, top, beat + 3, 0.85, 0.19 * gain, .answer, 0.28, rr, 0.65, .soft)
            }
            guard !(song.id > 0 && bar < 2) && bar < song.bars - 2 else { continue }
            let extra = bar.isMultiple(of: 2) && !quiet && song.energy > 0.22
            try emit(
                .bass, chord.root, beat + 0.006 * song.tempo / 60,
                extra ? 2.65 : 3.52, 0.58 * gain, .bass, 0, rr, 0.11)
            if extra {
                let follow = chord.root + ((bar + song.bassCell) % 4 == 2 ? 7 : 12)
                try emit(.bass, follow, beat + 3, 0.72, 0.58 * gain * 0.64, .bass, 0, rr + 1, 0.10)
            }
            if song.energy > 0.76 && phase == 5 && !quiet {
                try emit(
                    .bass, chord.root + 7, beat + 2, 0.65, 0.58 * gain * 0.48, .bass, 0, rr + 2,
                    0.09)
            }
            let cell = (bar / 2 + song.drumCell) % 6
            let kickPatterns = [[0.0, 2.5], [0, 2], [0, 2.75], [0, 2.5], [0, 2], [0, 2.75]]
            var kicks = quiet || song.energy < 0.16 ? [0.0] : kickPatterns[(cell + bar % 2) % 6]
            if song.energy > 0.76 && bar % 4 == 2 { kicks = [0, 1.75, 2.5] }
            for (index, at) in kicks.enumerated() {
                try emit(
                    .kick, 0, beat + at, 0.4, (index == 0 ? 0.62 : 0.42) * gain, .drum, 0,
                    rr + index)
            }
            for (index, at) in [1.0, 3.0].enumerated() {
                if quiet && index == 1 && !bar.isMultiple(of: 2) { continue }
                try emit(
                    .snare, 1, beat + at + 0.014 * song.tempo / 60, 0.22,
                    (index == 0 ? 0.33 : 0.29) * gain, .drum, 0.025, rr + index)
            }
            for index in 0..<8 {
                if (quiet || song.energy < 0.22) && !index.isMultiple(of: 2) { continue }
                if song.energy < 0.42 && [3, 7].contains(index) { continue }
                if bar < 2 && !index.isMultiple(of: 2) { continue }
                let at = Double(index / 2) + (index.isMultiple(of: 2) ? 0 : 0.53)
                try emit(
                    .hat, 0, beat + at, 0.1,
                    [0.20, 0.075, 0.145, 0.065, 0.18, 0.075, 0.13, 0.055][index] * gain,
                    .drum, 0.18, rr + index)
            }
            if phase == 7 && song.energy > 0.32 && !quiet {
                try emit(.snare, 1, beat + 3.5, 0.1, 0.075, .ghost, -0.06, rr + 1)
            }
            if !cycle.isMultiple(of: 2) && !bar.isMultiple(of: 2) && song.energy > 0.48 {
                try emit(.shaker, 0, beat + 2.54, 0.16, 0.095 * gain, .drum, -0.3, rr)
            }
        }
        var cleaned = deduplicate(events)
        damp(&cleaned)
        for index in cleaned.indices where cleaned[index].instrument.harmonic {
            let firstBoundary = Int(cleaned[index].beat / 4) + 1
            for bar in firstBoundary..<song.bars {
                let elapsed = try schedule.seconds(at: Double(bar * 4)) - cleaned[index].time
                if elapsed >= cleaned[index].duration + cleaned[index].release { break }
                if !barChords[bar].pcs.contains(cleaned[index].note % 12) {
                    cleaned[index].duration = max(
                        0.04, min(cleaned[index].duration, elapsed - 0.11))
                    cleaned[index].release = max(0.025, elapsed - cleaned[index].duration - 0.01)
                    break
                }
            }
        }
        return try cleaned.map(NoteEvent.init)
    }

    private struct HarmonicKey: Hashable {
        let instrument: NoteEvent.Instrument
        let note, gesture: Int
    }

    private static func deduplicate(_ events: [EventDraft]) -> [EventDraft] {
        var result: [EventDraft] = []
        var slots: [HarmonicKey: Int] = [:]
        for var event in events {
            guard event.instrument.harmonic else {
                result.append(event)
                continue
            }
            let key = HarmonicKey(
                instrument: event.instrument, note: event.note, gesture: Int(event.beat + 0.08))
            if let slot = slots[key] {
                let prior = result[slot]
                if abs(prior.beat - event.beat) < 0.15 {
                    guard event.role == .melody else { continue }
                    event.velocity = max(event.velocity, prior.velocity)
                    event.duration = max(event.duration, prior.duration)
                }
                result[slot] = event
            } else {
                slots[key] = result.count
                result.append(event)
            }
        }
        // Explicit insertion-index tie breaking preserves Python's stable ordering.
        return result.enumerated().sorted {
            $0.element.time == $1.element.time
                ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }

    private static func damp(_ events: inout [EventDraft]) {
        for instrument in [NoteEvent.Instrument.guitar, .piano, .bass] {
            var previous: [Int: Int] = [:]
            for index in events.indices where events[index].instrument == instrument {
                let key = instrument == .bass ? 0 : events[index].note
                if let prior = previous[key] {
                    let distance = events[index].time - events[prior].time
                    events[prior].duration = max(
                        0.035, min(events[prior].duration, distance - 0.028))
                    events[prior].release = min(
                        events[prior].release, max(0.025, distance - events[prior].duration))
                }
                previous[key] = index
            }
        }
    }
}
