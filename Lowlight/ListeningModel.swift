// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import Observation

@MainActor @Observable
final class ListeningModel {
    private(set) var playback: SessionPlayback?
    private(set) var isLoading = true
    private(set) var loadFailed = false
    var saveFailed: Bool { saves.failed }
    var isSaving: Bool { saves.busy }
    @ObservationIgnored private let persistence: ListeningPersistence
    @ObservationIgnored private let makePlayback: (SessionRestartIntent?) -> SessionPlayback
    @ObservationIgnored private let remoteServices: () -> ListeningRemoteServices
    @ObservationIgnored private var remote: ListeningRemoteControl?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let saves: ListeningSaves
    @ObservationIgnored private var loadRevision: UInt64 = 0
    @ObservationIgnored private var previousListening: SessionListeningSnapshot?
    @ObservationIgnored private var previousState: SessionPlaybackState?
    @ObservationIgnored private var captureRequested = false
    @ObservationIgnored private var active = true

    init(
        persistence: ListeningPersistence = .disk(),
        remoteServices: @escaping () -> ListeningRemoteServices = { .system() },
        makePlayback: @escaping (SessionRestartIntent?) -> SessionPlayback = { restart in
            let bank = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("SoundBank", isDirectory: true)
            return SessionPlayback(bankURL: bank, restart: restart)
        }
    ) {
        self.persistence = persistence
        saves = ListeningSaves(write: persistence.save)
        self.makePlayback = makePlayback
        self.remoteServices = remoteServices
    }

    deinit {
        loadTask?.cancel()
    }

    func load() {
        guard playback == nil, loadTask == nil else { return }
        isLoading = true
        loadFailed = false
        loadRevision &+= 1
        let revision = loadRevision
        loadTask = Task { [weak self, persistence] in
            do {
                let saved = try await persistence.load()
                guard let self, !Task.isCancelled, revision == self.loadRevision else { return }
                self.loadTask = nil
                self.saves.restored(saved)
                self.install(saved)
            } catch {
                guard let self, !Task.isCancelled, revision == self.loadRevision else { return }
                self.loadTask = nil
                self.isLoading = false
                self.loadFailed = true
            }
        }
    }

    /// Explicitly abandons an unreadable checkpoint; it is overwritten only after a new
    /// valid musical selection is captured. This action still does not start playback.
    func startFresh() {
        guard playback == nil else { return }
        loadRevision &+= 1
        loadTask?.cancel()
        loadTask = nil
        saves.restored(nil)
        install(nil)
    }

    private func install(_ restart: SessionRestartIntent?) {
        let playback = makePlayback(restart)
        self.playback = playback
        isLoading = false
        loadFailed = false
        let input = playback.commandInput
        remote = ListeningRemoteControl(
            snapshot: remoteSnapshot, services: remoteServices(),
            send: { action in
                let command: SessionPlaybackCommand
                switch action {
                case .play: command = .play
                case .pause: command = .pause
                case .toggle: command = .toggle
                case .next: command = .next
                }
                return input.send(command) ? .accepted : .unavailable
            })
        observePlayback()
    }

    func togglePlayback() {
        _ = remote?.submit(playback?.state == .failed ? .play : .toggle)
    }
    func next() { _ = remote?.submit(.next) }
    func retryPreparation() { playback?.retryPreparation() }
    func retryCleanup() { playback?.pause() }

    func sceneActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value { playback?.refresh() } else { capture() }
        remote?.update(remoteSnapshot)
    }

    private func capture() {
        captureRequested = true
        playback?.requestCapture()
        if let restart = playback?.listeningSnapshot?.restart { saves.submit(restart) }
    }

    private func observePlayback() {
        guard let playback else { return }
        withObservationTracking {
            _ = playback.state
            _ = playback.requestedPlayback
            _ = playback.isInterrupted
            _ = playback.mediaServicesAvailable
            _ = playback.lastError
            _ = playback.audioSessionError
            _ = playback.sourceStatus
            _ = playback.preparationStatus
            _ = playback.listeningSnapshot
        } onChange: { [weak self] in
            // Observation is one-shot; property bursts share this single rearm/delivery.
            Task { @MainActor [weak self] in
                self?.playbackChanged()
                self?.observePlayback()
            }
        }
    }

    private func playbackChanged() {
        guard let playback else { return }
        let listening = playback.listeningSnapshot
        if let listening, listening != previousListening {
            if listening.selectionID != previousListening?.selectionID || captureRequested {
                saves.submit(listening.restart)
                captureRequested = false
            }
            previousListening = listening
        }
        if playback.state != previousState {
            previousState = playback.state
            if playback.state == .paused || playback.state == .stopped || playback.state == .failed
            {
                capture()
            }
        }
        remote?.update(remoteSnapshot)
    }

    func retrySave() { saves.retry() }

    var requestedPlayback: Bool { playback?.requestedPlayback == true }
    var primaryActionIsPause: Bool { requestedPlayback && playback?.state != .failed }
    var nextPending: Bool {
        guard playback?.preparationStatus != .stopped,
            let state = playback?.listeningSnapshot?.nextState
        else { return false }
        return state != .none
    }
    var canPlay: Bool {
        playback != nil && playback?.mediaServicesAvailable == true
            && playback?.state != .stopped && playback?.state != .stopping
    }
    var canRequestNext: Bool {
        canPlay && (playback?.state == .playing || playback?.state == .paused)
            && playback?.preparationStatus != .stopped
            && playback?.listeningSnapshot != nil && !nextPending
    }

    var statusText: String {
        if isLoading { return "Restoring your session…" }
        if loadFailed { return "This session couldn’t be restored." }
        guard let playback else { return "Ready when you are" }
        if !playback.mediaServicesAvailable { return "Audio is temporarily unavailable." }
        if playback.isInterrupted { return "Playback interrupted" }
        if playback.state == .preparing { return "Preparing your music…" }
        if playback.state == .failed {
            return "Playback couldn’t continue. Press Play to try again."
        }
        if playback.preparationStatus == .waitingForRetry { return "The next song needs a retry." }
        if playback.state == .playing, playback.sourceStatus == .waitingForPreparation {
            return "Preparing the next song…"
        }
        if nextPending { return "Next song queued" }
        switch playback.state {
        case .playing: return "A little room to unwind"
        case .paused: return "Paused — continue when you’re ready"
        case .stopping, .stopped: return "Playback stopped"
        default: return saves.lastSaved == nil ? "Ready when you are" : "Ready to continue"
        }
    }

    private var remoteSnapshot: ListeningRemoteSnapshot {
        let state: ListeningRemoteSnapshot.State
        if !canPlay {
            state = .unavailable
        } else if playback?.isInterrupted == true {
            state = .interrupted
        } else if playback?.state == .playing, playback?.sourceStatus == .waitingForPreparation {
            state = .waiting
        } else {
            switch playback?.state {
            case .playing: state = .playing
            case .preparing: state = .preparing
            case .paused: state = .paused
            case .failed: state = .failed
            case .stopped, .stopping: state = .ended
            default: state = .ready
            }
        }
        return ListeningRemoteSnapshot(
            state: state, requestedPlayback: requestedPlayback, canPlay: canPlay,
            canPause: requestedPlayback, canRequestNext: canRequestNext,
            subtitle: "Original lo-fi, offline")
    }
}
