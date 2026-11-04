// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Synchronization

/// One-way cancellation for one preparation attempt. Share with a control thread;
/// use a new token to retry. This neither stops rendering nor revokes an accepted song.
/// Cancellation is observed at worker checkpoints, not a synchronous stop/join.
public final class PreparationCancellation: Sendable {
    private let cancelled = Atomic(false)
    private let analysisCheckpoint: (@Sendable (UInt32) -> Void)?

    public init() { analysisCheckpoint = nil }

    // Internal test seam pins cancellation after real analysis progress, without timers.
    init(analysisCheckpoint: @escaping @Sendable (UInt32) -> Void) {
        self.analysisCheckpoint = analysisCheckpoint
    }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    // No payload is published by the flag. All cleanup stays on the preparing worker.
    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func check(analysisFrame: UInt32) throws {
        analysisCheckpoint?(analysisFrame)
        try check()
    }
}
