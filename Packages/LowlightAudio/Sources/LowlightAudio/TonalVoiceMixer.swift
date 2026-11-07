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
    let originalSamples: [Key: SampleReference]
    let warmth: Double
    let useLiveTonalSamples: Bool
    var controlChangeOwner: PreparedSongControlChange?
    // An accepted transport table is borrowed by the native mixer. Its owner outlives
    // that borrower regardless of the enclosing song's stored-property release order.
    var advanceOwner: PreparedSongAdvance?
    // Module-owned composition may borrow this handle while retaining the mixer.
    // The borrower must serialize all calls and must never destroy the mixer handle.
    var borrowedHandle: OpaquePointer { handle }
    struct Key: Hashable {
        let instrument: TonalInstrument
        let note, roundRobin, layer: Int
        var bandVoice: BandVoice?
        var calibrationKey: UInt32? {
            guard (50...69).contains(note) else { return nil }
            if let bandVoice { return bandVoice.sampleKey(note: note) }
            switch instrument {
            case .guitar: return UInt32((note - 50) * 4 + roundRobin)
            case .piano: return UInt32(80 + note - 50)
            default: return nil
            }
        }

        func sample(preparer: TonalSamplePreparer, warmth: Double, velocity: Double, live: Bool)
            throws -> PreparedTonalSample
        {
            if let bandVoice {
                return try preparer.bandBank.prepare(
                    bandVoice, note: note, warmth: warmth, live: live)
            }
            if live, calibrationKey != nil {
                // Initial and supplemental tonal keys use the same verified gain table.
                try preparer.calibrationBank.verify()
                return try preparer.tonalSource(
                    instrument: instrument, note: note, roundRobin: roundRobin)
            }
            return try preparer.prepare(
                instrument: instrument, note: note, roundRobin: roundRobin, warmth: warmth,
                velocity: velocity)
        }
    }

    struct SampleReference {
        let slot: UInt32
        let frames, completeFrames, channels: Int
    }

    static func key(for event: NoteEvent, bandColors: Bool = true) throws -> Key {
        if bandColors, let color = event.color {
            let voice: BandVoice =
                switch color {
                case .electricPiano: event.velocity >= 0.50 ? .electricAccent : .electricSoft
                case .vibraphone: .vibraphone
                case .tenor:
                    event.gateEndFrame - event.startFrame <= 10_240 ? .tenorShort : .tenorLong
                }
            // Route all three recorded colors to the existing keys/room send.
            return Key(
                instrument: .piano, note: event.note, roundRobin: 0, layer: 1, bandVoice: voice)
        }
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
    /// Swift preparation preserves subnormals and restores caller FP state, including on failure.
    public convenience init(
        preparer: TonalSamplePreparer, events: [NoteEvent], warmth: Double,
        busEnergy: Double? = nil, rackFades: SongRackFades? = nil, frameOrigin: UInt64 = 0,
        cancellation: PreparationCancellation? = nil
    ) throws {
        try self.init(
            preparer: preparer, events: events, warmth: warmth, busEnergy: busEnergy,
            rackFades: rackFades, frameOrigin: frameOrigin, cancellation: cancellation,
            useLiveTonalSamples: true)
    }

    // The baked path remains an independent fixed-control oracle for native comparison.
    init(
        preparer: TonalSamplePreparer, events: [NoteEvent], warmth: Double,
        busEnergy: Double? = nil, rackFades: SongRackFades? = nil, frameOrigin: UInt64 = 0,
        cancellation: PreparationCancellation? = nil, useLiveTonalSamples: Bool
    ) throws {
        self.useLiveTonalSamples = useLiveTonalSamples
        let prepared = try PreparationMode.perform {
            try Self.makeHandle(
                preparer: preparer, events: events, warmth: warmth,
                busEnergy: busEnergy, rackFades: rackFades, frameOrigin: frameOrigin,
                cancellation: cancellation, useLiveTonalSamples: useLiveTonalSamples)
        }
        handle = prepared.handle
        originalSamples = prepared.samples
        self.warmth = warmth
    }

    // Validation, sample preparation, and event conversion share the preparation scope.
    @inline(never)
    private static func makeHandle(
        preparer: TonalSamplePreparer, events: [NoteEvent], warmth: Double,
        busEnergy: Double?, rackFades: SongRackFades?, frameOrigin: UInt64,
        cancellation: PreparationCancellation?, useLiveTonalSamples: Bool
    ) throws -> (handle: OpaquePointer, samples: [Key: SampleReference]) {
        try cancellation?.check()
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
                let key = try Self.key(for: event, bandColors: preparer.bandColors)
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
            if useLiveTonalSamples {
                let calibration = try LiveTonalCalibration.shared.get()
                let bin = UInt32((TonalSamplePreparer.quantizedWarmth(warmth) * 100).rounded())
                guard ll_mixer_configure_tonal(handle, calibration.handle, bin) else {
                    throw SamplePreparationError.invalidBank
                }
            }
            var slots: [Key: UInt32] = [:]
            var references: [Key: SampleReference] = [:]
            var score: [LLEvent] = []
            for event in events {
                try cancellation?.check()
                let key = try Self.key(for: event, bandColors: preparer.bandColors)
                let instrument = key.instrument
                if slots[key] == nil {
                    guard slots.count < Int(LL_SAMPLE_LIMIT) else {
                        throw VoiceMixerError.capacityExceeded
                    }
                    let sample = try key.sample(
                        preparer: preparer, warmth: warmth, velocity: event.velocity,
                        live: useLiveTonalSamples)
                    try cancellation?.check()
                    // Preserve the kernel's full-sample bounds, including discarded suffixes.
                    guard (1...2).contains(sample.channels),
                        sample.samples.count.isMultiple(of: sample.channels),
                        (1...215_513).contains(sample.frames),
                        sample.samples.allSatisfy({ $0.isFinite && abs($0) <= 8 })
                    else { throw VoiceMixerError.capacityExceeded }
                    // Retain only the reachable tonal/bass prefix after preparing the source.
                    // Percussion plays its complete shaped body regardless of event gates.
                    let frames = min(sample.frames, requiredFrames[key] ?? sample.frames)
                    let slot = sample.samples.withUnsafeBufferPointer { buffer in
                        if useLiveTonalSamples, let row = key.calibrationKey {
                            return ll_mixer_add_tonal_sample(
                                handle, buffer.baseAddress, UInt32(frames), UInt32(sample.channels),
                                row)
                        }
                        return ll_mixer_add_sample(
                            handle, buffer.baseAddress, UInt32(frames), UInt32(sample.channels))
                    }
                    guard slot >= 0 else { throw VoiceMixerError.capacityExceeded }
                    slots[key] = UInt32(slot)
                    references[key] = SampleReference(
                        slot: UInt32(slot), frames: frames, completeFrames: sample.frames,
                        channels: sample.channels)
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
            try cancellation?.check()
            guard
                score.withUnsafeBufferPointer({
                    ll_mixer_load_events(handle, $0.baseAddress, UInt32($0.count))
                })
            else {
                throw VoiceMixerError.invalidScore
            }
            return (handle, references)
        } catch {
            ll_mixer_destroy(handle)
            throw error
        }
    }

    deinit { withExtendedLifetime((advanceOwner, controlChangeOwner)) { ll_mixer_destroy(handle) } }

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
    /// Conservative loaded-score demand before voice stealing; may exceed 64.
    /// Includes the reserved bass slot and ignores neither silent PCM nor rack fades.
    public var requiredVoiceSlots: Int { Int(ll_mixer_required_voice_slots(handle)) }
}
