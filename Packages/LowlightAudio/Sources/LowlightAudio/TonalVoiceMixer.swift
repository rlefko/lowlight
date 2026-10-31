// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum VoiceMixerError: Error { case invalidScore, capacityExceeded }

/// Single-owner render session. Construction/preparation/destruction run off the callback.
/// The C kernel owns immutable PCM and score copies; no borrowed Swift array survives setup.
public final class TonalVoiceMixer {
    private let handle: OpaquePointer
    private struct Key: Hashable {
        let instrument: TonalInstrument
        let note, roundRobin: Int
    }

    public init(preparer: TonalSamplePreparer, events: [NoteEvent], warmth: Double) throws {
        guard events.count <= Int(LL_EVENT_LIMIT), warmth.isFinite else {
            throw VoiceMixerError.invalidScore
        }
        var previous: Int64 = -1
        for event in events {
            try event.validate()
            guard [.guitar, .piano, .bass].contains(event.instrument), event.startFrame >= previous
            else {
                throw VoiceMixerError.invalidScore
            }
            previous = event.startFrame
        }
        guard let handle = ll_mixer_create() else { throw VoiceMixerError.capacityExceeded }
        do {
            var slots: [Key: UInt32] = [:]
            var score: [LLEvent] = []
            for event in events {
                guard let instrument = TonalInstrument(rawValue: event.instrument.rawValue) else {
                    throw VoiceMixerError.invalidScore
                }
                let key = Key(
                    instrument: instrument, note: event.note,
                    roundRobin: instrument == .guitar
                        ? event.roundRobin % 4 : (instrument == .bass ? event.roundRobin % 2 : 0))
                if slots[key] == nil {
                    guard slots.count < Int(LL_SAMPLE_LIMIT) else {
                        throw VoiceMixerError.capacityExceeded
                    }
                    let sample = try preparer.prepare(
                        instrument: instrument, note: key.note,
                        roundRobin: key.roundRobin, warmth: warmth)
                    let slot = sample.samples.withUnsafeBufferPointer {
                        ll_mixer_add_sample(
                            handle, $0.baseAddress, UInt32(sample.frames), UInt32(sample.channels))
                    }
                    guard slot >= 0 else { throw VoiceMixerError.capacityExceeded }
                    slots[key] = UInt32(slot)
                }
                guard let slot = slots[key] else { throw VoiceMixerError.invalidScore }
                score.append(
                    LLEvent(
                        start_frame: UInt64(event.startFrame), sample_index: slot,
                        hold_frames: UInt32(event.gateEndFrame - event.startFrame),
                        release_frames: UInt32(event.releaseEndFrame - event.gateEndFrame),
                        velocity: Float(event.velocity), pan: Float(event.pan),
                        instrument: instrument == .guitar ? 0 : (instrument == .piano ? 1 : 2),
                        connected: event.articulation == .connected ? 1 : 0,
                        priority: [.melody, .bass].contains(event.role)
                            ? 2 : (event.role == .answer ? 1 : 0),
                        midi: UInt8(event.note)))
            }
            guard
                score.withUnsafeBufferPointer({
                    ll_mixer_load_events(handle, $0.baseAddress, UInt32($0.count))
                })
            else {
                throw VoiceMixerError.invalidScore
            }
            self.handle = handle
        } catch {
            ll_mixer_destroy(handle)
            throw error
        }
    }

    deinit { ll_mixer_destroy(handle) }

    /// Supplies an already allocated interleaved stereo buffer at 32 kHz.
    /// No concurrent setup/reset/render calls. Future device callbacks will call the C kernel directly.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard buffer.count.isMultiple(of: 2), buffer.count / 2 <= UInt32.max else { return false }
        return ll_mixer_render(handle, buffer.baseAddress, UInt32(buffer.count / 2))
    }

    public func reset() { ll_mixer_reset(handle) }
    public var activeVoices: Int { Int(ll_mixer_active_voices(handle)) }
    public var stolenVoices: Int { Int(ll_mixer_steals(handle)) }
    public var droppedEvents: Int { Int(ll_mixer_dropped_events(handle)) }
    public var position: UInt64 { ll_mixer_position(handle) }
    public var preparedBytes: Int { Int(ll_mixer_sample_bytes(handle)) }
}
