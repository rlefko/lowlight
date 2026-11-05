// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation

enum PlaybackAudioSessionEvent: Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case oldDeviceUnavailable
}

/// Removes observers once, without invoking the cancellation closure under its lock.
final class PlaybackAudioSessionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(_ cancellation: @escaping @Sendable () -> Void = {}) {
        self.cancellation = cancellation
    }

    deinit { cancel() }

    func cancel() {
        let action = lock.withLock {
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }

    #if os(iOS)
        // Tokens are immutable after registration; the outer observation serializes removal.
        private final class Registrations: @unchecked Sendable {
            let center: NotificationCenter
            let tokens: [NSObjectProtocol]
            init(_ center: NotificationCenter, _ tokens: [NSObjectProtocol]) {
                self.center = center
                self.tokens = tokens
            }
            func remove() { for token in tokens { center.removeObserver(token) } }
        }

        static func system(
            notificationCenter: NotificationCenter,
            receive: @escaping @Sendable (PlaybackAudioSessionEvent) -> Void
        ) -> PlaybackAudioSessionObservation {
            let session = AVAudioSession.sharedInstance()
            let interruption = notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: nil
            ) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    if let reason = notification.userInfo?[AVAudioSessionInterruptionReasonKey]
                        as? UInt,
                        reason == AVAudioSession.InterruptionReason.routeDisconnected.rawValue
                    {
                        receive(.oldDeviceUnavailable)
                    }
                    receive(.interruptionBegan)
                case .ended:
                    let raw =
                        notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                        as? UInt ?? 0
                    receive(
                        .interruptionEnded(
                            shouldResume: AVAudioSession.InterruptionOptions(rawValue: raw)
                                .contains(.shouldResume)))
                @unknown default: break
                }
            }
            let route = notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: session, queue: nil
            ) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                    raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                else { return }
                receive(.oldDeviceUnavailable)
            }
            let registrations = Registrations(notificationCenter, [interruption, route])
            return PlaybackAudioSessionObservation { registrations.remove() }
        }
    #endif
}
