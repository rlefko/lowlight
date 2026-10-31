// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum TimelineError: Error, Equatable {
    case invalidTime, invalidSchedule, invalidCheckpoint, unsupportedVersion
}

public enum MusicalTime {
    public static let sampleRate = 32_000.0
    public static let maximumFrame: Int64 = 1 << 52

    public static func frame(_ seconds: Double) throws -> Int64 {
        guard seconds.isFinite, seconds >= 0,
            seconds <= Double(maximumFrame) / sampleRate
        else { throw TimelineError.invalidTime }
        return Int64((seconds * sampleRate).rounded(.toNearestOrEven))
    }
}

/// One shared 16-beat linear BPM ramp, integrated before absolute frame rounding.
public struct TempoRamp: Codable, Equatable, Sendable {
    public let startSeconds, fromTempo, toTempo: Double

    public init(startSeconds: Double, fromTempo: Double, toTempo: Double) throws {
        self.startSeconds = startSeconds
        self.fromTempo = fromTempo
        self.toTempo = toTempo
        try validate()
    }

    func validate() throws {
        guard fromTempo.isFinite, toTempo.isFinite,
            (60...100).contains(fromTempo), (60...100).contains(toTempo)
        else { throw TimelineError.invalidTime }
        _ = try MusicalTime.frame(startSeconds)
        _ = try MusicalTime.frame(startSeconds + elapsed(16))
    }

    private func elapsed(_ beats: Double) -> Double {
        let slope = (toTempo - fromTempo) / 16
        return abs(slope) < 1e-12
            ? 60 * beats / fromTempo : 60 * log1p(slope * beats / fromTempo) / slope
    }

    public func seconds(at beat: Double) throws -> Double {
        try validate()
        guard beat.isFinite, (0...16).contains(beat) else { throw TimelineError.invalidTime }
        return startSeconds + elapsed(beat)
    }

    public func frame(at beat: Double) throws -> Int64 {
        try MusicalTime.frame(seconds(at: beat))
    }

    /// Linear in elapsed frames between the rounded endpoints, within one frame of elapsed seconds.
    public func progress(atFrame frame: Int64) throws -> Double {
        guard (0...MusicalTime.maximumFrame).contains(frame) else {
            throw TimelineError.invalidTime
        }
        let start = try self.frame(at: 0)
        let end = try self.frame(at: 16)
        return min(1, max(0, Double(frame - start) / Double(end - start)))
    }
}
