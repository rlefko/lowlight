// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio

/// Synchronous hooks used only on the playback control queue. The host provides one
/// device coordinator because AVAudioSession is process-global, not owned by a graph.
struct PlaybackAudioSession: Sendable {
    let configure: @Sendable () throws -> Void
    let activate: @Sendable () throws -> Void
    let deactivate: @Sendable () throws -> Void

    static let unmanaged = PlaybackAudioSession(configure: {}, activate: {}, deactivate: {})

    static var system: PlaybackAudioSession {
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
                })
        #else
            .unmanaged
        #endif
    }
}
