// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import LowlightPlanning

/// Immutable bus envelopes on the mixer's 32 kHz event clock, before filters/glue/room.
/// Fractional frames support independent reference imports. Native plans use shared rounded frames.
/// The mixer validates this descriptor before preparing samples or loading a score.
public struct SongRackFades {
    public let tonalInStartFrame, tonalInEndFrame: Double
    public let tonalOutStartFrame, tonalOutEndFrame: Double
    public let rhythmInFrame, rhythmOutFrame: Double

    /// Both incoming tonal endpoints zero disable arrival fading; rhythmInFrame zero disables gating.
    public init(
        tonalInStartFrame: Double = 0, tonalInEndFrame: Double = 0,
        tonalOutStartFrame: Double, tonalOutEndFrame: Double,
        rhythmInFrame: Double = 0, rhythmOutFrame: Double
    ) {
        self.tonalInStartFrame = tonalInStartFrame
        self.tonalInEndFrame = tonalInEndFrame
        self.tonalOutStartFrame = tonalOutStartFrame
        self.tonalOutEndFrame = tonalOutEndFrame
        self.rhythmInFrame = rhythmInFrame
        self.rhythmOutFrame = rhythmOutFrame
    }

    /// Uses the same absolute endpoints as SongSchedule's tonal and rhythm gains.
    /// Events supplied to the mixer must use this same clock.
    public init(schedule: SongSchedule) throws {
        try schedule.validate()
        self.init(
            tonalInStartFrame: Double(try schedule.incoming?.ramp.frame(at: 0) ?? 0),
            tonalInEndFrame: Double(try schedule.incoming?.ramp.frame(at: 16) ?? 0),
            tonalOutStartFrame: Double(try schedule.outgoing.ramp.frame(at: 0)),
            tonalOutEndFrame: Double(try schedule.outgoing.ramp.frame(at: 16)),
            rhythmInFrame: Double(try schedule.incoming?.handoffFrame() ?? 0),
            rhythmOutFrame: Double(try schedule.outgoing.handoffFrame()))
    }

    var configuration: LLRackFades {
        LLRackFades(
            tonal_in_start_frame: tonalInStartFrame, tonal_in_end_frame: tonalInEndFrame,
            tonal_out_start_frame: tonalOutStartFrame, tonal_out_end_frame: tonalOutEndFrame,
            rhythm_in_frame: rhythmInFrame, rhythm_out_frame: rhythmOutFrame)
    }
}
