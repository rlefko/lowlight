// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

/// Opt-in release acceptance through the same worker and native endpoint used by the app.
/// Waits are recorded separately from PCM; this is not a hardware deadline benchmark.
struct SessionControlsStressTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["LOWLIGHT_CONTROLS_SOAK_SECONDS"] != nil))
    func productionControlsSoak() throws {
        let environment = ProcessInfo.processInfo.environment
        let seconds = try #require(Int(environment["LOWLIGHT_CONTROLS_SOAK_SECONDS"] ?? ""))
        try #require((720...7200).contains(seconds))
        let acceleration = try #require(
            Double(environment["LOWLIGHT_CONTROLS_SOAK_ACCELERATION"] ?? "8"))
        try #require(acceleration.isFinite && (1...64).contains(acceleration))
        let target = UInt64(seconds) * 32_000
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let initial = try Controls.preset(.focus)
        let worker = try SessionPreparationWorker(seed: 1, controls: initial, preparer: preparer)
        defer {
            worker.requestStop()
            worker.join()
        }
        let endpoint = try worker.makeRenderEndpoint()
        var effects = LiveEffectSoak(input: try #require(worker.effectsInput), cycles: seconds / 30)
        let destination = environment["LOWLIGHT_CONTROLS_SOAK_OUTPUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let destination {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
        }
        // Bounded excerpts include preset, manual/Auto tempo, and Variation changes.
        let auditionFrames = min(target, 720 * 32_000)
        let audioURL = destination?.appendingPathComponent("controls-soak-first-720s.f32")
        if let audioURL { try Data().write(to: audioURL) }
        let audio = try audioURL.map { try FileHandle(forWritingTo: $0) }
        defer { try? audio?.close() }
        var excerpts: [(name: String, start: UInt64, end: UInt64, file: FileHandle)] = []
        if let destination {
            for (name, start, end) in [
                ("workout", 660, 900), ("manual-tempo", 1380, 1620),
                ("auto-tempo", 1620, 1860), ("variation", 2820, 3060),
            ] where start < seconds {
                let url = destination.appendingPathComponent("controls-\(name).f32")
                try Data().write(to: url)
                excerpts.append(
                    (
                        name, UInt64(start) * 32_000, UInt64(end) * 32_000,
                        try FileHandle(forWritingTo: url)
                    ))
            }
        }
        defer { for excerpt in excerpts { try? excerpt.file.close() } }
        let sizes = [1, 17, 256, 1023, 4093]
        var buffer = [Float](repeating: 0, count: 4093 * 2)
        var requests: [[String: Any]] = []
        var observations: [[String: Any]] = []
        var revision: UInt64 = 1
        var requestIndex = 0
        var nextRequests = 0
        var nextSelectionChanges = 0
        var pendingNextSelection: UInt64?
        var submitted: [UInt64: Controls] = [1: initial]
        var supersededRevisions: Set<UInt64> = []
        var appliedRevisions: Set<UInt64> = [1]
        var appliedValues = [initial]
        var lastAppliedRevision: UInt64 = 1
        var pauses = 0
        let intendedCount = (seconds - 480) / 240
        var deferredSettings: [[String: UInt64]] = []
        var nextSettings: UInt64 = 240 * 32_000
        var nextSkip: UInt64 = 120 * 32_000
        var nextCapture: UInt64 = 32_000
        var selection: UInt64?
        var selections = 0
        var latest = initial
        var previousControls: SessionControlsSnapshot?
        var zeroPulls = 0
        var shortPulls = 0
        var pulls = 0
        var peak = 0.0
        var squares = 0.0
        let clock = ContinuousClock()
        let started = clock.now
        var progress = started

        func submit(_ controls: Controls, label: String) throws {
            revision += 1
            let request = try SessionControlsRequest(revision: revision, controls: controls)
            try #require(worker.setControls(request))
            try #require(worker.setControls(request))  // Idempotent repeated delivery.
            latest = request.controls
            submitted[revision] = request.controls
            if label.hasPrefix("superseded") { supersededRevisions.insert(revision) }
            requests.append([
                "frame": endpoint.position, "revision": revision, "label": label,
                "controls": try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest)),
            ])
        }

        while endpoint.position < target {
            try #require(progress.duration(to: clock.now) < .seconds(30))
            try #require(worker.lastError == nil && worker.controlsError == nil)
            // Keep an eight-minute musical tail for a deferred request to reach a later
            // eligible selection. Wall-clock waiting alone cannot finish a transition.
            // A newer intention may legally supersede a late handoff. Give each intended
            // setting a turn before sending the next burst. Retry on the 30-second grid
            // between live-effect reversals and keep rendering while preparation catches up.
            if endpoint.position >= nextSettings, !appliedRevisions.contains(revision),
                nextSettings + 480 * 32_000 <= target
            {
                deferredSettings.append(["frame": endpoint.position, "pending_revision": revision])
                nextSettings += 30 * 32_000
            }
            if endpoint.position >= nextSettings, requestIndex < intendedCount,
                nextSettings + 480 * 32_000 <= target
            {
                requestIndex += 1
                var controls: Controls
                let sequence: [Preset] = [.relax, .commute, .workout, .reflective, .focus]
                if requestIndex % 6 == 0 {
                    controls = initial
                    controls.energy = 0.58
                    controls.mood = 0.35
                    controls.variation = requestIndex.isMultiple(of: 12) ? 1 : 0
                    controls.tempo = 92
                } else {
                    controls = try .preset(sequence[(requestIndex - 1) % 6])
                }
                if requestIndex.isMultiple(of: 5) {
                    try #require(worker.suspend())
                    let deadline = clock.now + .seconds(30)
                    while worker.status != .suspended {
                        try #require(clock.now < deadline)
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    pauses += 1
                }
                if requestIndex.isMultiple(of: 2) {
                    var obsolete = controls
                    obsolete.tempo = 60
                    try submit(obsolete, label: "superseded-60")
                    obsolete.tempo = 100
                    try submit(obsolete, label: "superseded-100")
                }
                try submit(
                    controls,
                    label: requestIndex % 6 == 0
                        ? "Custom" : sequence[(requestIndex - 1) % 6].rawValue)
                if requestIndex.isMultiple(of: 5) {
                    let position = endpoint.position
                    Thread.sleep(forTimeInterval: 0.01)
                    try #require(worker.status == .suspended && endpoint.position == position)
                    try #require(worker.controlsSnapshot.requested == latest)
                    try #require(worker.resume())
                }
                nextSettings = max(
                    nextSettings + 30 * 32_000, UInt64(requestIndex + 1) * 240 * 32_000)
            }
            if endpoint.position >= nextSkip {
                if let selected = worker.listeningSnapshot?.selectionID, worker.requestNext() {
                    nextRequests += 1
                    pendingNextSelection = selected
                }
                nextSkip += 720 * 32_000
            }
            if endpoint.position >= nextCapture {
                worker.requestCapture()
                nextCapture += 32_000
            }
            if let current = worker.listeningSnapshot?.selectionID, current != selection {
                selection = current
                selections += 1
                worker.requestCapture()
                if let pending = pendingNextSelection, current > pending {
                    nextSelectionChanges += 1
                    pendingNextSelection = nil
                }
            }
            let controls = worker.controlsSnapshot
            if controls != previousControls {
                previousControls = controls
                if controls.appliedRevision > 0 {
                    try #require(controls.appliedRevision >= lastAppliedRevision)
                    try #require(
                        submitted[controls.appliedRevision]?.hasSameMusic(as: controls.applied)
                            == true)
                    try #require(!supersededRevisions.contains(controls.appliedRevision))
                    lastAppliedRevision = controls.appliedRevision
                    appliedRevisions.insert(controls.appliedRevision)
                    if controls.applied == submitted[controls.appliedRevision],
                        !appliedValues.contains(controls.applied)
                    {
                        appliedValues.append(controls.applied)
                    }
                }
                observations.append([
                    "frame": endpoint.position, "revision": controls.revision,
                    "appliedRevision": controls.appliedRevision,
                    "state": String(describing: controls.state),
                    "requested": try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(controls.requested)),
                    "applied": try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(controls.applied)),
                ])
            }
            try effects.update(frame: endpoint.position, committed: SessionEffects(latest))
            let before = endpoint.position
            let count = min(sizes[pulls % sizes.count], Int(target - before))
            let written = try #require(
                buffer.withUnsafeMutableBufferPointer {
                    endpoint.render(into: UnsafeMutableBufferPointer(rebasing: $0[..<(count * 2)]))
                })
            try #require(endpoint.position == before + UInt64(written) && !endpoint.isFaulted)
            try #require(buffer[..<(written * 2)].allSatisfy { $0.isFinite })
            try #require(buffer[(written * 2)..<(count * 2)].allSatisfy { $0 == 0 })
            for sample in buffer[..<(written * 2)] {
                let value = Double(sample)
                peak = max(peak, abs(value))
                squares += value * value
            }
            if before < auditionFrames, let audio {
                let exported = min(written, Int(auditionFrames - before))
                try buffer.withUnsafeBytes { bytes in
                    try audio.write(
                        contentsOf: bytes.prefix(exported * 2 * MemoryLayout<Float>.stride))
                }
            }
            for excerpt in excerpts {
                let start = max(before, excerpt.start)
                let end = min(before + UInt64(written), excerpt.end)
                if end > start {
                    try buffer.withUnsafeBytes { bytes in
                        let lower = Int(start - before) * 2 * MemoryLayout<Float>.stride
                        let upper = Int(end - before) * 2 * MemoryLayout<Float>.stride
                        try excerpt.file.write(contentsOf: bytes[lower..<upper])
                    }
                }
            }
            pulls += 1
            if written == 0 {
                zeroPulls += 1
                Thread.sleep(forTimeInterval: 0.001)
            } else {
                if written < count { shortPulls += 1 }
                progress = clock.now
                // This correctness soak explicitly yields preparation time; its elapsed
                // duration is not a maximum-throughput or device-deadline measurement.
                let waitingForHandoff =
                    deferredSettings.last?["pending_revision"] == revision
                    && !appliedRevisions.contains(revision)
                let pace = waitingForHandoff ? 1 : acceleration
                Thread.sleep(forTimeInterval: Double(written) / (32_000 * pace))
            }
        }
        // Give the worker its ordinary observation turn after the final consumer pull.
        worker.requestCapture()
        Thread.sleep(forTimeInterval: 0.2)
        let final = worker.controlsSnapshot
        let finalEffects = try #require(worker.effectsSnapshot)
        try #require(effects.cycles == seconds / 30)
        try #require(finalEffects.requested == SessionEffects(latest))
        try #require(finalEffects.requested == finalEffects.settled)
        try #require(finalEffects.revision == finalEffects.settledRevision)
        if final.appliedRevision > 0 {
            try #require(submitted[final.appliedRevision]?.hasSameMusic(as: final.applied) == true)
            appliedRevisions.insert(final.appliedRevision)
            if final.applied == submitted[final.appliedRevision],
                !appliedValues.contains(final.applied)
            {
                appliedValues.append(final.applied)
            }
        }
        worker.requestStop()
        worker.join()
        worker.captureAfterRenderStopped()
        try #require(
            worker.lastError == nil && worker.controlsError == nil && worker.status == .stopped)
        try #require(peak > 0 && peak <= 1 && squares > 0 && endpoint.position == target)
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        let presets = try Preset.allCases.map { try Controls.preset($0) }
        let fullCoverage =
            presets.allSatisfy { appliedValues.contains($0) }
            && appliedValues.contains { $0.tempo == 92 && $0.variation == 0 }
            && appliedValues.contains { $0.tempo == 92 && $0.variation == 1 }
        let intendedRevisions = Set(submitted.keys).subtracting(supersededRevisions)
        let allIntendedApplied =
            requestIndex == intendedCount && appliedRevisions == intendedRevisions
        let coverage = allIntendedApplied && (seconds < 7200 || fullCoverage)
        let elapsed = started.duration(to: clock.now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let receipt: [String: Any] = [
            "passed": final.requested == latest && final.applied == latest && final.state == .none
                && final.revision == revision && final.appliedRevision == revision
                && nextSelectionChanges == nextRequests && coverage,
            "effect_cycles": effects.cycles, "effect_observations": effects.receipts,
            "final_effect_revision": finalEffects.revision,
            "seed": 1, "audio_seconds": seconds, "frames": target,
            "samples": target * 2, "peak": peak, "rms": sqrt(squares / Double(target * 2)),
            "elapsed_seconds_excluding_initial_preparation": elapsedSeconds,
            "maximum_consumer_acceleration": acceleration,
            "maximum_resident_bytes": usage.ru_maxrss,
            "selections": selections, "next_requests": nextRequests, "suspensions": pauses,
            "next_selection_changes": nextSelectionChanges,
            "applied_revisions": appliedRevisions.sorted(),
            "intended_revisions": intendedRevisions.sorted(), "planned_changes": intendedCount,
            "deferred_settings_windows": deferredSettings,
            "applied_settings_count": appliedValues.count,
            "zero_pulls": zeroPulls, "short_pulls": shortPulls, "pulls": pulls,
            "requests": requests, "observations": observations, "last_revision": revision,
            "final_revision": final.revision, "final_applied_revision": final.appliedRevision,
            "final_state": String(describing: final.state),
            "full_scheduled_settings_coverage": fullCoverage,
            "coverage_required": seconds == 7200, "coverage_gate_passed": coverage,
            "excerpts": excerpts.map {
                [
                    "name": $0.name, "start_frame": $0.start,
                    "end_frame": min(target, $0.end),
                ] as [String: Any]
            },
            "worker_stopped": true, "worker_error_nil": true,
            "limitations":
                "Accelerated native stream with explicit waits; no hardware deadline, energy, device memory, or live pool-counter measurement.",
        ]
        if let destination {
            try JSONSerialization.data(
                withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: destination.appendingPathComponent("controls-soak.json"))
        }
        try #require(final.requested == latest && final.applied == latest && final.state == .none)
        try #require(final.revision == revision && final.appliedRevision == revision)
        try #require(nextSelectionChanges == nextRequests)
        try #require(coverage)
        print(
            "Controls soak: \(seconds)s, \(selections) selections, \(requestIndex) settings changes, peak \(peak)"
        )
    }
}
