// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightAudio
import LowlightPlanning
import OSLog
import SwiftUI

/// A small value copied only on playback publications. The two frame counters share a
/// rate, but Next and restoration can give the canonical and transport clocks different origins.
struct HorizonTransport: Equatable {
    let seed: UInt64
    let frame: UInt64
    let tempo: Double
    let playing: Bool

    init(
        seed: UInt64, canonicalFrame: UInt64, snapshotPosition: UInt64, position: UInt64,
        tempo: Double, playing: Bool
    ) {
        self.seed = seed
        let framesSinceSnapshot = position > snapshotPosition ? position - snapshotPosition : 0
        frame = canonicalFrame + framesSinceSnapshot
        self.tempo = tempo
        self.playing = playing
    }

    @MainActor init?(_ playback: SessionPlayback?) {
        guard let playback, let snapshot = playback.listeningSnapshot else { return nil }
        let running =
            playback.state == .playing && playback.requestedPlayback
            && playback.mediaServicesAvailable && !playback.isInterrupted
            && (playback.sourceStatus == .ready || playback.sourceStatus == .rendering)
            && (playback.preparationStatus == .running || playback.preparationStatus == .preparing)
        self.init(
            seed: snapshot.currentSong.takeSeed, canonicalFrame: snapshot.canonicalFrame,
            snapshotPosition: snapshot.transportFrame, position: playback.position,
            tempo: snapshot.currentSong.tempo, playing: running)
    }

    /// One quiet cycle per four bars, derived from generated musical time.
    func phase(elapsed: Duration) -> Double {
        let parts = elapsed.components
        let elapsedSeconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let seconds =
            Double(frame) / MusicalTime.sampleRate + (playing ? max(0, elapsedSeconds) : 0)
        let cycle = (seconds * tempo / (60 * 16)).truncatingRemainder(dividingBy: 1)
        return cycle * 2 * .pi
    }
}

struct HorizonAnchor {
    let transport: HorizonTransport?
    let time: ContinuousClock.Instant

    func phase(at now: ContinuousClock.Instant) -> Double {
        transport?.phase(elapsed: time.duration(to: now)) ?? 0
    }
}

/// Keep the displayed seed and phase together. Handoffs may update the musical anchor
/// behind a sheet or in the background without invalidating the rendered landscape.
struct HorizonFrame: Equatable {
    var phase = 0.0
    var seed: UInt64?

    func updated(from anchor: HorizonAnchor, at time: ContinuousClock.Instant, gate: HorizonGate)
        -> Self
    {
        guard let transport = anchor.transport else { return self }
        switch gate {
        case .active: break
        case .lowPower, .reduceMotion, .disabled:
            guard seed == nil else { return self }  // One still frame for a visible static launch.
        default: return self
        }
        return Self(phase: anchor.phase(at: time), seed: transport.seed)
    }
}

enum HorizonGate: String {
    case active, playback, scene, covered, offscreen, lowPower, reduceMotion, disabled

    init(
        playing: Bool, sceneActive: Bool, visible: Bool, covered: Bool, lowPower: Bool,
        reduceMotion: Bool, disabled: Bool
    ) {
        if !sceneActive {
            self = .scene
        } else if covered {
            self = .covered
        } else if !visible {
            self = .offscreen
        } else if disabled {
            self = .disabled
        } else if reduceMotion {
            self = .reduceMotion
        } else if lowPower {
            self = .lowPower
        } else if !playing {
            self = .playback
        } else {
            self = .active
        }
    }
}

struct HorizonMotionView: View {
    let model: ListeningModel
    let covered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var visible = false

    var body: some View {
        let transport = HorizonTransport(model.playback)
        let gate = HorizonGate(
            playing: transport?.playing == true, sceneActive: scenePhase == .active,
            visible: visible, covered: covered, lowPower: lowPower || HorizonDiagnostics.lowPower,
            reduceMotion: reduceMotion || HorizonDiagnostics.reduceMotion,
            disabled: HorizonDiagnostics.disabled)
        HorizonFrames(transport: transport, gate: gate)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .onReceive(
                NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            ) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
            }
    }
}

/// Only this leaf invalidates at the visual rate. It never requests a playback update.
/// Re-entering view samples the retained anchor once, without replaying missed frames.
private struct HorizonFrames: View {
    let transport: HorizonTransport?
    let gate: HorizonGate
    @State private var anchor = HorizonAnchor(transport: nil, time: .now)
    @State private var frame = HorizonFrame()

    var body: some View {
        DuskHorizon(phase: frame.phase, seed: frame.seed ?? 0)
            .onChange(of: transport, initial: true) { _, value in
                anchor = HorizonAnchor(transport: value, time: .now)
                HorizonDiagnostics.sample(value)
                displayFrame(for: gate)
            }
            .task(id: gate) {
                HorizonDiagnostics.gate(gate)
                displayFrame(for: gate)
                guard gate == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(67)) } catch { return }
                    guard !Task.isCancelled else { return }
                    HorizonDiagnostics.tick()
                    displayFrame(for: .active)
                }
            }
    }

    private func displayFrame(for gate: HorizonGate) {
        let next = frame.updated(from: anchor, at: .now, gate: gate)
        if next != frame { frame = next }
    }
}

enum HorizonDiagnostics {
    #if targetEnvironment(simulator)
        private static let settings = ProcessInfo.processInfo.environment
        static let disabled = settings["LOWLIGHT_VISUAL_STATIC"] == "1"
        static let lowPower = settings["LOWLIGHT_VISUAL_LOW_POWER"] == "1"
        static let reduceMotion = settings["LOWLIGHT_VISUAL_REDUCE_MOTION"] == "1"
        private static let trace = settings["LOWLIGHT_VISUAL_TRACE"] == "1"
        private static let traceGate = trace || settings["LOWLIGHT_VISUAL_GATE_TRACE"] == "1"
        private static let logger = Logger(subsystem: "com.rlefko.lowlight", category: "Horizon")
        static func sample(_ sample: HorizonTransport?) {
            if trace, let sample {
                logger.info(
                    "anchor frame=\(sample.frame, privacy: .public) seed=\(sample.seed, privacy: .public) playing=\(sample.playing ? 1 : 0, privacy: .public)"
                )
            }
        }
        static func tick() { if trace { logger.info("tick") } }
        static func draw() { if trace { logger.info("draw") } }
        static func gate(_ gate: HorizonGate) {
            if traceGate { logger.info("gate \(gate.rawValue, privacy: .public)") }
        }
    #else
        static let disabled = false
        static let lowPower = false
        static let reduceMotion = false
        static func sample(_ sample: HorizonTransport?) {}
        static func tick() {}
        static func draw() {}
        static func gate(_ gate: HorizonGate) {}
    #endif
}
