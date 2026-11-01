// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let preparedRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct PreparedSampleTests {
    private func preparer() throws -> TonalSamplePreparer {
        try TonalSamplePreparer(bankURL: preparedRoot.appendingPathComponent("Lowlight/SoundBank"))
    }

    @Test func laterLongerEventsShareCompleteReachablePrefixes() throws {
        let events = try [
            event(.guitar, note: 60, start: 0, hold: 1),
            event(.piano, note: 60, start: 2, hold: 1),
            event(.guitar, note: 60, rr: 4, start: 128, hold: 2048, release: 2049),
            event(.piano, note: 60, rr: 10, start: 8192, hold: 1024, release: 4096),
        ]
        let mixer = try paired(events, frames: 16384)
        // RR aliases share one mono guitar and one stereo piano allocation.
        #expect(mixer.preparedBytes == (4097 + 5120 * 2) * 4)
    }

    @Test func sourceEndsAndBassSustainMatchCompleteSamples() throws {
        let events = try [
            event(.guitar, note: 64, hold: 200000, release: 1000),
            event(.piano, note: 60, hold: 200000, release: 1000),
            event(.bass, note: 48, rr: 1, hold: 100000, release: 8000),
        ]
        let mixer = try paired(events, frames: 201001)
        // Long gates retain each source in full; bass synthesis outlives its body PCM.
        #expect(mixer.preparedBytes == (192000 + 166400 * 2 + 84758) * 4)
    }

    @Test func oneShotsAndOverloadKeepTheirOriginalBehavior() throws {
        let hits = try [
            event(.kick, hold: 1), event(.snare, note: 1, hold: 1),
            event(.hat, hold: 1, velocity: 0.719999999),
            event(.hat, hold: 1, velocity: 0.72), event(.shaker, hold: 1),
        ]
        let hitMixer = try paired(hits, frames: 24000)
        let source = try preparer()
        var originalBytes = 0
        for hit in hits {
            let instrument = try #require(TonalInstrument(rawValue: hit.instrument.rawValue))
            let sample = try source.prepare(
                instrument: instrument, note: hit.note, roundRobin: hit.roundRobin,
                warmth: 0.78, velocity: hit.velocity)
            originalBytes += sample.samples.count * 4
        }
        #expect(hitMixer.preparedBytes == originalBytes)
        let note = try event(.guitar, note: 60, hold: 1024, release: 256)
        let overloaded = try paired(Array(repeating: note, count: 129), frames: 4096)
        #expect(overloaded.preparedBytes == 1280 * 4)
        #expect(overloaded.stolenVoices == 64 && overloaded.droppedEvents == 1)
    }

    @Test func completeAcceptedScoreFitsWithoutChangingCapacityLimits() throws {
        let data = try Data(
            contentsOf: preparedRoot.appendingPathComponent("tests/fixtures/v9/events.json"))
        let events = try NoteEvent.importReference(data)
        #expect(events.count == 621 && LL_SAMPLE_LIMIT == 64 && LL_SAMPLE_BYTES == 33_554_432)
        let mixer = try TonalVoiceMixer(
            preparer: preparer(), events: events, warmth: 0.78, busEnergy: 0.3795510689640131)
        #expect(mixer.preparedBytes == 23_363_076)
        var output = [RhythmBusFrame](repeating: RhythmBusFrame(), count: 512)
        while mixer.position < 3_711_911 {
            let count = min(512, 3_711_911 - Int(mixer.position))
            try #require(
                output.withUnsafeMutableBufferPointer {
                    mixer.renderBuses(into: UnsafeMutableBufferPointer(rebasing: $0[..<count]))
                })
        }
        #expect(mixer.activeVoices == 0 && mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        let last = output[0]
        #expect(
            [
                last.guitar.0, last.guitar.1, last.piano.0, last.piano.1,
                last.bass.0, last.bass.1, last.drums.0, last.drums.1,
            ].allSatisfy { $0 == 0 })
        #expect(last.duck == 1)

        var longScore = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for index in longScore.indices {
            longScore[index]["duration"] = 16.0
            longScore[index]["release"] = 5.0
        }
        let longEvents = try NoteEvent.importReference(
            JSONSerialization.data(withJSONObject: longScore))
        // The same 63 keys retain their full 39,363,152 bytes: the 32 MiB guard still rejects.
        do {
            _ = try TonalVoiceMixer(preparer: preparer(), events: longEvents, warmth: 0.78)
            Issue.record("Expected the unchanged 32 MiB sample limit to reject this score")
        } catch VoiceMixerError.capacityExceeded {}
    }

    @Test func sampleSlotLimitStillRejectsTinySixtyFifthKey() throws {
        let events = try (0..<65).map {
            try event(.guitar, note: 50 + $0 / 4, rr: $0 % 4, start: $0 * 2, hold: 1)
        }
        let source = try preparer()
        let mixer = try TonalVoiceMixer(
            preparer: source, events: Array(events.prefix(64)), warmth: 0.78)
        #expect(mixer.preparedBytes == 64 * 4)
        do {
            _ = try TonalVoiceMixer(preparer: source, events: events, warmth: 0.78)
            Issue.record("Expected the unchanged 64-slot limit to reject the sixty-fifth key")
        } catch VoiceMixerError.capacityExceeded {}
    }

    private func event(
        _ instrument: NoteEvent.Instrument, note: Int = 0, rr: Int = 0, start: Int = 0,
        hold: Int, release: Int = 0, velocity: Double = 0.5
    ) throws -> NoteEvent {
        let role =
            instrument == .bass
            ? "bass" : ([.guitar, .piano].contains(instrument) ? "support" : "drum")
        let values: [String: Any] = [
            "instrument": instrument.rawValue, "role": role, "articulation": "normal",
            "note": note, "roundRobin": rr, "beat": 0, "velocity": velocity, "pan": 0.1,
            "startFrame": start, "gateEndFrame": start + hold,
            "releaseEndFrame": start + hold + release,
        ]
        return try JSONDecoder().decode(
            NoteEvent.self, from: JSONSerialization.data(withJSONObject: values))
    }

    /// This oracle registers every prepared sample in full; it never computes a trim length.
    private func fullSampleMixer(_ events: [NoteEvent], preparer: TonalSamplePreparer) throws
        -> OpaquePointer
    {
        let handle = try #require(ll_mixer_create())
        do {
            try #require(ll_mixer_configure_buses(handle, 0.38))
            var slots: [String: UInt32] = [:]
            var score: [LLEvent] = []
            for event in events {
                let instrument = try #require(TonalInstrument(rawValue: event.instrument.rawValue))
                let takes =
                    instrument == .piano ? 1 : ([.guitar, .shaker].contains(instrument) ? 4 : 2)
                let layer = instrument == .hat && event.velocity >= 0.72 ? 2 : 1
                let key =
                    "\(instrument.rawValue)/\(event.note)/\(event.roundRobin % takes)/\(layer)"
                if slots[key] == nil {
                    let sample = try preparer.prepare(
                        instrument: instrument, note: event.note, roundRobin: event.roundRobin,
                        warmth: 0.78, velocity: event.velocity)
                    let slot = sample.samples.withUnsafeBufferPointer {
                        ll_mixer_add_sample(
                            handle, $0.baseAddress, UInt32(sample.frames), UInt32(sample.channels))
                    }
                    try #require(slot >= 0)
                    slots[key] = UInt32(slot)
                }
                let identifier: UInt8 =
                    switch instrument {
                    case .guitar: 0
                    case .piano: 1
                    case .bass: 2
                    case .kick: 3
                    case .snare: 4
                    case .hat: 5
                    case .shaker: 6
                    }
                score.append(
                    LLEvent(
                        start_frame: UInt64(event.startFrame),
                        sample_index: try #require(slots[key]),
                        hold_frames: UInt32(event.gateEndFrame - event.startFrame),
                        release_frames: UInt32(event.releaseEndFrame - event.gateEndFrame),
                        velocity: Float(event.velocity), pan: Float(event.pan),
                        instrument: identifier,
                        connected: event.articulation == .connected ? 1 : 0,
                        priority: [.melody, .bass].contains(event.role)
                            ? 2 : (event.role == .answer ? 1 : 0),
                        midi: UInt8(event.note)))
            }
            try #require(
                score.withUnsafeBufferPointer {
                    ll_mixer_load_events(handle, $0.baseAddress, UInt32($0.count))
                })
            return handle
        } catch {
            ll_mixer_destroy(handle)
            throw error
        }
    }

    private func paired(_ events: [NoteEvent], frames: Int) throws -> TonalVoiceMixer {
        let source = try preparer()
        let original = try fullSampleMixer(events, preparer: source)
        defer { ll_mixer_destroy(original) }
        let mixer = try TonalVoiceMixer(
            preparer: source, events: events, warmth: 0.78, busEnergy: 0.38)
        for partitions in [[512], [1, 17, 256, 1023]] {
            mixer.reset()
            ll_mixer_reset(original)
            var position = 0
            var block = 0
            while position < frames {
                let count = min(partitions[block % partitions.count], frames - position)
                var actual = [RhythmBusFrame](repeating: RhythmBusFrame(), count: count)
                var expected = actual
                try #require(actual.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
                try #require(
                    expected.withUnsafeMutableBufferPointer {
                        ll_mixer_render_buses(original, $0.baseAddress, UInt32(count))
                    })
                let identical = actual.withUnsafeBytes { left in
                    expected.withUnsafeBytes { right in left.elementsEqual(right) }
                }
                try #require(
                    identical, "Prepared PCM changed a bus field at block starting \(position)")
                position += count
                block += 1
            }
            #expect(mixer.stolenVoices == Int(ll_mixer_steals(original)))
            #expect(mixer.droppedEvents == Int(ll_mixer_dropped_events(original)))
            #expect(mixer.activeVoices == Int(ll_mixer_active_voices(original)))
        }
        return mixer
    }
}
