// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import LowlightPlanning
import Observation

@MainActor @Observable
final class ListeningModel {
    private(set) var playback: SessionPlayback?
    private(set) var isLoading = true
    private(set) var loadFailed = false
    private(set) var controls = Controls()
    private(set) var committedControls = Controls()
    private(set) var controlCommitFailed = false
    private(set) var isStartingNewSession = false
    var saveFailed: Bool { saves.failed }
    var isSaving: Bool { saves.busy }
    @ObservationIgnored private let presets = Result {
        try Preset.allCases.map { ($0, try Controls.preset($0)) }
    }
    @ObservationIgnored private let persistence: ListeningPersistence
    @ObservationIgnored private let makeSeed: () -> UInt64
    @ObservationIgnored private let makePlayback:
        (Controls, SessionRestartIntent?, UInt64) -> SessionPlayback
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
        makeSeed: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) },
        makePlayback: @escaping (Controls, SessionRestartIntent?, UInt64) -> SessionPlayback = {
            controls, restart, seed in
            let bank = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("SoundBank", isDirectory: true)
            return SessionPlayback(
                bankURL: bank, seed: seed, controls: controls, edition: .evolving, restart: restart)
        }
    ) {
        self.persistence = persistence
        saves = ListeningSaves(write: persistence.save)
        self.makeSeed = makeSeed
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
    /// valid selection or settings edit is saved. This action still does not start playback.
    func startFresh() {
        guard playback == nil else { return }
        loadRevision &+= 1
        loadTask?.cancel()
        loadTask = nil
        saves.restored(nil)
        install(nil)
    }

    /// This explicit recovery discards the old place. Installation waits for confirmed
    /// terminal cleanup so two app owners can never compete for the system audio session.
    func startNewSession() {
        guard canStartNewSession, let playback else { return }
        isStartingNewSession = true
        playback.cancelEffectsPreview()
        controls = committedControls
        controlCommitFailed = false
        captureRequested = false
        remote?.invalidate()
        remote = nil
        saves.discardRestart(seed: makeSeed())
        playback.stop()
    }

    private func install(_ record: ListeningRecord?) {
        let settings = record?.controls ?? Controls()
        controls = settings
        committedControls = settings
        // Existing checkpoints reconstruct their own random stream. A settings-only record
        // carries its unplayed seed across launches. A genuinely new owner draws once.
        let seed = record?.sessionSeed ?? (record?.restart == nil ? makeSeed() : 0)
        if record?.restart == nil { saves.bindSessionSeed(seed) }
        let playback = makePlayback(settings, record?.restart, seed)
        self.playback = playback
        previousListening = nil
        previousState = nil
        captureRequested = false
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
        commitControls()
        _ = remote?.submit(playback?.state == .failed ? .play : .toggle)
    }
    func next() { _ = remote?.submit(.next) }
    func retryPreparation() { playback?.retryPreparation() }
    func retryCleanup() {
        if isStartingNewSession { playback?.stop() } else { playback?.pause() }
    }

    func sceneActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            playback?.refresh()
        } else {
            commitControls()
            capture()
        }
        remote?.update(remoteSnapshot)
    }

    private func capture() {
        guard !isStartingNewSession else { return }
        captureRequested = true
        playback?.requestCapture()
        if let restart = playback?.listeningSnapshot?.restart { saves.capture(restart) }
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
            _ = playback.desiredControls
            _ = playback.appliedControls
            _ = playback.controlChangeState
        } onChange: { [weak self, weak playback] in
            // Observation is one-shot; property bursts share this single rearm/delivery.
            Task { @MainActor [weak self, weak playback] in
                guard let self, let playback, self.playback === playback else { return }
                self.playbackChanged()
                if self.playback === playback { self.observePlayback() }
            }
        }
    }

    private func playbackChanged() {
        guard let playback else { return }
        if isStartingNewSession {
            guard playback.state == .stopped, playback.audioSessionError == nil else { return }
            isStartingNewSession = false
            install(saves.latest)
            return
        }
        let listening = playback.listeningSnapshot
        if let listening, listening != previousListening {
            if listening.selectionID != previousListening?.selectionID || captureRequested {
                saves.capture(listening.restart)
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

    /// Only tone changes audition during a drag. The gesture's final complete settings
    /// reach musical preparation and persistence together.
    func previewControls(_ value: Controls) {
        guard canEditControls, let playback, let normalized = try? value.normalized() else {
            return
        }
        let oldEffects = SessionEffects(controls)
        controls = normalized
        let effects = SessionEffects(normalized)
        if effects != oldEffects {
            do {
                try playback.previewEffects(effects)
            } catch {
                controlCommitFailed = true
                return
            }
        }
        if normalized == committedControls { controlCommitFailed = false }
    }

    func commitControls() {
        guard canEditControls, let playback else { return }
        guard controls != committedControls else {
            playback.cancelEffectsPreview()
            controlCommitFailed = false
            return
        }
        do {
            let normalized = try controls.normalized()
            try playback.setControls(normalized)
            try saves.updateControls(normalized)
            committedControls = normalized
            controls = normalized
            controlCommitFailed = false
        } catch {
            controlCommitFailed = true
        }
    }

    func selectPreset(_ preset: Preset) {
        guard canEditControls else { return }
        do {
            guard let selected = try presets.get().first(where: { $0.0 == preset }) else {
                throw PlanningError.invalidCatalog
            }
            controls = selected.1
            if controls == committedControls { controlCommitFailed = false }
            commitControls()
        } catch {
            controlCommitFailed = true
        }
    }

    var presetName: String {
        (try? presets.get().first { $0.1 == controls }?.0.rawValue) ?? "Custom"
    }

    var canEditControls: Bool {
        guard let playback else { return false }
        return !isStartingNewSession && playback.state != .stopping && playback.state != .stopped
    }

    var canStartNewSession: Bool {
        !isStartingNewSession
            && (playback?.state == .failed || playback?.lastError != nil
                || playback?.preparationStatus == .waitingForRetry)
    }

    var controlsFailed: Bool {
        controlCommitFailed || playback?.controlChangeState == .failed
    }

    var controlsPending: Bool {
        playback?.controlChangeState == .queued || playback?.controlChangeState == .transitioning
    }

    func retryControls() {
        if controlCommitFailed { commitControls() } else { playback?.retryControls() }
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
        !isStartingNewSession && playback != nil && playback?.mediaServicesAvailable == true
            && playback?.state != .stopped && playback?.state != .stopping
    }
    var canRequestNext: Bool {
        canPlay && (playback?.state == .playing || playback?.state == .paused)
            && playback?.preparationStatus != .stopped
            && playback?.listeningSnapshot != nil && !nextPending
    }

    var statusText: String {
        if isStartingNewSession { return "Starting a new session…" }
        if isLoading { return "Restoring your session…" }
        if loadFailed { return "This session couldn’t be restored." }
        guard let playback else { return "Ready to play" }
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
        if controlsFailed { return "Changes couldn’t be prepared. You can keep listening." }
        if controlsPending {
            return playback.controlChangeState == .transitioning
                ? "Changing with the music." : "Changes queued for an upcoming phrase."
        }
        if nextPending { return "Next song queued" }
        switch playback.state {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopping, .stopped: return "Playback stopped"
        default: return saves.latest.restart == nil ? "Ready to play" : "Ready to continue"
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
