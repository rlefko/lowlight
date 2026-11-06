// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

/// Immutable future score and supplemental samples, borrowing this song's fixed arena.
/// The accepted owner must outlive the native source, including all active voices.
final class PreparedSongControlChange {
    let handle: OpaquePointer
    let requiredVoiceSlots, preparedBytes: Int
    let boundaryFrames, inputFrames, advancedFrames: UInt32

    init(handle: OpaquePointer, boundary: UInt32, frames: UInt32, advanced: UInt32) {
        self.handle = handle
        requiredVoiceSlots = Int(ll_song_change_required_voice_slots(handle))
        preparedBytes = Int(ll_song_change_sample_bytes(handle))
        boundaryFrames = boundary
        inputFrames = frames
        advancedFrames = advanced
    }

    deinit { ll_song_change_destroy(handle) }
}

extension PreparedSong {
    /// Builds only the revised outgoing bridge, preserving all consumed source history.
    /// A slower ramp must still end within this song's original prepared extent.
    func makeControlChange(
        offer: LLSongChangeOffer, revisedSchedule: SongSchedule, boundaryFrames: UInt32,
        preparer: TonalSamplePreparer, cancellation: PreparationCancellation? = nil
    ) throws -> PreparedSongControlChange {
        try PreparationMode.perform {
            try cancellation?.check()
            guard offer.first == handle, controlChange == nil else {
                throw PreparedSessionError.preparationFailed
            }
            try revisedSchedule.validate()
            let revisedLayout = try SongRenderLayout(schedule: revisedSchedule)
            let originalFades = try SongRackFades(schedule: revisedSchedule)
            let outro = try revisedSchedule.outgoing.ramp.frame(at: 0)
            let localOutro = outro - Int64(layout.frameOrigin)
            guard revisedLayout.frameOrigin == layout.frameOrigin,
                localOutro == Int64(offer.outro_start_frames),
                localOutro >= Int64(boundaryFrames)
            else { throw PreparedSessionError.preparationFailed }
            let advanced = UInt32(localOutro) - boundaryFrames
            guard advanced < revisedLayout.inputFrames,
                revisedLayout.inputFrames - advanced <= layout.inputFrames
            else { throw PreparedSessionError.preparationFailed }
            let frames = revisedLayout.inputFrames - advanced
            let events = try EventPlanner.events(for: revisedSchedule).filter {
                $0.startFrame >= outro
            }
            let fades = LLRackFades(
                tonal_in_start_frame: originalFades.tonalInStartFrame,
                tonal_in_end_frame: originalFades.tonalInEndFrame,
                tonal_out_start_frame: originalFades.tonalOutStartFrame - Double(advanced),
                tonal_out_end_frame: originalFades.tonalOutEndFrame - Double(advanced),
                rhythm_in_frame: originalFades.rhythmInFrame,
                rhythm_out_frame: originalFades.rhythmOutFrame - Double(advanced))
            var mask: UInt16 = 0
            for pitch in revisedSchedule.outgoing.pivot.pcs { mask |= 1 << pitch }
            var offer = offer
            guard let change = ll_song_pair_begin_change(&offer) else {
                throw PreparedSessionError.preparationFailed
            }
            do {
                let score = try source.mixer.prepareChangeEvents(
                    change: change, events: events, shiftFrames: advanced,
                    preparer: preparer, cancellation: cancellation)
                try cancellation?.check()
                let success = score.withUnsafeBufferPointer { buffer in
                    var configuration = LLSongChangeScore(
                        events: buffer.baseAddress, samples: nil,
                        event_count: UInt32(buffer.count), sample_count: 0,
                        boundary_frames: boundaryFrames, input_frames: frames,
                        pivot_pitch_classes: mask, fades: fades)
                    return ll_song_change_finish(change, &configuration)
                }
                guard success else { throw PreparedSessionError.preparationFailed }
                try cancellation?.check()
                return PreparedSongControlChange(
                    handle: change, boundary: boundaryFrames, frames: frames, advanced: advanced)
            } catch {
                ll_song_change_destroy(change)
                throw error
            }
        }
    }

