// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightPlanning

public enum SessionControlsError: Error, Equatable {
    case invalidRevision, stalePlan, unsupportedSource
}

/// One complete desired setting, rather than a queue of individual slider samples.
/// Revisions are monotonic within one playback owner; zero is reserved and cannot be submitted.
public struct SessionControlsRequest: Equatable, Sendable {
    public let revision: UInt64
    public let controls: Controls

    public init(revision: UInt64, controls: Controls) throws {
        guard revision > 0 else { throw SessionControlsError.invalidRevision }
        self.controls = try controls.normalized()
        self.revision = revision
    }
}

public enum SessionControlChangeState: Equatable, Sendable {
    case none, queued, transitioning, failed
}

/// The musical revision and its phase follow selection at the shared rhythm handoff.
/// The worker's applied value combines that music with the last settled render effects.
/// See SessionEffectsSnapshot for independent live target and ramp acknowledgments.
public struct SessionControlsSnapshot: Equatable, Sendable {
    public let requested: Controls
    public let applied: Controls
    public let revision: UInt64
    public let appliedRevision: UInt64
    public let state: SessionControlChangeState
}
