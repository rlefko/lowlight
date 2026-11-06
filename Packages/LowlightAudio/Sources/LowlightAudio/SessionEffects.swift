// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

/// The three controls that shape generated sound independently of song planning.
public struct SessionEffects: Equatable, Sendable {
    public var warmth, space, texture: Double

    public init(warmth: Double, space: Double, texture: Double) {
        self.warmth = warmth
        self.space = space
        self.texture = texture
    }

    public init(_ controls: Controls) {
        self.init(warmth: controls.warmth, space: controls.space, texture: controls.texture)
    }

    func normalized() throws -> Self {
        try Self(applying(to: Controls()).normalized())
    }

    func applying(to controls: Controls) -> Controls {
        var controls = controls
        controls.warmth = warmth
        controls.space = space
        controls.texture = texture
        return controls
    }
}

extension Controls {
    func hasSameMusic(as other: Self) -> Bool {
        energy == other.energy && mood == other.mood && tempo == other.tempo
            && variation == other.variation
    }
}

/// Effects revisions belong to the render path. Adopted and settled count generated
/// canonical audio. They do not describe device presentation or a musical handoff.
public struct SessionEffectsSnapshot: Equatable, Sendable {
    public let requested, settled: SessionEffects
    public let revision, adoptedRevision, settledRevision: UInt64

    init(
        requested: SessionEffects, revision: UInt64,
        settled: SessionEffects, adoptedRevision: UInt64, settledRevision: UInt64
    ) {
        self.requested = requested
        self.revision = revision
        self.settled = settled
        self.adoptedRevision = adoptedRevision
        self.settledRevision = settledRevision
    }
}

/// A weak capability with independent native acknowledgment, including while the
/// preparation owner is busy. Only the native consumer changes render state.
public struct SessionEffectsInput: Sendable {
    private let submit: @Sendable (SessionEffects, UInt64) -> Bool
    private let read: @Sendable () -> SessionEffectsSnapshot?

    init(_ mailbox: SessionEffectsMailbox) {
        submit = { [weak mailbox] effects, revision in
            mailbox?.send(effects, revision: revision) ?? false
        }
        read = { [weak mailbox] in mailbox?.snapshot }
    }

    @discardableResult public func send(_ effects: SessionEffects, revision: UInt64) -> Bool {
        submit(effects, revision)
    }

    public var snapshot: SessionEffectsSnapshot? { read() }
}

/// The endpoint pins the pair through each producer call. A retained public input
/// holds only a weak reference here. The callback never uses this producer lock.
final class SessionEffectsMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let endpoint: PreparedSession.EffectsEndpoint
    private var target: SessionEffects
    private var revision: UInt64 = 1
    private var stopped = false

    init(_ endpoint: PreparedSession.EffectsEndpoint) {
        self.endpoint = endpoint
        let initial = endpoint.progress
        target = SessionEffects(
            warmth: initial.warmth, space: initial.space, texture: initial.texture)
    }

    func send(_ value: SessionEffects, revision: UInt64) -> Bool {
        guard let value = try? value.normalized() else { return false }
        return lock.withLock {
            guard !stopped, revision >= self.revision else { return false }
            if revision == self.revision { return value == target }
            return publish(value, revision: revision)
        }
    }

    /// A whole worker control submission can follow separately revisioned previews.
    /// It commits the latest effect target using this lane's own monotonic counter.
    func commit(_ value: SessionEffects) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            if value == target { return true }
            guard revision < .max else { return false }
            return publish(value, revision: revision + 1)
        }
    }

    private func publish(_ value: SessionEffects, revision: UInt64) -> Bool {
        guard
            endpoint.send(
                revision: revision, warmth: value.warmth, space: value.space, texture: value.texture
            )
        else { return false }
        target = value
        self.revision = revision
        return true
    }

    var snapshot: SessionEffectsSnapshot {
        lock.withLock {
            let progress = endpoint.progress
            return SessionEffectsSnapshot(
                requested: target, revision: revision,
                settled: SessionEffects(
                    warmth: progress.warmth, space: progress.space, texture: progress.texture),
                adoptedRevision: progress.adoptedRevision, settledRevision: progress.settledRevision
            )
        }
    }

    func close() { lock.withLock { stopped = true } }
}
