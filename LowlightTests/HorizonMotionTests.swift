// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import Lowlight

struct HorizonMotionTests {
    @Test func everySuppressionConditionStopsTheSchedule() {
        for expected in [
            HorizonGate.active, .playback, .scene, .covered, .offscreen, .lowPower, .reduceMotion,
            .disabled,
        ] {
            let gate = HorizonGate(
                playing: expected != .playback, sceneActive: expected != .scene,
                visible: expected != .offscreen, covered: expected == .covered,
                lowPower: expected == .lowPower, reduceMotion: expected == .reduceMotion,
                disabled: expected == .disabled)
            #expect(gate == expected)
        }
        let coveredInBackground = HorizonGate(
            playing: true, sceneActive: false, visible: true, covered: true, lowPower: false,
            reduceMotion: false, disabled: false)
        #expect(coveredInBackground == .scene)
    }

    @Test func usesGeneratedFrameAndAdvancesAtTheSelectedTempo() {
        let transport = HorizonTransport(
            seed: 23, canonicalFrame: 96_000, snapshotPosition: 12_000,
            position: 44_000, tempo: 60, playing: true)
        let time = ContinuousClock.now
        let clock = HorizonAnchor(transport: transport, time: time)
        #expect(transport.frame == 128_000 && transport.seed == 23)
        #expect(abs(clock.phase(at: time) - .pi / 2) < 1e-9)
        // After being covered for 164 seconds the next visible frame is evaluated directly.
        #expect(abs(clock.phase(at: time.advanced(by: .seconds(164))) - .pi) < 1e-9)
        let next = HorizonTransport(
            seed: 97, canonicalFrame: 32_000, snapshotPosition: 8_000,
            position: 7_000, tempo: 96, playing: true)
        let handoff = HorizonAnchor(transport: next, time: time.advanced(by: .seconds(164)))
        #expect(next.frame == 32_000 && next.seed == 97)
        #expect(abs(handoff.phase(at: time.advanced(by: .seconds(165))) - 0.4 * .pi) < 1e-9)
    }

    @Test func handoffWhileCoveredKeepsTheDisplayedSeedAndPhaseUntilVisible() {
        let now = ContinuousClock.now
        func song(_ seed: UInt64) -> HorizonAnchor {
            let transport = HorizonTransport(
                seed: seed, canonicalFrame: 64_000, snapshotPosition: 0, position: 0,
                tempo: 90, playing: true)
            return HorizonAnchor(transport: transport, time: now)
        }
        let first = HorizonFrame().updated(from: song(7), at: now, gate: .active)
        let later = now.advanced(by: .seconds(3))
        let nextSong = song(17)
        for gate in [
            HorizonGate.covered, .offscreen, .scene, .playback, .lowPower, .reduceMotion, .disabled,
        ] {
            #expect(first.updated(from: nextSong, at: later, gate: gate) == first)
        }
        let resumed = first.updated(from: nextSong, at: later, gate: .active)
        #expect(resumed.seed == 17 && resumed.phase != first.phase)
        #expect(HorizonFrame().updated(from: nextSong, at: now, gate: .disabled).seed == 17)
        #expect(HorizonFrame().updated(from: nextSong, at: now, gate: .scene).seed == nil)
    }

    @Test func pausedClockKeepsItsFrameAndMissingSelectionIsStatic() {
        let transport = HorizonTransport(
            seed: 1, canonicalFrame: 256_000, snapshotPosition: 0, position: 0,
            tempo: 60, playing: false)
        let now = ContinuousClock.now
        let paused = HorizonAnchor(transport: transport, time: now)
        #expect(paused.phase(at: now) == paused.phase(at: now.advanced(by: .seconds(3))))
        #expect(abs(paused.phase(at: now) - .pi) < 1e-9)
        #expect(HorizonAnchor(transport: nil, time: now).phase(at: now) == 0)
    }
}
