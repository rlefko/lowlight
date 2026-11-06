// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MediaPlayer
import UIKit

enum ListeningRemoteAction: CaseIterable, Hashable, Sendable { case play, pause, toggle, next }
enum ListeningRemoteResult: Equatable, Sendable { case accepted, unavailable }

struct ListeningRemoteSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unavailable, ready, preparing, playing, paused, waiting, interrupted, failed, ended
    }
    var state: State
    // Latest requested intent, not a delayed engine-state observation; used by Toggle.
    var requestedPlayback: Bool
    var canPlay: Bool
    var canPause: Bool
    var canRequestNext: Bool
    var subtitle: String?

    func permits(_ action: ListeningRemoteAction) -> Bool {
        switch action {
        case .play: canPlay
        case .pause: canPause
        case .toggle: requestedPlayback ? canPause : canPlay
        case .next: canRequestNext
        }
    }
}

/// Invalidates this adapter's captured handlers without adding a command queue or intent
/// state. The injected input synchronously enters the backend's existing locked mailbox.
/// A call admitted before invalidation may complete; application code never runs under lock.
private final class ListeningRemoteInput: @unchecked Sendable {
    private let lock = NSLock()
    private let send: @Sendable (ListeningRemoteAction) -> ListeningRemoteResult
    private var valid = true

    init(send: @escaping @Sendable (ListeningRemoteAction) -> ListeningRemoteResult) {
        self.send = send
    }

    func submit(_ action: ListeningRemoteAction) -> ListeningRemoteResult {
        guard lock.withLock({ valid }) else { return .unavailable }
        return send(action)
    }

    func invalidate() { lock.withLock { valid = false } }
}

/// Narrow registration/metadata seam; it does not replace an audio implementation.
struct ListeningRemoteServices: Sendable {
    typealias Removal = @MainActor @Sendable () -> Void
    let register:
        @MainActor @Sendable (
            ListeningRemoteAction, @escaping @Sendable () -> ListeningRemoteResult
        ) -> Removal
    let update: @MainActor @Sendable (ListeningRemoteSnapshot?) -> Void
}

@MainActor
final class ListeningRemoteControl {
    typealias CleanupSchedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let services: ListeningRemoteServices
    private let input: ListeningRemoteInput
    private let lifetime: Lifetime
    private var invalidated = false
    private var previous: ListeningRemoteSnapshot?

    convenience init(
        snapshot: ListeningRemoteSnapshot,
        send: @escaping @Sendable (ListeningRemoteAction) -> ListeningRemoteResult
    ) {
        self.init(snapshot: snapshot, services: .system(), send: send)
    }

    init(
        snapshot: ListeningRemoteSnapshot, services: ListeningRemoteServices,
        cleanupSchedule: @escaping CleanupSchedule = { work in
            Task { @MainActor in work() }
        },
        send: @escaping @Sendable (ListeningRemoteAction) -> ListeningRemoteResult
    ) {
        self.services = services
        let input = ListeningRemoteInput(send: send)
        self.input = input
        let removals = ListeningRemoteAction.allCases.map { action in
            services.register(action) { input.submit(action) }
        }
        lifetime = Lifetime(input: input, schedule: cleanupSchedule) {
            // Registration removal and metadata work occur outside both lifetime/input locks.
            for remove in removals { remove() }
            services.update(nil)
        }
        update(snapshot)
    }

    deinit { lifetime.finishEventually() }

    /// UI and remote commands reach the same backend synchronously. No MainActor task is
    /// inserted before backend admission; Toggle/Next/reset ordering belongs to that mailbox.
    @discardableResult
    nonisolated func submit(_ action: ListeningRemoteAction) -> ListeningRemoteResult {
        input.submit(action)
    }

    func update(_ snapshot: ListeningRemoteSnapshot) {
        guard !invalidated, previous != snapshot else { return }
        previous = snapshot
        services.update(snapshot)
    }

