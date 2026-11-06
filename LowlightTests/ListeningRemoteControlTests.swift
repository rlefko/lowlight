// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MediaPlayer
import Testing

@testable import Lowlight

@Suite(.serialized)
@MainActor
struct ListeningRemoteControlTests {
    private static let ready = ListeningRemoteSnapshot(
        state: .ready, requestedPlayback: false,
        canPlay: true, canPause: false, canRequestNext: true, subtitle: "Focus")

    @Test
    func remoteAndUICommandsEnterTheSameBackendBeforeReturning() async throws {
        for remoteFirst in [true, false] {
            let recorder = RemoteCommandRecorder()
            let services = FakeRemoteServices()
            let owner = ListeningRemoteControl(
                snapshot: Self.ready, services: services.value,
                send: { recorder.send($0) })
            defer { owner.invalidate() }
            let remotePlay = try #require(services.handler(for: .play))
            if remoteFirst {
                let immediateCount = await Task.detached {
                    #expect(remotePlay() == .accepted)
                    return recorder.snapshot().count
                }.value
                #expect(immediateCount == 1)
                #expect(owner.submit(.pause) == .accepted)
            } else {
                #expect(owner.submit(.pause) == .accepted)
                #expect(recorder.snapshot().count == 1)
                let immediateCount = await Task.detached {
                    #expect(remotePlay() == .accepted)
                    return recorder.snapshot().count
                }.value
                #expect(immediateCount == 2)
            }
            let values = recorder.snapshot()
            #expect(values.map(\.action) == (remoteFirst ? [.play, .pause] : [.pause, .play]))
            #expect(values.first { $0.action == .play }?.onMainThread == false)
            #expect(values.first { $0.action == .pause }?.onMainThread == true)
            owner.update(Self.ready)  // Metadata observation never resubmits old intent.
            #expect(recorder.snapshot().count == 2)
        }
    }

    @Test
    func toggleAndNextAreSynchronousBackendCommandsWithoutAnAppQueue() async throws {
        let recorder = RemoteCommandRecorder()
        let services = FakeRemoteServices()
        let owner = ListeningRemoteControl(
            snapshot: Self.ready, services: services.value, send: { recorder.send($0) })
        defer { owner.invalidate() }
        let toggle = try #require(services.handler(for: .toggle))
        let next = try #require(services.handler(for: .next))
        let count = await Task.detached {
            for _ in 0..<100 {
                #expect(toggle() == .accepted)
                #expect(next() == .accepted)
            }
            return recorder.snapshot().count
        }.value
        #expect(count == 200)
        #expect(recorder.snapshot().allSatisfy { !$0.onMainThread })
        #expect(
            recorder.snapshot().map(\.action)
                == Array(repeating: [.toggle, .next], count: 100).flatMap { $0 })
        // The real backend, not this adapter, coalesces Next and interprets Toggle atomically.
    }

    @Test
    func backendRejectionIsReturnedWithoutMetadataPermissionOrDeferredWork() throws {
        let services = FakeRemoteServices()
        let owner = ListeningRemoteControl(
            snapshot: Self.ready, services: services.value, send: { _ in .unavailable })
        defer { owner.invalidate() }
        #expect(owner.submit(.play) == .unavailable)
        for action in ListeningRemoteAction.allCases {
            let handler = try #require(services.handler(for: action))
            #expect(handler() == .unavailable)
        }
    }

    @Test
    func adapterRemovesOnlyItsRegistrationsAndRejectsCapturedLateHandlers() throws {
        let services = FakeRemoteServices()
        let recorder = RemoteCommandRecorder()
        let external = services.addExternalRegistration()
        let owner = ListeningRemoteControl(
            snapshot: Self.ready, services: services.value, send: { recorder.send($0) })
        #expect(services.registrations.count == 5)
        let handler = try #require(services.handler(for: .next))
        #expect(handler() == .accepted)
        owner.update(Self.ready)
        #expect(services.updates.count == 1)
        owner.invalidate()
        owner.invalidate()
        #expect(services.registrations.keys.sorted() == [external])
        #expect(services.removalCalls == 4)
        #expect(services.updates.count == 2)
        #expect(services.updates.last.map { $0 == nil } == true)
        #expect(handler() == .unavailable)
        #expect(owner.submit(.play) == .unavailable)
        #expect(recorder.snapshot().map(\.action) == [.next])
        owner.update(Self.ready)
        #expect(services.updates.count == 2)
    }

    @Test
    func deinitInvalidatesImmediatelyAndRemovesOwnedTargetsOnMainActor() throws {
        let queue = ManualCleanupQueue()
        let services = FakeRemoteServices()
        var owner: ListeningRemoteControl? = ListeningRemoteControl(
            snapshot: Self.ready, services: services.value,
            cleanupSchedule: { queue.enqueue($0) }, send: { _ in .accepted })
        weak var weakOwner = owner
        let handler = try #require(services.handler(for: .play))
        owner = nil
        #expect(weakOwner == nil)
        #expect(handler() == .unavailable)
        #expect(queue.count == 1)
        queue.runOne()
        #expect(services.registrations.isEmpty)
        #expect(services.removalCalls == 4)
    }

    @Test
    func systemAdapterUpdatesSupportedCommandsAndProtectsANewerOwnerDuringCleanup() throws {
        let commands = MPRemoteCommandCenter.shared()
        let information = MPNowPlayingInfoCenter.default()
        var playing = Self.ready
        playing.state = .playing
        playing.requestedPlayback = true
        playing.canPause = true
        let first = ListeningRemoteControl(snapshot: playing, send: { _ in .accepted })
        let second = ListeningRemoteControl(snapshot: playing, send: { _ in .accepted })
        defer {
            first.invalidate()
            second.invalidate()
        }
        #expect(commands.playCommand.isEnabled && commands.pauseCommand.isEnabled)
        #expect(commands.togglePlayPauseCommand.isEnabled && commands.nextTrackCommand.isEnabled)
        #expect(!commands.previousTrackCommand.isEnabled)
        #expect(!commands.changePlaybackPositionCommand.isEnabled)
        #expect(!commands.seekForwardCommand.isEnabled && !commands.seekBackwardCommand.isEnabled)
        first.invalidate()
        #expect(commands.nextTrackCommand.isEnabled)
        #expect(information.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        var paused = playing
        paused.state = .paused
        paused.requestedPlayback = false
        paused.canPause = false
        second.update(paused)
        #expect(commands.playCommand.isEnabled && !commands.pauseCommand.isEnabled)
        #expect(information.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        second.invalidate()
        #expect(information.nowPlayingInfo == nil)
        #expect(!commands.playCommand.isEnabled && !commands.pauseCommand.isEnabled)
        #expect(!commands.togglePlayPauseCommand.isEnabled && !commands.nextTrackCommand.isEnabled)
    }

    @Test
    func metadataReusesTheBundledPosterWithoutDurationOrSeek() throws {
        #expect(ListeningRemoteMetadata.values(Self.ready) == nil)
        var value = Self.ready
        let nonPlaying: [ListeningRemoteSnapshot.State] = [
            .preparing, .paused, .waiting, .interrupted, .failed, .ended,
        ]
        var previousArtwork: MPMediaItemArtwork?
        for state in nonPlaying + [.playing] {
            value.state = state
            let metadata = try #require(ListeningRemoteMetadata.values(value))
            let artwork = try #require(metadata[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
            if let previousArtwork {
                #expect(artwork === previousArtwork)
            } else {
                #expect(artwork.bounds.size == CGSize(width: 512, height: 512))
                let size = CGSize(width: 64, height: 64)
                #expect(artwork.image(at: size)?.size == size)
                previousArtwork = artwork
            }
            #expect(metadata[MPMediaItemPropertyTitle] as? String == "Lowlight")
            #expect(metadata[MPMediaItemPropertyAlbumTitle] as? String == "Focus")
            #expect(
                metadata[MPNowPlayingInfoPropertyPlaybackRate] as? Double
                    == (state == .playing ? 1 : 0))
            #expect(
                metadata.keys.sorted()
                    == [
                        MPMediaItemPropertyTitle, MPMediaItemPropertyAlbumTitle,
                        MPMediaItemPropertyArtwork,
                        MPNowPlayingInfoPropertyMediaType, MPNowPlayingInfoPropertyPlaybackRate,
                    ].sorted())
        }
        value.state = .unavailable
        #expect(ListeningRemoteMetadata.values(value) == nil)
    }
}

