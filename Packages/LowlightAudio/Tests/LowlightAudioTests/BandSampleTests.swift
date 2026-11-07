// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

struct BandSampleTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Lowlight/SoundBank")

    private func note(_ color: BandColor?, velocity: Double = 0.48, hold: Int = 19_200) throws
        -> NoteEvent
    {
        var fields: [String: Any] = [
            "formatVersion": color == nil ? 1 : 2,
            "instrument": "piano", "role": "melody", "articulation": "normal",
            "note": 61, "roundRobin": 0, "beat": 0, "velocity": velocity,
            "pan": 0.06, "startFrame": 0, "gateEndFrame": hold, "releaseEndFrame": hold + 6400,
        ]
        fields["color"] = color?.rawValue
        return try JSONDecoder().decode(
            NoteEvent.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func render(
        _ event: NoteEvent, preparer: TonalSamplePreparer, warmth: Double = 0.78,
        live: Bool = true
    ) throws -> [Float] {
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: [event], warmth: warmth, useLiveTonalSamples: live)
        var pcm = [Float](repeating: 0, count: 19200)
        try pcm.withUnsafeMutableBufferPointer { try #require(mixer.render(into: $0)) }
        return pcm
    }

    @Test func eachArticulationReachesTheLiveMixerAndOriginalPaletteIsReproducible() throws {
        let native = try TonalSamplePreparer(bankURL: root)
        let original = try TonalSamplePreparer(bankURL: root, bandColors: false)
        var voices: Set<BandVoice> = []
        var prior: [[Float]] = []
        for event in try [
            note(.electricPiano), note(.electricPiano, velocity: 0.53),
            note(.vibraphone), note(.tenor), note(.tenor, hold: 10_240),
        ] {
            let key = try TonalVoiceMixer.key(for: event)
            voices.insert(try #require(key.bandVoice))
            let pcm = try render(event, preparer: native)
            try #require(pcm.contains { abs($0) > 0.001 })
            #expect(pcm.allSatisfy { $0.isFinite && abs($0) < 1 })
            #expect(!prior.contains(pcm))
            prior.append(pcm)
            let baked = try render(event, preparer: native, live: false)
            #expect(pcm == baked)
            let bright = try render(event, preparer: native, warmth: 0)
            #expect(bright != pcm)
            let legacy = try note(nil, velocity: event.velocity, hold: Int(event.gateEndFrame))
            let ablated = try render(event, preparer: original)
            #expect(try render(legacy, preparer: native) == ablated)
            #expect(pcm != ablated)
        }
        #expect(voices == Set(BandVoice.allCases))
    }
}
