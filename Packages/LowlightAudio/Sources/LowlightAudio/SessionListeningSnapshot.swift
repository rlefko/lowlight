// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightPlanning

public enum SessionRestartError: Error, Equatable { case invalidIntent, unsupportedVersion }

/// Bounded musical intent, not a serialized renderer. Restoration warms one song's prefix
/// with fresh effects; predecessor tails and the original session protector are not restored.
/// Decoding never starts playback. File location and autoplay policy belong to the host.
public struct SessionRestartIntent: Equatable, Sendable {
    public static let formatVersion = 1
    public static let maximumEncodedByteCount = 262_144
    public let checkpoint: Data
    public let canonicalFrame: UInt64
    let schedule: SongSchedule

    public var currentSong: SongPlan { schedule.song }

    private struct Envelope: Codable {
        let formatVersion: Int
        let checkpoint: Data
    }

    /// The checkpoint must belong to the rendered selection, not the preparation cursor.
    /// Its existing v1 position field is updated through the validated planning owner.
    public init(checkpoint: Data, canonicalFrame: UInt64) throws {
        guard canonicalFrame <= UInt64(MusicalTime.maximumFrame) else {
            throw SessionRestartError.invalidIntent
        }
        let planning = try SessionPlanning.restore(checkpoint)
        guard let schedule = planning.current else { throw SessionRestartError.invalidIntent }
        try planning.setPosition(frame: Int64(canonicalFrame))
        let captured = try planning.checkpoint()
        guard captured.count <= SessionTimeline.maximumCheckpointByteCount else {
            throw SessionRestartError.invalidIntent
        }
        self.checkpoint = captured
        self.canonicalFrame = canonicalFrame
        self.schedule = schedule
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            Envelope(formatVersion: Self.formatVersion, checkpoint: checkpoint))
        guard data.count <= Self.maximumEncodedByteCount else {
            throw SessionRestartError.invalidIntent
        }
        return data
    }

    public static func restore(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedByteCount else { throw SessionRestartError.invalidIntent }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch {
            throw SessionRestartError.invalidIntent
        }
        guard envelope.formatVersion == formatVersion else {
            throw SessionRestartError.unsupportedVersion
        }
        let planning = try SessionPlanning.restore(envelope.checkpoint)
        guard let frame = planning.positionFrame, frame >= 0, planning.current != nil else {
            throw SessionRestartError.invalidIntent
        }
        return try Self(checkpoint: envelope.checkpoint, canonicalFrame: UInt64(frame))
    }
}

public enum SessionNextState: Equatable, Sendable { case none, queued, transitioning }

/// Immutable worker-published state. Selection changes at the rhythm handoff. Both clocks
/// describe generated canonical audio, not device presentation or an audible playhead.
public struct SessionListeningSnapshot: Equatable, Sendable {
    public let currentSong: SongPlan
    public let nextSong: SongPlan?
    public let canonicalFrame: UInt64
    public let transportFrame: UInt64
    public let nextState: SessionNextState
    public let restart: SessionRestartIntent

    public var selectionID: UInt64 { currentSong.id }
}
