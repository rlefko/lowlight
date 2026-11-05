// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import LowlightPlanning

public enum SessionControlsError: Error, Equatable { case invalidRevision, stalePlan }

/// One complete desired setting, rather than a queue of individual slider samples.
/// Revisions are monotonic within one playback owner; zero denotes its initial state.
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

/// Requested settings do not become sounding settings merely because preparation finishes.
/// Applied settings follow the selected song at the shared rhythm handoff.
public struct SessionControlsSnapshot: Equatable, Sendable {
    public let requested: Controls
    public let applied: Controls
    public let revision: UInt64
    public let appliedRevision: UInt64
    public let state: SessionControlChangeState
}
