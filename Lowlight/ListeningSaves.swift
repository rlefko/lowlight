// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightAudio
import LowlightPlanning
import Observation

/// One atomic write at a time and one replaceable pending checkpoint. A failed write
/// preserves the newest intent for explicit retry without interrupting playback.
@MainActor @Observable
final class ListeningSaves {
    private(set) var failed = false
    private(set) var busy = false
    private(set) var lastSaved: ListeningRecord?
    private(set) var latest = ListeningRecord.initial
    @ObservationIgnored private let write: @Sendable (ListeningRecord) async throws -> Void
    @ObservationIgnored private var pending: ListeningRecord?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(write: @escaping @Sendable (ListeningRecord) async throws -> Void) {
        self.write = write
    }

    deinit { task?.cancel() }

    func restored(_ record: ListeningRecord?) {
        precondition(task == nil && pending == nil)
        lastSaved = record
        latest = record ?? .initial
    }

    /// A fresh owner reuses this seed on retries. Preserve the silent-launch policy by
    /// saving it with the first settings edit or capture; an old restart carries its own RNG.
    func bindSessionSeed(_ seed: UInt64) {
        latest = latest.withSessionSeed(seed)
    }

    func updateControls(_ controls: Controls) throws {
        latest = try ListeningRecord(
            controls: controls, restart: latest.restart, sessionSeed: latest.sessionSeed)
        submit(latest)
    }

    func capture(_ restart: SessionRestartIntent) {
        latest = latest.capturing(restart)
        submit(latest)
    }

    /// An explicit new-session choice replaces any pending old place, preserving settings.
    func discardRestart(seed: UInt64) {
        latest = latest.discardingRestart(seed: seed)
        failed = false
        submit(latest)
    }

    private func submit(_ intent: ListeningRecord) {
        guard intent != lastSaved || task != nil || pending != nil else { return }
        pending = intent
        drain()
    }

    func retry() {
        failed = false
        drain()
    }

    private func drain() {
        guard task == nil, !failed, pending != nil else { return }
        busy = true
        task = Task { [weak self, write] in
            guard let self else { return }
            defer {
                self.task = nil
                self.busy = false
            }
            while let intent = self.pending, !Task.isCancelled {
                self.pending = nil
                if intent == self.lastSaved { continue }
                do {
                    try await write(intent)
                    self.lastSaved = intent
                } catch {
                    if self.pending == nil { self.pending = intent }
                    self.failed = true
                    break
                }
            }
        }
    }
}
