// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

#if LOWLIGHT_PLAYBACK_COMPARISON
    import AVFAudio
    import Foundation
    import LowlightAudio
    import LowlightPlanning
    import Observation
    import SwiftUI

    enum ComparisonMode: String { case generator, aac, idle }
    enum ComparisonState: String {
        case ready, preparing, playing, running, paused, stopping, stopped, failed
    }

    @MainActor @Observable
    final class PlaybackComparison: NSObject, @preconcurrency AVAudioPlayerDelegate {
        let mode: ComparisonMode?
        let trialID: UUID
        private(set) var state = ComparisonState.ready
        private(set) var frames: UInt64 = 0
        private(set) var errorText: String?
        @ObservationIgnored private let directory = URL.applicationSupportDirectory.appending(
            path: "PlaybackComparison", directoryHint: .isDirectory)
        @ObservationIgnored private var appSHA256: String?
        @ObservationIgnored private var generator: SessionPlayback?
        @ObservationIgnored private var player: AVAudioPlayer?
        @ObservationIgnored private var fixture: ComparisonFixture?
        @ObservationIgnored private var validation: Task<ComparisonFixture, any Error>?
        @ObservationIgnored private var needsDeactivation = false
        @ObservationIgnored private var startCount = 0
        @ObservationIgnored private var requestedPause = false
        @ObservationIgnored private var commandID = 0

        override init() {
            let environment = ProcessInfo.processInfo.environment
            mode = environment["LOWLIGHT_COMPARISON_MODE"].flatMap(ComparisonMode.init(rawValue:))
            let requestedID = environment["LOWLIGHT_COMPARISON_TRIAL_ID"]
            let parsedID = requestedID.flatMap(UUID.init(uuidString:))
            trialID = parsedID ?? UUID()
            super.init()
            if mode == nil {
                state = .failed
                errorText = "Set LOWLIGHT_COMPARISON_MODE to generator, aac, or idle."
            } else if requestedID != nil && parsedID == nil {
                state = .failed
                errorText = "LOWLIGHT_COMPARISON_TRIAL_ID must be a UUID."
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let start = directory.appending(path: "start.json")
                if FileManager.default.fileExists(atPath: start.path) {
                    try FileManager.default.removeItem(at: start)
                }
                guard let executable = Bundle.main.executableURL else {
                    throw ComparisonFailure("Profile executable unavailable.")
                }
                appSHA256 = try ComparisonFixture.sha256(of: executable)
                try writeSnapshot(reason: "launch")
            } catch {
                fail(error)
            }
        }

        func start() {
            guard state == .ready || state == .paused else { return }
            commandID += 1
            state = .preparing
            do {
                switch mode {
                case .generator:
                    if generator == nil {
                        observeOutputChanges()
                        let bank = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appending(
                            path: "SoundBank")
                        generator = try SessionPlayback(
                            bankURL: bank, seed: ComparisonFixture.seed,
                            controls: Controls.preset(.focus), restart: nil)
                        observeGenerator()
                    }
                    generator?.play()
                case .aac:
                    if let player {
                        try playAAC(player)
                    } else {
                        let directory = directory
                        let check = Task.detached(priority: .userInitiated) {
                            try ComparisonFixture.load(from: directory)
                        }
                        validation = check
                        Task {
                            do {
                                let result = try await check.value
                                guard state == .preparing else { return }
                                validation = nil
                                let audio = try AVAudioPlayer(
                                    contentsOf: directory.appending(path: "reference.m4a"))
                                guard
                                    abs(
                                        audio.duration * Double(ComparisonFixture.sampleRate)
                                            - Double(result.frames)) <= 1024
                                else {
                                    throw ComparisonFailure(
                                        "Player duration does not match manifest.json.")
                                }
                                fixture = result
                                player = audio
                                audio.delegate = self
                                observeOutputChanges()
                                try playAAC(audio)
                            } catch {
                                if state == .preparing { fail(error) }
                            }
                        }
                    }
                case .idle: record(.running, reason: "start")
                case nil: break
                }
            } catch { fail(error) }
        }

        func pause() {
            guard state == .playing || state == .running else { return }
            commandID += 1
            if let generator {
                requestedPause = true
                generator.pause()
                return
            }
            do {
                if let player {
                    guard player.isPlaying else {
                        throw ComparisonFailure("AAC output stopped before Pause.")
                    }
                    player.pause()
                    sampleAAC()
                    try deactivate()
                }
                record(.paused, reason: "pause")
            } catch { fail(error) }
        }

        func stop() {
            guard state != .failed, state != .stopped, state != .stopping else { return }
            commandID += 1
            validation?.cancel()
            validation = nil
            if let generator {
                state = .stopping
                generator.stop()
                return
            }
            if let player {
                player.pause()
                sampleAAC()
                player.stop()
            }
            do {
                try deactivate()
                record(.stopped, reason: "stop")
            } catch { fail(error) }
        }

        func refresh() async {
            guard state != .preparing, state != .stopping, state != .failed else { return }
            let command = commandID
            do {
                if let generator {
                    let sample = try await generator.readRenderedPosition()
                    guard command == commandID, state != .failed else { return }
                    frames = sample
                } else if let player, state == .playing {
                    guard player.isPlaying else {
                        throw ComparisonFailure("AAC output stopped before Refresh.")
                    }
                    sampleAAC()
                }
                record(state, reason: "refresh")
            } catch { fail(error) }
        }

        private func observeGenerator() {
            guard let generator else { return }
            let observation = withObservationTracking {
                (
                    generator.state, generator.lastError ?? generator.audioSessionError,
                    generator.isInterrupted, generator.mediaServicesAvailable
                )
            } onChange: { [weak self] in
                Task { @MainActor in self?.observeGenerator() }
            }
            guard state != .failed else { return }
            if let error = observation.1 {
                fail(error)
                return
            }
            if observation.2 || !observation.3 {
                fail(ComparisonFailure("Generator audio session interrupted."))
                return
            }
            let next: ComparisonState
            switch observation.0 {
            case .playing: next = .playing
            case .paused: next = .paused
            case .stopped: next = .stopped
            case .failed:
                fail(ComparisonFailure("Generator playback failed."))
                return
            case .idle, .preparing, .stopping: return
            }
            guard next != state, state != .stopping || next == .stopped else { return }
            frames = generator.position
            switch next {
            case .playing: record(next, reason: "start")
            case .paused:
                guard requestedPause else {
                    fail(ComparisonFailure("Generator paused during the trial."))
                    return
                }
                requestedPause = false
                record(next, reason: "pause")
            default: record(next, reason: "stop")
            }
        }

        private func playAAC(_ audio: AVAudioPlayer) throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            needsDeactivation = true
            try session.setActive(true)
            guard audio.prepareToPlay(), audio.play() else {
                throw ComparisonFailure("AAC output could not start.")
            }
            sampleAAC()
            record(.playing, reason: "start")
        }

        private func observeOutputChanges() {
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(interruption),
                name: AVAudioSession.interruptionNotification, object: nil)
            center.addObserver(
                self, selector: #selector(routeChanged),
                name: AVAudioSession.routeChangeNotification, object: nil)
            for name in [
                AVAudioSession.mediaServicesWereLostNotification,
                AVAudioSession.mediaServicesWereResetNotification,
            ] {
                center.addObserver(
                    self, selector: #selector(mediaUnavailable), name: name, object: nil)
            }
        }

        @objc private nonisolated func interruption(_ notification: Notification) {
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                type == AVAudioSession.InterruptionType.began.rawValue
            else { return }
            Task { @MainActor in self.mediaInterrupted() }
        }

        @objc private nonisolated func routeChanged(_ notification: Notification) {
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    || reason
                        == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue
            else { return }
            Task { @MainActor in self.mediaInterrupted() }
        }

        @objc private nonisolated func mediaUnavailable(_ notification: Notification) {
            Task { @MainActor in self.mediaInterrupted() }
        }

        private func mediaInterrupted() {
            guard state == .playing || state == .paused || state == .preparing else { return }
            fail(ComparisonFailure("Audio session interrupted or output route unavailable."))
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            guard state == .playing else { return }
            guard flag, let fixture else {
                fail(ComparisonFailure("AAC finished with a decoding error."))
                return
            }
            frames = fixture.frames
            do {
                try deactivate()
                record(.stopped, reason: "end")
            } catch { fail(error) }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            fail(error ?? ComparisonFailure("AAC decoding failed."))
        }

        private func sampleAAC() {
            if let player, let fixture {
                frames = min(
                    fixture.frames,
                    UInt64(max(0, player.currentTime) * Double(ComparisonFixture.sampleRate)))
            }
        }

        private func deactivate() throws {
            guard needsDeactivation else { return }
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            needsDeactivation = false
        }

        private func record(_ next: ComparisonState, reason: String) {
            state = next
            if reason == "start" { startCount += 1 }
            do { try writeSnapshot(reason: reason) } catch { fail(error) }
        }

        private func fail(_ error: any Error) {
            state = .failed
            errorText = error.localizedDescription
            validation?.cancel()
            generator?.stop()
            player?.stop()
            do { try deactivate() } catch {
                errorText = "\(errorText ?? "") \(error.localizedDescription)"
            }
            do { try writeSnapshot(reason: "failure") } catch {
                errorText = "\(errorText ?? "") \(error.localizedDescription)"
            }
        }

        private struct Snapshot: Encodable {
            let formatVersion = 1
            #if targetEnvironment(simulator)
                let platform = "simulator"
            #else
                let platform = "device"
            #endif
            let appSHA256: String?
            let bundleID: String?
            let mode: String?
            let state: String
            let startCount: Int
            let generatedFrames: UInt64
            let trialID: UUID
            let observedAt: Date
            let seed = ComparisonFixture.seed
            let preset = "Focus"
            let aacSHA256: String?
            let reason: String
            let error: String?
        }

        private func writeSnapshot(reason: String) throws {
            let value = Snapshot(
                appSHA256: appSHA256, bundleID: Bundle.main.bundleIdentifier, mode: mode?.rawValue,
                state: state.rawValue,
                startCount: startCount, generatedFrames: frames,
                trialID: trialID, observedAt: Date(), aacSHA256: fixture?.aacSha256, reason: reason,
                error: errorText)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            if reason == "start", startCount == 1 {
                try data.write(to: directory.appending(path: "start.json"), options: .atomic)
            }
            try data.write(to: directory.appending(path: "snapshot.json"), options: .atomic)
        }
    }

    struct PlaybackComparisonView: View {
        let model: PlaybackComparison
        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        readout(
                            "Mode", value: model.mode?.rawValue ?? "Invalid", id: "comparisonMode")
                        readout(
                            "Status", value: model.state.rawValue.capitalized,
                            id: "comparisonStatus")
                        readout(
                            "Frames at 32 kHz", value: String(model.frames), id: "comparisonFrames")
                        if let message = model.errorText {
                            Text(message).accessibilityIdentifier("comparisonError")
                        }
                    }
                    Section {
                        Button("Start") { model.start() }.accessibilityIdentifier("comparisonStart")
                            .disabled(model.state != .ready && model.state != .paused)
                        Button("Pause") { model.pause() }.accessibilityIdentifier("comparisonPause")
                            .disabled(model.state != .playing && model.state != .running)
                        Button("Stop") { model.stop() }.accessibilityIdentifier("comparisonStop")
                            .disabled([.stopping, .stopped, .failed].contains(model.state))
                        Button("Refresh") { Task { await model.refresh() } }
                            .accessibilityIdentifier("comparisonRefresh")
                            .disabled([.preparing, .stopping, .failed].contains(model.state))
                    }
                }
                .navigationTitle("Playback comparison")
            }
        }

        private func readout(_ title: LocalizedStringKey, value: String, id: String) -> some View {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().accessibilityIdentifier(id)
            }
            .accessibilityElement(children: .contain)
        }
    }
#endif
