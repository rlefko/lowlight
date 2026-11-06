// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP

extension PreparedSession {
    func makeEffectsEndpoint() -> EffectsEndpoint? {
        finiteFrameCount == nil ? EffectsEndpoint(owner: self) : nil
    }

    static func tonalBin(_ warmth: Double) -> UInt32 {
        UInt32((TonalSamplePreparer.quantizedWarmth(warmth) * 100).rounded())
    }

    /// Retains the pair throughout an off-callback publication or observation. The pair
    /// synchronizes producers and exposes atomic progress independently of preparation.
    final class EffectsEndpoint: @unchecked Sendable {
        private let owner: PreparedSession

        fileprivate init(owner: PreparedSession) { self.owner = owner }

        func send(revision: UInt64, warmth: Double, space: Double, texture: Double) -> Bool {
            guard warmth.isFinite, space.isFinite, texture.isFinite,
                (0...1).contains(warmth), (0...1).contains(space), (0...1).contains(texture)
            else { return false }
            let values = LLEffectValues(warmth: warmth, space: space, texture: texture)
            return ll_song_pair_send_effects(
                owner.handle, values, PreparedSession.tonalBin(warmth), revision)
        }

        var progress:
            (
                adoptedRevision: UInt64, settledRevision: UInt64, warmth: Double, space: Double,
                texture: Double
            )
        {
            let state = ll_song_pair_effect_progress(owner.handle)
            let values = state.settled_values
            return (
                state.adopted_revision, state.settled_revision, values.warmth, values.space,
                values.texture
            )
        }
    }
}