private final class RemoteCommandRecorder: @unchecked Sendable {
    struct Record: Sendable {
        let action: ListeningRemoteAction
        let onMainThread: Bool
    }
    private let lock = NSLock()
    private var records: [Record] = []
    func send(_ action: ListeningRemoteAction) -> ListeningRemoteResult {
        lock.withLock { records.append(Record(action: action, onMainThread: Thread.isMainThread)) }
        return .accepted
    }
    func snapshot() -> [Record] { lock.withLock { records } }
}

private final class ManualCleanupQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { jobs.append(body) }
    }
    var count: Int { lock.withLock { jobs.count } }
    @MainActor func runOne() {
        let job = lock.withLock { jobs.removeFirst() }
        job()
    }
}

@MainActor
private final class FakeRemoteServices {
    struct Registration {
        let action: ListeningRemoteAction?
        let handler: @Sendable () -> ListeningRemoteResult
    }
    var registrations: [Int: Registration] = [:]
    var updates: [ListeningRemoteSnapshot?] = []
    var removalCalls = 0
    private var nextID = 0

    var value: ListeningRemoteServices {
        ListeningRemoteServices(
            register: { [self] action, handler in
                let id = register(action, handler: handler)
                return { [self] in
                    removalCalls += 1
                    registrations.removeValue(forKey: id)
                }
            },
            update: { [self] in updates.append($0) })
    }

    func handler(for action: ListeningRemoteAction) -> (@Sendable () -> ListeningRemoteResult)? {
        registrations.values.first { $0.action == action }?.handler
    }
    func addExternalRegistration() -> Int { register(nil, handler: { .accepted }) }
    private func register(
        _ action: ListeningRemoteAction?, handler: @escaping @Sendable () -> ListeningRemoteResult
    ) -> Int {
        nextID += 1
        registrations[nextID] = Registration(action: action, handler: handler)
        return nextID
    }
}