    /// Reserve the complete future demand after old-successor withdrawal and before
    /// constructing its replacement. On rollback, restore only after the candidate dies.
    func retainControlChange(_ change: PreparedSongControlChange) throws {
        precondition(controlChange == nil)
        try reservation?.replaceVoiceSlots(change.requiredVoiceSlots)
        reservation?.replacePCMBytes(change.preparedBytes)
        controlChange = change
        source.mixer.controlChangeOwner = change
    }

    // Only unpublished work or a rejected/rolled-back acknowledgment may be discarded.
    func discardControlChange() {
        guard controlChange != nil else { return }
        reservation?.restoreVoiceSlots(originalVoiceSlots)
        reservation?.replacePCMBytes(originalPreparedBytes)
        source.mixer.controlChangeOwner = nil
        controlChange = nil
    }
}

extension TonalVoiceMixer {
    func prepareChangeEvents(
        change: OpaquePointer, events: [NoteEvent], shiftFrames: UInt32,
        preparer: TonalSamplePreparer, cancellation: PreparationCancellation?
    ) throws -> [LLEvent] {
        var needed: [Key: Int] = [:]
        for event in events {
            try event.validate()
            guard event.startFrame >= Int64(shiftFrames) else {
                throw VoiceMixerError.invalidScore
            }
            let key = try Self.key(for: event)
            needed[key] = max(needed[key] ?? 0, Int(event.releaseEndFrame - event.startFrame))
        }
        var slots: [Key: UInt32] = [:]
        var result: [LLEvent] = []
        for event in events {
            try cancellation?.check()
            let key = try Self.key(for: event)
            if slots[key] == nil {
                let isPrefix = [.guitar, .piano, .bass].contains(key.instrument)
                let required = needed[key] ?? 0
                let slot: Int32
                if let original = originalSamples[key],
                    !isPrefix || original.frames >= min(original.completeFrames, required)
                {
                    var sample = LLSongChangeSample(
                        original_sample: Int32(original.slot), pcm: nil, frames: 0, channels: 0)
                    slot = ll_song_change_add_sample(change, &sample)
                } else {
                    // Use the original rack encoding and shared calibration row for new keys.
                    let sample = try key.sample(
                        preparer: preparer, warmth: warmth, velocity: event.velocity,
                        live: useLiveTonalSamples)
                    guard (1...2).contains(sample.channels),
                        sample.samples.count.isMultiple(of: sample.channels),
                        (1...215_513).contains(sample.frames),
                        sample.samples.allSatisfy({ $0.isFinite && abs($0) <= 8 })
                    else { throw VoiceMixerError.capacityExceeded }
                    try cancellation?.check()
                    let frames = isPrefix ? min(sample.frames, required) : sample.frames
                    slot = sample.samples.withUnsafeBufferPointer { buffer in
                        var prepared = LLSongChangeSample(
                            original_sample: -1, pcm: buffer.baseAddress,
                            frames: UInt32(frames), channels: UInt32(sample.channels))
                        if useLiveTonalSamples, let row = key.calibrationKey {
                            return ll_song_change_add_tonal_sample(change, &prepared, row)
                        }
                        return ll_song_change_add_sample(change, &prepared)
                    }
                }
                guard slot >= 0 else { throw VoiceMixerError.capacityExceeded }
                slots[key] = UInt32(slot)
            }
            guard let slot = slots[key] else { throw VoiceMixerError.invalidScore }
            let identifier: UInt8 =
                switch key.instrument {
                case .guitar: 0
                case .piano: 1
                case .bass: 2
                case .kick: 3
                case .snare: 4
                case .hat: 5
                case .shaker: 6
                }
            result.append(
                LLEvent(
                    start_frame: UInt64(event.startFrame) - UInt64(shiftFrames), sample_index: slot,
                    hold_frames: UInt32(event.gateEndFrame - event.startFrame),
                    release_frames: UInt32(event.releaseEndFrame - event.gateEndFrame),
                    velocity: Float(event.velocity), pan: Float(event.pan), instrument: identifier,
                    connected: event.articulation == .connected ? 1 : 0,
                    priority: [.melody, .bass].contains(event.role)
                        ? 2 : (event.role == .answer ? 1 : 0), midi: UInt8(event.note)))
        }
        return result
    }
}
