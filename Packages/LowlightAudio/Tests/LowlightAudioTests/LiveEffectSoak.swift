// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Testing

@testable import LowlightAudio

/// One reversal every thirty seconds, offset from complete preset commits. The consumer
/// observes adoption inside the first ramp and settlement after rendering the second.
struct LiveEffectSoak {
    private enum Phase {
        case begin
        case reverse(revision: UInt64)
        case restore(revision: UInt64)
        case verify(revision: UInt64)
    }
    private let input: SessionEffectsInput
    private let limit: Int
    private var phase = Phase.begin
    private var due: UInt64 = 15 * 32_000
    private(set) var cycles = 0
    private(set) var receipts: [[String: UInt64]] = []
    private var currentReceipt: [String: UInt64] = [:]

    init(input: SessionEffectsInput, cycles: Int) {
        self.input = input
        limit = cycles
    }

    mutating func update(frame: UInt64, committed: SessionEffects) throws {
        guard cycles < limit, frame >= due else { return }
        let state = try #require(input.snapshot)
        let low = SessionEffects(warmth: 0, space: 1, texture: 0)
        let high = SessionEffects(warmth: 1, space: 0, texture: 1)
        let first = cycles.isMultiple(of: 2) ? low : high
        let second = cycles.isMultiple(of: 2) ? high : low
        switch phase {
        case .begin:
            // No consumer pull between these sends. The second target supersedes the first.
            try #require(input.send(second, revision: state.revision + 1))
            let revision = state.revision + 2
            try #require(input.send(first, revision: revision))
            currentReceipt = ["first_frame": frame, "first_revision": revision]
            due = frame + 1_600
            phase = .reverse(revision: revision)
        case .reverse(let firstRevision):
            try #require(
                state.adoptedRevision == firstRevision && state.settledRevision < firstRevision)
            let revision = state.revision + 1
            try #require(input.send(second, revision: revision))
            currentReceipt["reverse_frame"] = frame
            currentReceipt["reverse_revision"] = revision
            due = frame + 10_000
            phase = .restore(revision: revision)
        case .restore(let reverseRevision):
            try #require(state.settledRevision == reverseRevision && state.settled == second)
            let revision = state.revision + 1
            try #require(input.send(committed, revision: revision))
            currentReceipt["restore_frame"] = frame
            due = frame + 10_000
            phase = .verify(revision: revision)
        case .verify(let revision):
            try #require(state.settledRevision == revision && state.settled == committed)
            currentReceipt["settled_frame"] = frame
            currentReceipt["settled_revision"] = revision
            receipts.append(currentReceipt)
            cycles += 1
            due = UInt64(15 + cycles * 30) * 32_000
            phase = .begin
        }
    }
}