    /// Call before replacing this app-lifetime adapter. Deinit also invalidates handlers
    /// immediately, then schedules only registration/metadata cleanup on MainActor.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        lifetime.finish()
    }

    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private let input: ListeningRemoteInput
        private let cleanup: @MainActor @Sendable () -> Void
        private let schedule: CleanupSchedule
        private var finished = false

        init(
            input: ListeningRemoteInput, schedule: @escaping CleanupSchedule,
            cleanup: @escaping @MainActor @Sendable () -> Void
        ) {
            self.input = input
            self.schedule = schedule
            self.cleanup = cleanup
        }

        private func claim() -> Bool {
            input.invalidate()
            return lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
        }

        @MainActor func finish() { if claim() { cleanup() } }
        func finishEventually() {
            guard claim() else { return }
            let cleanup = cleanup
            schedule { cleanup() }
        }
    }
}

extension ListeningRemoteServices {
    @MainActor static func system() -> Self {
        let system = SystemListeningRemote()
        return Self(
            register: { system.register($0, receive: $1) },
            update: { system.update($0) })
    }
}

@MainActor
private final class SystemListeningRemote {
    private static var currentOwner: UUID?
    private let identity = UUID()
    private let commands = MPRemoteCommandCenter.shared()
    private let information = MPNowPlayingInfoCenter.default()

    init() {
        Self.currentOwner = identity
        // This app has one device listening owner. No duration, seek, rate, history or queue
        // controls are advertised. Only our own registered handler tokens are removed later.
        for command in [
            commands.stopCommand, commands.previousTrackCommand,
            commands.seekForwardCommand, commands.seekBackwardCommand,
            commands.skipForwardCommand, commands.skipBackwardCommand,
            commands.changePlaybackPositionCommand, commands.changePlaybackRateCommand,
            commands.changeRepeatModeCommand, commands.changeShuffleModeCommand,
            commands.ratingCommand, commands.likeCommand, commands.dislikeCommand,
            commands.bookmarkCommand, commands.enableLanguageOptionCommand,
            commands.disableLanguageOptionCommand,
        ] { command.isEnabled = false }
    }

    func register(
        _ action: ListeningRemoteAction, receive: @escaping @Sendable () -> ListeningRemoteResult
    ) -> ListeningRemoteServices.Removal {
        let command = command(for: action)
        let token = command.addTarget { _ in
            switch receive() {
            case .accepted: .success
            case .unavailable: .noActionableNowPlayingItem
            }
        }
        return { command.removeTarget(token) }
    }

    func update(_ snapshot: ListeningRemoteSnapshot?) {
        // A delayed deinit cleanup cannot clear a newer owner's metadata or disable it.
        guard Self.currentOwner == identity else { return }
        for action in ListeningRemoteAction.allCases {
            command(for: action).isEnabled = snapshot?.permits(action) ?? false
        }
        information.nowPlayingInfo = snapshot.flatMap { ListeningRemoteMetadata.values($0) }
        if snapshot == nil { Self.currentOwner = nil }
    }

    private func command(for action: ListeningRemoteAction) -> MPRemoteCommand {
        switch action {
        case .play: commands.playCommand
        case .pause: commands.pauseCommand
        case .toggle: commands.togglePlayPauseCommand
        case .next: commands.nextTrackCommand
        }
    }
}

@MainActor
enum ListeningRemoteMetadata {
    // This poster belongs to the ongoing session and survives transport and song changes.
    private static let artwork: MPMediaItemArtwork? = {
        guard let poster = UIImage(named: "NowPlayingArtwork") else { return nil }
        return MPMediaItemArtwork(boundsSize: poster.size) { @Sendable size in
            guard size.width > 0, size.height > 0,
                min(size.width, size.height) < poster.size.width
            else { return poster }
            return poster.preparingThumbnail(of: size) ?? poster
        }
    }()

    static func values(_ snapshot: ListeningRemoteSnapshot) -> [String: Any]? {
        guard snapshot.state != .unavailable, snapshot.state != .ready else { return nil }
        var value: [String: Any] = [
            MPMediaItemPropertyTitle: "Lowlight",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.state == .playing ? 1.0 : 0.0,
        ]
        value[MPMediaItemPropertyArtwork] = artwork
        if let subtitle = snapshot.subtitle { value[MPMediaItemPropertyAlbumTitle] = subtitle }
        return value
    }

}
