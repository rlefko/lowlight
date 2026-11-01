// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightPlanning

public enum SongRenderLayoutError: Error { case invalidLayout }

/// Finite logical song coordinates at 32 kHz, including the source tail.
/// Include the final logical frames recovered by glue's drain; physical startup
/// frames and peak protection's delay do not increase this length.
public struct SongRenderLayout: Equatable, Sendable {
    public let frameOrigin: UInt64
    public let inputFrames: UInt32
    public let bodyFrames: Range<UInt32>

    /// Explicit local boundaries, including independently imported reference frames.
    /// This initializer performs no conversion between local and absolute clocks.
    public init(frameOrigin: UInt64, inputFrames: UInt32, bodyFrames: Range<UInt32>) throws {
        let maximumFrame = UInt64(MusicalTime.maximumFrame)
        guard inputFrames > 0, inputFrames <= SongMix.maximumInputFrames,
            frameOrigin <= maximumFrame, UInt64(inputFrames) <= maximumFrame - frameOrigin,
            bodyFrames.lowerBound <= bodyFrames.upperBound,
            bodyFrames.upperBound <= inputFrames,
            bodyFrames.upperBound - bodyFrames.lowerBound >= SongLoudnessMeter.minimumBodyFrames,
            bodyFrames.upperBound - bodyFrames.lowerBound <= SongLoudnessMeter.maximumBodyFrames
        else { throw SongRenderLayoutError.invalidLayout }
        self.frameOrigin = frameOrigin
        self.inputFrames = inputFrames
        self.bodyFrames = bodyFrames
    }

    /// Reuses the native schedule's shared rounded absolute boundaries, rebased
    /// by the same origin. The finite render includes five seconds after the form.
    public init(schedule: SongSchedule) throws {
        try schedule.validate()
        let origin = try schedule.frame(at: 0)
        let bodyStart = try schedule.frame(at: 16)
        let bodyEnd = try schedule.outgoing.ramp.frame(at: 0)
        let formEnd = try schedule.outgoing.ramp.frame(at: 16)
        guard origin >= 0, bodyStart >= origin, bodyEnd >= bodyStart, formEnd >= bodyEnd else {
            throw SongRenderLayoutError.invalidLayout
        }
        let frames = UInt64(formEnd - origin) + 160_000
        guard frames <= UInt64(SongMix.maximumInputFrames) else {
            throw SongRenderLayoutError.invalidLayout
        }
        try self.init(
            frameOrigin: UInt64(origin), inputFrames: UInt32(frames),
            bodyFrames: UInt32(bodyStart - origin)..<UInt32(bodyEnd - origin))
    }
}
