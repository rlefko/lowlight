// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum SongRenderSourceError: Error { case invalidConfiguration, preparationFailed }

/// Single-owner finite voices, glue, room, air, and HP32 source at 32 kHz.
/// Construction/destruction belong off the callback. Output is before body
/// analysis, fixed song gain, and peak protection; no concurrent calls are allowed.
public final class SongRenderSource {
    public let layout: SongRenderLayout
    private let mixer: TonalVoiceMixer
    private let handle: OpaquePointer

    /// Events and fades use the layout's absolute clock. Every onset must fall
    /// inside the song; gates, releases, and effect tails are truncated at its end.
    /// Swift preparation uses round-to-nearest with gradual underflow and restores caller FP state.
    public init(
        layout: SongRenderLayout, preparer: TonalSamplePreparer, events: [NoteEvent],
        takeSeed: UInt32, focus: HarmonicFocus, warmth: Double, energy: Double,
        space: Double, texture: Double, rackFades: SongRackFades,
        cancellation: PreparationCancellation? = nil
    ) throws {
        let prepared = try PreparationMode.perform {
            try Self.makeSource(
                layout: layout, preparer: preparer, events: events, takeSeed: takeSeed,
                focus: focus, warmth: warmth, energy: energy, space: space,
                texture: texture, rackFades: rackFades, cancellation: cancellation)
        }
        self.layout = layout
        mixer = prepared.mixer
        handle = prepared.handle
    }

    @inline(never)
    private static func makeSource(
        layout: SongRenderLayout, preparer: TonalSamplePreparer, events: [NoteEvent],
        takeSeed: UInt32, focus: HarmonicFocus, warmth: Double, energy: Double,
        space: Double, texture: Double, rackFades: SongRackFades,
        cancellation: PreparationCancellation?
    ) throws -> (mixer: TonalVoiceMixer, handle: OpaquePointer) {
        try cancellation?.check()
        guard takeSeed < (UInt32(1) << 31), events.count <= Int(LL_EVENT_LIMIT),
            [warmth, energy, space, texture].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw SongRenderSourceError.invalidConfiguration }
        let origin = Int64(layout.frameOrigin)
        let end = origin + Int64(layout.inputFrames)
        var previous = origin
        for event in events {
            guard event.startFrame >= previous, event.startFrame < end else {
                throw SongRenderSourceError.invalidConfiguration
            }
            previous = event.startFrame
        }
        // The mixer validates every event and fade before decoding any samples.
        let mixer = try TonalVoiceMixer(
            preparer: preparer, events: events, warmth: warmth, busEnergy: energy,
            rackFades: rackFades, frameOrigin: layout.frameOrigin, cancellation: cancellation)
        try cancellation?.check()
        var configuration = LLSongSourceConfig(
            frame_origin: layout.frameOrigin, input_frames: layout.inputFrames,
            take_seed: takeSeed, focus: focus.rawValue, space: space, warmth: warmth,
            texture: texture, rack_fades: rackFades.configuration)
        guard let handle = ll_song_source_create(mixer.borrowedHandle, &configuration) else {
            throw SongRenderSourceError.preparationFailed
        }
        do {
            try cancellation?.check()
        } catch {
            withExtendedLifetime(mixer) { ll_song_source_destroy(handle) }
            throw error
        }
        return (mixer, handle)
    }

    // Destroy the borrower before Swift releases its privately retained mixer.
    deinit { ll_song_source_destroy(handle) }

    // Internal borrowers must retain this source, serialize access, and never destroy its handle.
    var borrowedHandle: OpaquePointer { handle }

    // Worker-only, before publication or after a rejected acknowledgment.
    func retainAdvance(_ advance: PreparedSongAdvance?) { mixer.advanceOwner = advance }

    /// Writes logical stereo frames, removing glue startup and recovering its drain.
    /// Returns frames written, zero at EOF or for empty capacity, or nil on failure.
    /// Unused capacity is zeroed. Invalid dimensions leave progress unchanged;
    /// an unexpected downstream failure faults the source until reset.
    public func render(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
        guard output.count.isMultiple(of: 2), output.count / 2 <= UInt32.max else {
            output.update(repeating: 0)
            return nil
        }
        var written: UInt32 = 0
        guard ll_song_source_render(handle, output.baseAddress, UInt32(output.count / 2), &written)
        else { return nil }
        return Int(written)
    }

    /// Rewinds every stage and logical cursor, retaining prepared PCM and air normalization.
    public func reset() { ll_song_source_reset(handle) }
    public var position: UInt32 { ll_song_source_position(handle) }
    public var isFaulted: Bool { ll_song_source_faulted(handle) }
    public var preparedBytes: Int { mixer.preparedBytes }
    public var requiredVoiceSlots: Int { mixer.requiredVoiceSlots }
    public var stolenVoices: Int { mixer.stolenVoices }
    public var droppedEvents: Int { mixer.droppedEvents }
}
