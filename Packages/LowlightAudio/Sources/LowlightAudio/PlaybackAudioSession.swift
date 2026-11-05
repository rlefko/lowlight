// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation

/// Synchronous hooks used only on the playback control queue. The host provides one
/// device coordinator because AVAudioSession is process-global, not owned by a graph.
struct PlaybackAudioSession: Sendable {
    let configure: @Sendable () throws -> Void
    let activate: @Sendable () throws -> Void
    let deactivate: @Sendable () throws -> Void
    let observe:
        @Sendable (@escaping @Sendable (PlaybackAudioSessionEvent) -> Void)
            -> PlaybackAudioSessionObservation

    init(
        configure: @escaping @Sendable () throws -> Void,
        activate: @escaping @Sendable () throws -> Void,
        deactivate: @escaping @Sendable () throws -> Void,
        observe:
            @escaping @Sendable (@escaping @Sendable (PlaybackAudioSessionEvent) -> Void)
            -> PlaybackAudioSessionObservation = { _ in PlaybackAudioSessionObservation() }
    ) {
        self.configure = configure
        self.activate = activate
        self.deactivate = deactivate
        self.observe = observe
    }

    static let unmanaged = PlaybackAudioSession(configure: {}, activate: {}, deactivate: {})

    static var system: PlaybackAudioSession { system(notificationCenter: .default) }

    static func system(notificationCenter: NotificationCenter) -> PlaybackAudioSession {
        #if os(iOS)
            PlaybackAudioSession(
                configure: {
                    try AVAudioSession.sharedInstance().setCategory(
                        .playback, mode: .default, options: [])
                },
                activate: { try AVAudioSession.sharedInstance().setActive(true) },
                deactivate: {
                    try AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation)
                },
                observe: {
                    PlaybackAudioSessionObservation.system(
                        notificationCenter: notificationCenter, receive: $0)
                })
        #else
            .unmanaged
        #endif
    }
}
