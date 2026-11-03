// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum PreparedSongError: Error { case analysisFailed, unmeasurableBody, preparationFailed }

/// Single-owner finite song with one measured gain and accepted song peak protection.
/// Construction analyzes every logical frame off the callback using fixed scratch.
/// Calls must be serialized; rendering stores no complete song or changing gain.
public final class PreparedSong {
    public let layout: SongRenderLayout
    public let measurement: SongLoudnessMeasurement
    public let gainDecibels, linearMultiplier: Double
    private let source: SongRenderSource
    private let handle: OpaquePointer
    private let reservation: SongPreparationPool.Reservation?
    private typealias Prepared = (
        source: SongRenderSource, handle: OpaquePointer,
        measurement: SongLoudnessMeasurement, gain: LLSongGainValues
    )

    public convenience init(
        layout: SongRenderLayout, preparer: TonalSamplePreparer, events: [NoteEvent],
        takeSeed: UInt32, focus: HarmonicFocus, warmth: Double, energy: Double,
        space: Double, texture: Double, rackFades: SongRackFades
    ) throws {
        try self.init(
            layout: layout, preparer: preparer, events: events, takeSeed: takeSeed,
            focus: focus, warmth: warmth, energy: energy, space: space, texture: texture,
            rackFades: rackFades, reservation: nil)
    }

    convenience init(
        layout: SongRenderLayout, preparer: TonalSamplePreparer, events: [NoteEvent],
        takeSeed: UInt32, focus: HarmonicFocus, warmth: Double, energy: Double,
        space: Double, texture: Double, rackFades: SongRackFades,
        reservation: SongPreparationPool.Reservation?
    ) throws {
        let prepared = try PreparationMode.perform {
            try Self.makeSong(
                layout: layout, preparer: preparer, events: events, takeSeed: takeSeed,
                focus: focus, warmth: warmth, energy: energy, space: space,
                texture: texture, rackFades: rackFades, reservation: reservation)
        }
        self.init(prepared: prepared, reservation: reservation)
    }

    /// Prepares an already formed native schedule on its shared absolute frame clock.
    /// Schedule validation and render-input derivation use the preparation numeric scope;
    /// earlier planning remains a separate contract. Existing score/storage limits apply.
    public convenience init(schedule: SongSchedule, preparer: TonalSamplePreparer) throws {
        try self.init(schedule: schedule, preparer: preparer, reservation: nil)
    }

    convenience init(
        schedule: SongSchedule, preparer: TonalSamplePreparer,
        reservation: SongPreparationPool.Reservation?
    ) throws {
        let prepared = try PreparationMode.perform {
            try Self.makeScheduledSong(
                schedule: schedule, preparer: preparer, reservation: reservation)
        }
        self.init(prepared: prepared, reservation: reservation)
    }

    private init(prepared: Prepared, reservation: SongPreparationPool.Reservation?) {
        layout = prepared.source.layout
        source = prepared.source
        handle = prepared.handle
        self.reservation = reservation
        measurement = prepared.measurement
        gainDecibels = prepared.gain.gain_db
        linearMultiplier = prepared.gain.linear_multiplier
    }

    @inline(never)
    private static func makeScheduledSong(
        schedule: SongSchedule, preparer: TonalSamplePreparer,
        reservation: SongPreparationPool.Reservation?
    ) throws -> Prepared {
        try schedule.validate()
        let song = schedule.song
        let layout = try SongRenderLayout(schedule: schedule)
        let fades = try SongRackFades(schedule: schedule)
        let events = try EventPlanner.events(for: schedule)
        return try makeSong(
            layout: layout, preparer: preparer, events: events,
            takeSeed: UInt32(song.takeSeed), focus: song.focus == "guitar" ? .guitar : .piano,
            warmth: song.controls.warmth, energy: song.energy,
            space: song.controls.space, texture: song.controls.texture, rackFades: fades,
            reservation: reservation)
    }

    @inline(never)
    private static func makeSong(
        layout: SongRenderLayout, preparer: TonalSamplePreparer, events: [NoteEvent],
        takeSeed: UInt32, focus: HarmonicFocus, warmth: Double, energy: Double,
        space: Double, texture: Double, rackFades: SongRackFades,
        reservation: SongPreparationPool.Reservation?
    ) throws -> Prepared {
        let source = try SongRenderSource(
            layout: layout, preparer: preparer, events: events, takeSeed: takeSeed,
            focus: focus, warmth: warmth, energy: energy, space: space,
            texture: texture, rackFades: rackFades)
        // Admission precedes the analysis render; failed construction releases the lease.
        try reservation?.claim(
            voiceSlots: source.requiredVoiceSlots, pcmBytes: source.preparedBytes)
        let body = try SongBodyLoudness(layout: layout)
        var scratch = [Float](repeating: 0, count: 256 * 2)
        try scratch.withUnsafeMutableBufferPointer { buffer in
            while source.position < layout.inputFrames {
                guard let frames = source.render(into: buffer), frames > 0,
                    body.process(UnsafeBufferPointer(start: buffer.baseAddress, count: frames * 2))
                else { throw PreparedSongError.analysisFailed }
            }
        }
        let measurement = try body.finish()
        guard let loudness = measurement.integratedLUFS else {
            throw PreparedSongError.unmeasurableBody
        }
        source.reset()
        guard let handle = ll_song_replay_create(source.borrowedHandle, loudness) else {
            throw PreparedSongError.preparationFailed
        }
        var gain = LLSongGainValues()
        guard ll_song_replay_gain(handle, &gain) else {
            ll_song_replay_destroy(handle)
            throw PreparedSongError.preparationFailed
        }
        return (source, handle, measurement, gain)
    }

    // Destroy the native borrower before releasing its privately retained source.
    deinit { withExtendedLifetime(reservation) { ll_song_replay_destroy(handle) } }

    /// Returns logical frames written, zero at EOF/empty capacity, or nil on failure.
    /// Both processor delays are removed; unused capacity is zeroed. Invalid
    /// dimensions preserve progress; a downstream failure faults until reset.
    public func render(into output: UnsafeMutableBufferPointer<Float>) -> Int? {
        guard output.count.isMultiple(of: 2), output.count / 2 <= UInt32.max else {
            output.update(repeating: 0)
            return nil
        }
        var written: UInt32 = 0
        guard ll_song_replay_render(handle, output.baseAddress, UInt32(output.count / 2), &written)
        else { return nil }
        return Int(written)
    }

    /// Rewinds source and peak history, retaining the measurement and fixed gain.
    public func reset() { ll_song_replay_reset(handle) }
    public var position: UInt32 { ll_song_replay_position(handle) }
    public var isFaulted: Bool { ll_song_replay_faulted(handle) }
    public var preparedBytes: Int { source.preparedBytes }
    public var requiredVoiceSlots: Int { source.requiredVoiceSlots }
    public var stolenVoices: Int { source.stolenVoices }
    public var droppedEvents: Int { source.droppedEvents }
}
