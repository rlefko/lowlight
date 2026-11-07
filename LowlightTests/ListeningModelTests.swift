// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import LowlightPlanning
import Testing

@testable import Lowlight
@testable import LowlightAudio

@MainActor
struct ListeningModelTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForLoad(_ loader: ModelLoadGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while await !loader.isWaiting {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func intent() throws -> SessionRestartIntent {
        let planning = try SessionPlanning()
        _ = try planning.next()
        return try SessionRestartIntent(checkpoint: planning.checkpoint(), canonicalFrame: 1234)
    }

    @Test func loadingIsSilentAndBackgroundingPreservesExplicitPlayback() async throws {
        let saved = try intent()
        let probe = ListeningModelProbe()
        let remote = ModelRemoteServices()
        var restorations: [SessionRestartIntent?] = []
        let model = ListeningModel(
            persistence: ListeningPersistence(
                load: { try ListeningRecord(controls: saved.currentSong.controls, restart: saved) },
                save: { _ in }),
            remoteServices: { remote.value },
            makePlayback: { controls, restart, _ in
                restorations.append(restart)
                return SessionPlayback(controls: controls, factory: { try probe.makeEngine($0) })
            })
        model.load()
        model.load()
        try await wait { !model.isLoading }
        let playback = try #require(model.playback)
        #expect(restorations == [saved])
        #expect(playback.state == .idle && !model.requestedPlayback && !model.nextPending)
        #expect(model.canPlay && !model.canRequestNext && probe.constructions == 0)
        #expect(remote.handlers.count == 4)
        model.sceneActive(false)
        #expect(try await playback.inspect { $0 == nil })
        #expect(probe.constructions == 0)
        model.sceneActive(true)
        let play = try #require(remote.handlers[.play])
        #expect(await Task.detached { play() }.value == .accepted)
        try await wait { playback.state == .playing }
        #expect(model.requestedPlayback && probe.constructions == 1)
        let samples = try await playback.inspect { try probe.pull($0) }
        #expect(samples.contains { $0 != 0 } && samples.allSatisfy(\.isFinite))
        model.sceneActive(false)
        #expect(try await playback.inspect { $0?.state == .playing && $0?.position == 2048 })
        model.sceneActive(true)
        model.togglePlayback()
        try await wait { playback.state == .paused && !model.requestedPlayback }
        model.togglePlayback()
        model.togglePlayback()
        #expect(try await playback.inspect { $0?.state == .paused && $0?.position == 2048 })
        try await wait { playback.state == .paused && !model.requestedPlayback }
        #expect(probe.constructions == 1)
        playback.stop()
        try await wait { playback.state == .stopped }
        #expect(try await playback.inspect { $0 == nil })
    }

    @Test func failedStartupRetriesOnOnePlayTap() async throws {
        let probe = ListeningModelProbe(failFirst: true)
        let remote = ModelRemoteServices()
        var seedDraws = 0
        var installedSeeds: [UInt64] = []
        let model = ListeningModel(
            persistence: ListeningPersistence(load: { nil }, save: { _ in }),
            remoteServices: { remote.value },
            makeSeed: {
                seedDraws += 1
                return 123
            },
            makePlayback: { controls, _, seed in
                installedSeeds.append(seed)
                return SessionPlayback(controls: controls, factory: { try probe.makeEngine($0) })
            })
        model.load()
        try await wait { !model.isLoading }
        let playback = try #require(model.playback)
        model.togglePlayback()
        try await wait { playback.state == .failed }
        #expect(model.requestedPlayback && !model.primaryActionIsPause && model.canPlay)
        #expect(probe.constructions == 1)
        model.togglePlayback()
        try await wait { playback.state == .playing }
        #expect(model.primaryActionIsPause && probe.constructions == 2)
        #expect(seedDraws == 1 && installedSeeds == [123])
        playback.stop()
        try await wait { playback.state == .stopped }
    }

    @Test func restoreFailureOffersRetryAndFreshStartNeverAutoplays() async throws {
        let loader = ModelLoadGate()
        let remote = ModelRemoteServices()
        var installed: [SessionRestartIntent?] = []
        let model = ListeningModel(
            persistence: ListeningPersistence(load: { try await loader.load() }, save: { _ in }),
            remoteServices: { remote.value },
            makePlayback: { controls, restart, _ in
                installed.append(restart)
                return SessionPlayback(
                    controls: controls, factory: { _ in throw ModelLoadError.failed })
            })
        model.load()
        try await waitForLoad(loader)
        await loader.finish(.failure(ModelLoadError.failed))
        try await wait { model.loadFailed }
        #expect(model.playback == nil && !model.canPlay && remote.handlers.isEmpty)
        model.load()
        try await waitForLoad(loader)
        model.startFresh()
        let fresh = try #require(model.playback)
        #expect(fresh.state == .idle && !model.loadFailed && !model.isLoading)
        // The earlier load deliberately ignores task cancellation. Its generation cannot
        // replace the user's newer fresh-session choice when it eventually completes.
        await loader.finish(
            .success(try ListeningRecord(controls: .preset(.focus), restart: intent())))
        await Task.yield()
        #expect(model.playback === fresh && installed == [nil])
        #expect(!model.requestedPlayback)
        fresh.stop()
        try await wait { fresh.state == .stopped }
    }
}

private enum ModelLoadError: Error { case failed }

private actor ModelLoadGate {
    private var continuation: CheckedContinuation<ListeningRecord?, any Error>?
    var isWaiting: Bool { continuation != nil }
    func load() async throws -> ListeningRecord? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<ListeningRecord?, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class ModelRemoteServices {
    var handlers: [ListeningRemoteAction: @Sendable () -> ListeningRemoteResult] = [:]
    var value: ListeningRemoteServices {
        ListeningRemoteServices(
            register: { [self] action, handler in
                handlers[action] = handler
                return { [self] in handlers.removeValue(forKey: action) }
            }, update: { _ in })
    }
}

/// Only the construction counter crosses threads. Engine creation/rendering belongs to
/// the real playback control executor, using the production source and native DSP.
private final class ListeningModelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failFirst: Bool
    private weak var engine: AVAudioEngine?
    var constructions: Int { lock.withLock { count } }

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func makeEngine(_ token: PreparationCancellation) throws -> SessionAudioEngine {
        let attempt = lock.withLock {
            count += 1
            return count
        }
        if failFirst && attempt == 1 { throw ModelLoadError.failed }
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
                frameCount: 20_000, preparation: .concurrent, cancellation: cancellation,
                accepted: { index += 1 },
                prepare: { pool, cancellation in
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

    func pull(_ owner: SessionAudioEngine?) throws -> [Float] {
        _ = try #require(owner)
        let engine = try #require(engine)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        try #require(engine.renderOffline(2048, to: buffer) == .success)
        let channels = try #require(buffer.floatChannelData)
        return (0..<2048).flatMap { [channels[0][$0], channels[1][$0]] }
    }
}
