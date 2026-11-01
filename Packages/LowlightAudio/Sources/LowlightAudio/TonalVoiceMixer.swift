// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum VoiceMixerError: Error { case invalidScore, capacityExceeded }

/// Separate raw harmonic buses, processed rhythm buses, and the shared kick-duck factor.
public typealias RhythmBusFrame = LLBusFrame

/// Single-owner render session. Construction/preparation/destruction run off the callback.
/// The C kernel owns immutable PCM and score copies; no borrowed Swift array survives setup.
public final class TonalVoiceMixer {
    private let handle: OpaquePointer
    private struct Key: Hashable {
        let instrument: TonalInstrument
        let note, roundRobin, layer: Int
    }

    private static func key(for event: NoteEvent) throws -> Key {
        guard let instrument = TonalInstrument(rawValue: event.instrument.rawValue) else {
            throw VoiceMixerError.invalidScore
        }
        let takes =
            switch instrument {
            case .guitar, .shaker: 4
            case .piano: 1
            default: 2
            }
        return Key(
            instrument: instrument, note: event.note, roundRobin: event.roundRobin % takes,
            layer: instrument == .hat && event.velocity >= 0.72 ? 2 : 1)
    }

    /// Starts with empty signal history at the absolute origin. Events and fades
    /// use that same clock; earlier events are rejected before sample preparation.
    /// This does not seek within a song or restore notes already in progress.
    public init(
        preparer: TonalSamplePreparer, events: [NoteEvent], warmth: Double,
        busEnergy: Double? = nil, rackFades: SongRackFades? = nil, frameOrigin: UInt64 = 0
    ) throws {
        guard events.count <= Int(LL_EVENT_LIMIT), warmth.isFinite,
            frameOrigin <= UInt64(MusicalTime.maximumFrame)
        else {
            throw VoiceMixerError.invalidScore
        }
        if let busEnergy, !busEnergy.isFinite || !(0...1).contains(busEnergy) {
            throw VoiceMixerError.invalidScore
        }
        var previous: Int64 = -1
        var requiredFrames: [Key: Int] = [:]
        for event in events {
            try event.validate()
            guard event.startFrame >= Int64(frameOrigin), event.startFrame >= previous else {
                throw VoiceMixerError.invalidScore
            }
            previous = event.startFrame
            if [.guitar, .piano, .bass].contains(event.instrument) {
                let key = try Self.key(for: event)
                requiredFrames[key] = max(
                    requiredFrames[key] ?? 0, Int(event.releaseEndFrame - event.startFrame))
            }
        }
        guard let handle = ll_mixer_create() else { throw VoiceMixerError.capacityExceeded }
        do {
            guard ll_mixer_configure_origin(handle, frameOrigin) else {
                throw VoiceMixerError.invalidScore
            }
            if let busEnergy, !ll_mixer_configure_buses(handle, busEnergy) {
                throw VoiceMixerError.invalidScore
            }
            if let rackFades {
                var configuration = rackFades.configuration
                guard ll_mixer_configure_fades(handle, &configuration) else {
                    throw VoiceMixerError.invalidScore
                }
            }
            var slots: [Key: UInt32] = [:]
            var score: [LLEvent] = []
            for event in events {
                let key = try Self.key(for: event)
                let instrument = key.instrument
                if slots[key] == nil {
                    guard slots.count < Int(LL_SAMPLE_LIMIT) else {
                        throw VoiceMixerError.capacityExceeded
                    }
                    let sample = try preparer.prepare(
                        instrument: instrument, note: key.note,
                        roundRobin: key.roundRobin, warmth: warmth, velocity: event.velocity)
                    // Preserve the kernel's full-sample bounds, including discarded suffixes.
                    guard (1...2).contains(sample.channels),
                        sample.samples.count.isMultiple(of: sample.channels),
                        (1...215_513).contains(sample.frames),
                        sample.samples.allSatisfy({ $0.isFinite && abs($0) <= 8 })
                    else { throw VoiceMixerError.capacityExceeded }
                    // Prepare the whole body before trimming: filtering and normalization
                    // need it. Tonal/bass readers cannot reach beyond any event's lifetime;
                    // percussion still plays its complete shaped body regardless of gates.
                    let frames = min(sample.frames, requiredFrames[key] ?? sample.frames)
                    let slot = sample.samples.withUnsafeBufferPointer {
                        ll_mixer_add_sample(
                            handle, $0.baseAddress, UInt32(frames), UInt32(sample.channels))
                    }
                    guard slot >= 0 else { throw VoiceMixerError.capacityExceeded }
                    slots[key] = UInt32(slot)
                }
                guard let slot = slots[key] else { throw VoiceMixerError.invalidScore }
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
                        start_frame: UInt64(event.startFrame), sample_index: slot,
                        hold_frames: UInt32(event.gateEndFrame - event.startFrame),
                        release_frames: UInt32(event.releaseEndFrame - event.gateEndFrame),
                        velocity: Float(event.velocity), pan: Float(event.pan),
                        instrument: identifier,
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

    /// Requires busEnergy at construction; optional rackFades precede bus filters.
    /// Bass remains before ducking for a later shared mix. Dry rendering stays unfaded.
    /// Both render views advance the same voices, filters, duck envelope, and playhead.
    public func renderBuses(into buffer: UnsafeMutableBufferPointer<RhythmBusFrame>) -> Bool {
        guard buffer.count <= UInt32.max else { return false }
        return ll_mixer_render_buses(handle, buffer.baseAddress, UInt32(buffer.count))
    }

    /// Restores the configured origin with empty voices, filters, ducking, and counters.
    public func reset() { ll_mixer_reset(handle) }
    public var activeVoices: Int { Int(ll_mixer_active_voices(handle)) }
    public var stolenVoices: Int { Int(ll_mixer_steals(handle)) }
    public var droppedEvents: Int { Int(ll_mixer_dropped_events(handle)) }
    /// Absolute 32 kHz frame position, shared by dry and bus rendering.
    public var position: UInt64 { ll_mixer_position(handle) }
    public var preparedBytes: Int { Int(ll_mixer_sample_bytes(handle)) }
}
