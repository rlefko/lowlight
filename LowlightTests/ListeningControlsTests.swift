// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

@testable import Lowlight
@testable import LowlightAudio

@MainActor
struct ListeningControlsTests {
    private func wait(
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func model(
        store: ControlsSaveStore, saved: ListeningRecord? = nil,
        makeSeed: @escaping () -> UInt64 = { 111 }
    ) -> ListeningModel {
        ListeningModel(
            persistence: ListeningPersistence(load: { saved }, save: { try await store.write($0) }),
            remoteServices: {
                ListeningRemoteServices(register: { _, _ in {} }, update: { _ in })
            },
            makeSeed: makeSeed,
            makePlayback: { controls, _, _ in
                SessionPlayback(controls: controls) { _ in
                    Issue.record("Editing settings must not construct an audio engine")
                    throw ControlsSaveError.unexpectedStartup
                }
            })
    }

    @Test func previewsDoNotPrepareOrSaveAndOneCommitSubmitsTheCompleteSnapshot() async throws {
        let store = ControlsSaveStore()
        let model = model(store: store)
        model.load()
        try await wait { !model.isLoading }
        let playback = try #require(model.playback)
        let initial = model.committedControls
        for index in 0..<20 {
            var preview = model.controls
            preview.energy = Double(index) / 20
            preview.variation = 0.8
            model.previewControls(preview)
        }
        #expect(model.controls.energy == 0.95 && model.controls.variation == 0.8)
        #expect(model.committedControls == initial && playback.desiredControls == initial)
        #expect(await store.attempts.isEmpty)
        #expect(playback.state == .idle && !model.requestedPlayback)
        #expect(try await playback.inspect { $0 == nil })
        var invalid = model.controls
        invalid.energy = .nan
        model.previewControls(invalid)
        #expect(model.controls.energy == 0.95)
        model.commitControls()
        try await wait { await store.attempts.count == 1 && !model.isSaving }
        #expect(model.committedControls == model.controls)
        #expect(playback.desiredControls == model.controls)
        #expect(await store.attempts[0].controls == model.controls)
        #expect(await store.attempts[0].restart == nil)
        #expect(await store.attempts[0].sessionSeed == 111)
        model.commitControls()
        #expect(!model.isSaving && !model.requestedPlayback)
        #expect(await store.attempts.count == 1)
        playback.stop()
        try await wait { playback.state == .stopped }
    }

    @Test func effectDraggingAuditionsWithoutSavingAndCommitKeepsTheLastRamp() async throws {
        let store = ControlsSaveStore()
        let model = model(store: store)
        model.load()
        try await wait { !model.isLoading }
        let owner = try #require(model.playback)
        let initial = model.committedControls
        var preview = initial
        preview.warmth = 0.1
        preview.space = 0.85
        preview.texture = 0.3
        model.previewControls(preview)
        #expect(owner.effectsSnapshot.requested == SessionEffects(preview))
        #expect(model.presetName == "Custom" && !model.controlsPending)
        #expect(owner.desiredControls == initial && model.committedControls == initial)
        #expect(await store.attempts.isEmpty)

        // Choosing the saved preset during a drag cancels its audition without a write.
        model.selectPreset(.focus)
        #expect(owner.effectsSnapshot.requested == SessionEffects(initial))
        #expect(await store.attempts.isEmpty)
        model.previewControls(preview)
        let lastPreview = owner.effectsSnapshot.revision
        model.commitControls()
        try await wait { await store.attempts.count == 1 && !model.isSaving }
        #expect(owner.effectsSnapshot.revision == lastPreview)
        #expect(await store.attempts[0].controls == preview)
        #expect(owner.state == .idle && !model.requestedPlayback)
        owner.stop()
        try await wait { owner.state == .stopped }
    }

    @Test func presetsSubmitEveryExactValueAndCustomRetainsTheOtherSettings() async throws {
        let store = ControlsSaveStore()
        let model = model(store: store)
        model.load()
        try await wait { !model.isLoading }
        let playback = try #require(model.playback)
        for preset in [Preset.relax, .workout, .reflective, .focus, .commute] {
            let expected = try Controls.preset(preset)
            model.selectPreset(preset)
            try await wait { !model.isSaving }
            #expect(model.controls == expected && model.committedControls == expected)
            #expect(playback.desiredControls == expected && model.presetName == preset.rawValue)
            #expect(model.controls.tempo == nil)
            #expect(await store.attempts.last?.controls == expected)
        }
        let preset = model.controls
        var custom = preset
        custom.mood = -0.4
        custom.tempo = 83
        model.previewControls(custom)
        #expect(model.presetName == "Custom" && model.committedControls == preset)
        model.commitControls()
        try await wait { !model.isSaving }
        #expect(model.committedControls.tempo == 83 && model.committedControls.mood == -0.4)
        #expect(model.committedControls.warmth == preset.warmth)
        #expect(model.committedControls.space == preset.space)
        #expect(model.committedControls.texture == preset.texture)
        #expect(!model.requestedPlayback)
        playback.stop()
        try await wait { playback.state == .stopped }
    }

    @Test func settingsOnlyRestoreAndBackgroundCommitStaySilent() async throws {
        let store = ControlsSaveStore()
        let saved = try ListeningRecord(controls: .preset(.relax), sessionSeed: 191)
        let model = model(store: store, saved: saved) {
            Issue.record("A saved seed must survive a silent launch")
            return 0
        }
        model.load()
        try await wait { !model.isLoading }
        let playback = try #require(model.playback)
        #expect(model.controls == saved.controls && model.committedControls == saved.controls)
        #expect(playback.desiredControls == saved.controls && model.presetName == "Relax")
        #expect(await store.attempts.isEmpty)
        var preview = model.controls
        preview.energy = 0.71
        model.previewControls(preview)
        model.sceneActive(false)
        try await wait { await store.attempts.count == 1 && !model.isSaving }
        #expect(await store.attempts[0].controls == preview)
        #expect(await store.attempts[0].restart == nil)
        #expect(await store.attempts[0].sessionSeed == 191)
        #expect(playback.state == .idle && !model.requestedPlayback)
        model.sceneActive(true)
        #expect(try await playback.inspect { $0 == nil })
        playback.stop()
        try await wait { playback.state == .stopped }
    }

    @Test func failedSaveRetriesTheNewestCommittedSettingsWithoutStartingPlayback() async throws {
        let store = ControlsSaveStore(failFirst: true)
        let model = model(store: store)
        model.load()
        try await wait { !model.isLoading }
        let playback = try #require(model.playback)
        model.selectPreset(.relax)
        try await wait { model.saveFailed && !model.isSaving }
        model.selectPreset(.workout)
        #expect(await store.attempts.count == 1)
        #expect(model.committedControls == (try Controls.preset(.workout)))
        model.retrySave()
        try await wait { !model.isSaving && !model.saveFailed }
        #expect(await store.attempts.count == 2)
        #expect(await store.attempts.last?.controls == (try Controls.preset(.workout)))
        #expect(!model.requestedPlayback && playback.state == .idle)
        playback.stop()
        try await wait { playback.state == .stopped }
    }

    @Test func newSessionWaitsForSuccessfulStopAndCannotResaveTheOldPlace() async throws {
        let planning = try SessionPlanning()
        _ = try planning.next()
        let restart = try SessionRestartIntent(
            checkpoint: planning.checkpoint(), canonicalFrame: 1234)
        let saved = try ListeningRecord(
            controls: .preset(.focus), restart: restart, sessionSeed: 111)
        let store = ControlsSaveStore()
        let remote = RecoveryRemoteServices()
        let probe = RecoveryPlaybackProbe()
        defer { probe.releaseStop() }
        var owners: [SessionPlayback] = []
        var installed: [ListeningRecord] = []
        let model = ListeningModel(
            persistence: ListeningPersistence(load: { saved }, save: { try await store.write($0) }),
            remoteServices: { remote.value },
            makeSeed: { 222 },
            makePlayback: { controls, restart, seed in
                if let previous = owners.last {
                    #expect(previous.state == .stopped && previous.audioSessionError == nil)
                    #expect(remote.handlers.isEmpty)
                }
                if let record = try? ListeningRecord(
                    controls: controls, restart: restart, sessionSeed: seed)
                {
                    installed.append(record)
                }
                let playback = SessionPlayback(
                    audioSession: probe.policy, controls: controls, restart: restart,
                    factory: { token, prepareOutput, latest, requested in
                        try probe.makeEngine(
                            token, prepareOutput: prepareOutput, controls: requested,
                            restart: latest)
                    })
                owners.append(playback)
                return playback
            })
        model.load()
        try await wait { !model.isLoading }
        let old = try #require(model.playback)
        let latePlay = try #require(remote.handlers[.play])
        model.togglePlayback()
        // Full-song analysis runs on the control executor before the injected start error.
        // Its duration is not a UI-delivery deadline; first await that work's barrier.
        #expect(try await old.inspect { $0 == nil })
        try await wait { old.state == .failed }
        let oldRestart = try #require(old.listeningSnapshot?.restart)
        #expect(old.audioSessionError != nil && model.canStartNewSession)
        model.selectPreset(.workout)
        try await wait { !model.isSaving }
        let settings = model.committedControls
        var preview = settings
        preview.energy = 0.1
        model.previewControls(preview)
        model.startNewSession()
        try await wait { probe.stopBlocked && !model.isSaving }
        #expect(model.isStartingNewSession && model.playback === old && owners.count == 1)
        #expect(!model.canPlay && !model.canEditControls && remote.handlers.isEmpty)
        #expect(latePlay() == .unavailable)
        #expect(await store.attempts.last?.controls == settings)
        #expect(await store.attempts.last?.restart == nil)
        model.sceneActive(false)
        probe.releaseStop()
        try await wait { old.state == .stopped && old.audioSessionError != nil }
        #expect(model.isStartingNewSession && owners.count == 1)
        model.retryCleanup()
        try await wait { !model.isStartingNewSession && model.playback !== old }
        let fresh = try #require(model.playback)
        #expect(installed.count == 2 && installed[1].restart == nil)
        #expect(installed.map(\.sessionSeed) == [111, 222])
        #expect(await store.attempts.last?.sessionSeed == 222)
        #expect(installed[1].controls == settings && model.controls == settings)
        #expect(fresh.state == .idle && !model.requestedPlayback && probe.constructions == 1)
        #expect(remote.handlers.count == 4 && latePlay() == .unavailable)
        #expect(old.listeningSnapshot?.restart == oldRestart)
        old.requestCapture()
        old.refresh()
        #expect(try await old.inspect { $0 == nil })
        await Task.yield()
        model.sceneActive(true)
        model.sceneActive(false)
        try await wait { !model.isSaving }
        #expect(await store.attempts.last?.restart == nil)
        #expect(await store.attempts.last?.controls == settings)
        fresh.stop()
        try await wait { fresh.state == .stopped }
    }

    @Test func pausedPreparationFailureCanStartANewSilentSession() async throws {
        let store = ControlsSaveStore()
        let probe = PausedFailureProbe()
        var owners: [SessionPlayback] = []
        let model = ListeningModel(
            persistence: ListeningPersistence(load: { nil }, save: { try await store.write($0) }),
            remoteServices: { ListeningRemoteServices(register: { _, _ in {} }, update: { _ in }) },
            makePlayback: { controls, restart, _ in
                #expect(restart == nil)
                if let previous = owners.last { #expect(previous.state == .stopped) }
                let playback = SessionPlayback(controls: controls) { try probe.makeEngine($0) }
                owners.append(playback)
                return playback
            })
        model.load()
        try await wait { !model.isLoading }
        model.selectPreset(.workout)
        let settings = model.committedControls
        let old = try #require(model.playback)
        model.togglePlayback()
        try await wait { old.state == .playing }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while old.preparationStatus != .waitingForRetry {
            try #require(ContinuousClock.now < deadline)
            try await old.inspect { try probe.pull($0) }
            old.refresh()
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(old.lastError != nil && model.canStartNewSession)
        model.togglePlayback()
        try await wait { old.state == .paused && old.preparationStatus == .suspended }
        #expect(old.lastError != nil && model.canStartNewSession)
        model.startNewSession()
        try await wait { model.playback !== old && !model.isStartingNewSession && !model.isSaving }
        let fresh = try #require(model.playback)
        #expect(owners.count == 2 && probe.constructions == 1)
        #expect(fresh.state == .idle && !model.requestedPlayback && model.controls == settings)
        #expect(await store.attempts.last?.controls == settings)
        #expect(await store.attempts.last?.restart == nil)
        fresh.stop()
        try await wait { fresh.state == .stopped }
    }
}

private enum ControlsSaveError: Error { case failed, unexpectedStartup }

private actor ControlsSaveStore {
    let failFirst: Bool
    private(set) var attempts: [ListeningRecord] = []

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func write(_ record: ListeningRecord) throws {
        attempts.append(record)
        if failFirst && attempts.count == 1 { throw ControlsSaveError.failed }
    }
}

@MainActor
private final class RecoveryRemoteServices {
    var handlers: [ListeningRemoteAction: @Sendable () -> ListeningRemoteResult] = [:]
    var value: ListeningRemoteServices {
        ListeningRemoteServices(
            register: { [self] action, handler in
                handlers[action] = handler
                return { [self] in handlers.removeValue(forKey: action) }
            }, update: { _ in })
    }
}

private final class RecoveryPlaybackProbe: @unchecked Sendable {
    enum Failure: Error { case start, deactivate }
    private let condition = NSCondition()
    private var count = 0
    private var deactivations = 0
    private var blocked = false
    private var released = false

    var constructions: Int { condition.withLock { count } }
    var stopBlocked: Bool { condition.withLock { blocked } }

    var policy: PlaybackAudioSession {
        PlaybackAudioSession(
            configure: {}, activate: {},
            deactivate: {
                self.condition.lock()
                defer { self.condition.unlock() }
                self.deactivations += 1
                if self.deactivations == 2 {
                    self.blocked = true
                    while !self.released { self.condition.wait() }
                }
                if self.deactivations <= 2 { throw Failure.deactivate }
            })
    }

    func releaseStop() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func makeEngine(
        _ token: PreparationCancellation, prepareOutput: () throws -> Void,
        controls: Controls, restart: SessionRestartIntent?
    ) throws -> SessionAudioEngine {
        condition.withLock { count += 1 }
        let bank = try #require(Bundle.main.resourceURL).appendingPathComponent("SoundBank")
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let worker = try SessionPreparationWorker(
            controls: controls, restart: restart, preparer: preparer, cancellation: token)
        do {
            try prepareOutput()
            let engine = AVAudioEngine()
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
            return try SessionAudioEngine(
                worker: worker, engine: engine, start: { _ in throw Failure.start })
        } catch {
            worker.requestStop()
            worker.join()
            throw error
        }
    }
}

/// Real short native racks make an ordinary successor failure deterministic without
/// rendering full songs. Only the count crosses threads; graph work stays on inspect/factory.
private final class PausedFailureProbe: @unchecked Sendable {
    enum Failure: Error { case successor }
    private let lock = NSLock()
    private var count = 0
    private weak var engine: AVAudioEngine?
    var constructions: Int { lock.withLock { count } }

    func makeEngine(_ token: PreparationCancellation) throws -> SessionAudioEngine {
        lock.withLock { count += 1 }
        let bank = try #require(Bundle.main.resourceURL).appendingPathComponent("SoundBank")
        let preparer = try TonalSamplePreparer(bankURL: bank)
        let events = Data(
            """
            [{"instrument":"guitar","note":60,"beat":0,"time":0,"local_time":0,
              "duration":0.4,"velocity":0.5,"role":"chord","pan":-0.25,
              "round_robin":0,"release":0.1,"articulation":"normal"}]
            """.utf8)
        let worker = try SessionPreparationWorker(cancellation: token) { cancellation in
            var index = 0
            return try PreparedSession(
                frameCount: 40_000, preparation: .concurrent, cancellation: cancellation,
                accepted: { index += 1 },
                prepare: { pool, cancellation in
                    guard index < 2 else { throw Failure.successor }
                    let origin: UInt64 = index == 0 ? 0 : 6400
                    let song = try pool.prepare(
                        layout: SongRenderLayout(
                            frameOrigin: origin, inputFrames: 16_000, bodyFrames: 0..<12_800),
                        preparer: preparer,
                        events: NoteEvent.importReference(events, placingAt: Int64(origin)),
                        takeSeed: 1, focus: .guitar, warmth: 0.78, energy: 0.35,
                        space: 0.44, texture: 0,
                        rackFades: SongRackFades(
                            tonalOutStartFrame: Double(origin + 12_800),
                            tonalOutEndFrame: Double(origin + 16_000),
                            rhythmOutFrame: Double(origin + 12_800)),
                        cancellation: cancellation)
                    return (song, index == 0 ? 6400 : 20_000)
                })
        }
        do {
            let engine = AVAudioEngine()
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2048)
            self.engine = engine
            return try SessionAudioEngine(worker: worker, engine: engine)
        } catch {
            worker.requestStop()
            worker.join()
            throw error
        }
    }

    func pull(_ owner: SessionAudioEngine?) throws {
        _ = try #require(owner)
        let engine = try #require(engine)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        try #require(engine.renderOffline(2048, to: buffer) == .success)
    }
}
