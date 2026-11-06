// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

public enum SongPreparationPoolError: Error { case rackCapacityExceeded, voiceCapacityExceeded }

/// Single-owner, synchronous admission for at most two prepared song racks.
/// Preparation and destruction of admitted songs must be serialized off the audio callback.
/// Render/reset never touch this pool. It does not schedule, mix, or retire playing songs.
public final class SongPreparationPool {
    public static let maximumRacks = 2
    public static let maximumVoiceSlots = Int(LL_VOICE_LIMIT)
    public static let pcmBytesPerRack = Int(LL_SAMPLE_BYTES)

    public private(set) var reservedRacks = 0
    public private(set) var reservedVoiceSlots = 0
    /// Registered PCM held by admitted sources; excludes preparation scratch and other DSP state.
    public private(set) var preparedPCMBytes = 0
    /// Fixed arena reservation, including a candidate still being prepared; not an RSS estimate.
    public var reservedPCMBytes: Int { reservedRacks * Self.pcmBytesPerRack }

    public init() {}

    public func prepare(
        schedule: SongSchedule, preparer: TonalSamplePreparer,
        cancellation: PreparationCancellation? = nil
    ) throws
        -> PreparedSong
    {
        try cancellation?.check()
        let reservation = try reserveRack()
        return try PreparedSong(
            schedule: schedule, preparer: preparer, reservation: reservation,
            cancellation: cancellation)
    }

    public func prepare(
        layout: SongRenderLayout, preparer: TonalSamplePreparer, events: [NoteEvent],
        takeSeed: UInt32, focus: HarmonicFocus, warmth: Double, energy: Double,
        space: Double, texture: Double, rackFades: SongRackFades,
        cancellation: PreparationCancellation? = nil
    ) throws -> PreparedSong {
        try cancellation?.check()
        let reservation = try reserveRack()
        return try PreparedSong(
            layout: layout, preparer: preparer, events: events, takeSeed: takeSeed,
            focus: focus, warmth: warmth, energy: energy, space: space, texture: texture,
            rackFades: rackFades, reservation: reservation, cancellation: cancellation)
    }

    private func reserveRack() throws -> Reservation {
        guard reservedRacks < Self.maximumRacks else {
            throw SongPreparationPoolError.rackCapacityExceeded
        }
        reservedRacks += 1
        return Reservation(pool: self)
    }

    /// Retained privately by the admitted song; keeps the pool alive without retaining songs.
    final class Reservation {
        private let pool: SongPreparationPool
        private var voiceSlots = 0
        private var pcmBytes = 0
        private var claimed = false

        fileprivate init(pool: SongPreparationPool) { self.pool = pool }

        func claim(voiceSlots: Int, pcmBytes: Int) throws {
            precondition(
                !claimed && voiceSlots >= 0
                    && (0...SongPreparationPool.pcmBytesPerRack).contains(pcmBytes))
            guard voiceSlots <= SongPreparationPool.maximumVoiceSlots - pool.reservedVoiceSlots
            else {
                throw SongPreparationPoolError.voiceCapacityExceeded
            }
            self.voiceSlots = voiceSlots
            self.pcmBytes = pcmBytes
            claimed = true
            pool.reservedVoiceSlots += voiceSlots
            pool.preparedPCMBytes += pcmBytes
        }

        // Worker-only: reserve an edited score's proven bound before callback publication.
        // PCM and rack ownership do not change. Rejection restores the previous bound.
        func replaceVoiceSlots(_ count: Int) throws {
            precondition(claimed && count >= 0)
            let other = pool.reservedVoiceSlots - voiceSlots
            guard count <= SongPreparationPool.maximumVoiceSlots - other else {
                throw SongPreparationPoolError.voiceCapacityExceeded
            }
            pool.reservedVoiceSlots = other + count
            voiceSlots = count
        }

        // Worker-only admission for supplemental PCM within the same fixed arena.
        func replacePCMBytes(_ count: Int) {
            precondition(claimed && (0...SongPreparationPool.pcmBytesPerRack).contains(count))
            pool.preparedPCMBytes += count - pcmBytes
            pcmBytes = count
        }

        func restoreVoiceSlots(_ count: Int) {
            let other = pool.reservedVoiceSlots - voiceSlots
            precondition(
                claimed && count >= 0 && count <= SongPreparationPool.maximumVoiceSlots - other)
            pool.reservedVoiceSlots = other + count
            voiceSlots = count
        }

        deinit {
            pool.reservedVoiceSlots -= voiceSlots
            pool.preparedPCMBytes -= pcmBytes
            pool.reservedRacks -= 1
        }
    }
}
