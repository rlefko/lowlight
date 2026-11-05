// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

@testable import Lowlight

@MainActor
struct ListeningSavesTests {
    private func intents() throws -> [SessionRestartIntent] {
        let planning = try SessionPlanning()
        _ = try planning.next()
        let checkpoint = try planning.checkpoint()
        return try [UInt64(100), 200, 300, 400].map {
            try SessionRestartIntent(checkpoint: checkpoint, canonicalFrame: $0)
        }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func serialWritesCoalesceToTheNewestIntentEvenWhenReturningToAnOldPosition() async throws
    {
        let values = try intents()
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.restored(try ListeningRecord(controls: .preset(.focus), restart: values[0]))
        saves.capture(values[0])
        #expect(!saves.busy && !saves.failed)
        saves.capture(values[1])
        try await wait { await writer.current == 200 }
        saves.capture(values[2])
        saves.capture(values[3])
        saves.capture(values[0])
        #expect(saves.busy)
        await writer.finish(.success(()))
        try await wait { await writer.current == 100 }
        #expect(saves.lastSaved?.restart == values[1])
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved?.restart == values[0] && !saves.failed)
        #expect(await writer.frames == [200, 100])
        saves.capture(values[0])
        #expect(!saves.busy)
    }

    @Test func failedWritesRetainTheLatestPendingPositionUntilExplicitRetry() async throws {
        let values = try intents()
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.restored(try ListeningRecord(controls: .preset(.focus), restart: values[0]))
        saves.capture(values[1])
        try await wait { await writer.current == 200 }
        saves.capture(values[2])
        await writer.finish(.failure(CheckpointWriteError.failed))
        try await wait { saves.failed && !saves.busy }
        #expect(saves.lastSaved?.restart == values[0])
        saves.capture(values[3])
        #expect(!saves.busy && saves.failed)
        #expect(await writer.frames == [200])
        saves.retry()
        try await wait { await writer.current == 400 }
        saves.retry()
        saves.capture(values[3])
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(!saves.failed && saves.lastSaved?.restart == values[3])
        #expect(await writer.frames == [200, 400])
    }

    @Test func failureWithNoNewerCaptureRetriesTheSameCheckpoint() async throws {
        let saved = try intents()[0]
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.capture(saved)
        try await wait { await writer.current == 100 }
        await writer.finish(.failure(CheckpointWriteError.failed))
        try await wait { saves.failed && !saves.busy }
        saves.retry()
        try await wait { await writer.current == 100 }
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved?.restart == saved && !saves.failed)
        #expect(await writer.frames == [100, 100])
    }

    @Test func capturesMergeWithTheLatestSettingsWhileOlderWritesAreInFlight() async throws {
        let values = try intents()
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.restored(try ListeningRecord(controls: .preset(.focus), restart: values[0]))
        saves.capture(values[1])
        try await wait { await writer.current == 200 }
        let workout = try Controls.preset(.workout)
        try saves.updateControls(workout)
        saves.capture(values[2])
        #expect(saves.latest.controls == workout && saves.latest.restart == values[2])
        await writer.finish(.success(()))
        try await wait { await writer.current == 300 }
        let records = await writer.records
        #expect(records.count == 2 && records[1].controls == workout)
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved == saves.latest)
    }

    @Test func settingsSaveBeforeAnySongAndSurviveTheFirstCapture() async throws {
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        let relax = try Controls.preset(.relax)
        try saves.updateControls(relax)
        try await wait { await writer.isWaiting }
        #expect(await writer.records.first?.restart == nil)
        #expect(await writer.records.first?.controls == relax)
        let captured = try intents()[0]
        saves.capture(captured)
        await writer.finish(.success(()))
        try await wait { await writer.current == 100 }
        #expect(await writer.records.last?.controls == relax)
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved?.restart == captured)
        #expect(saves.lastSaved?.controls == relax)
    }

    @Test func discardingThePlaceSupersedesAnOlderFailedWrite() async throws {
        let values = try intents()
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        let settings = try Controls.preset(.workout)
        saves.restored(try ListeningRecord(controls: settings, restart: values[0]))
        saves.capture(values[1])
        try await wait { await writer.current == 200 }
        saves.discardRestart()
        #expect(saves.latest.controls == settings && saves.latest.restart == nil)
        await writer.finish(.failure(CheckpointWriteError.failed))
        try await wait { saves.failed && !saves.busy }
        saves.retry()
        try await wait { await writer.isWaiting }
        #expect(await writer.records.last?.controls == settings)
        #expect(await writer.records.last?.restart == nil)
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved == saves.latest && !saves.failed)
    }

}

private enum CheckpointWriteError: Error { case failed }

private actor CheckpointWriteGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var current: UInt64?
    private(set) var frames: [UInt64] = []

    private(set) var records: [ListeningRecord] = []
    var isWaiting: Bool { continuation != nil }

    func write(_ record: ListeningRecord) async throws {
        try #require(continuation == nil)
        records.append(record)
        if let restart = record.restart { frames.append(restart.canonicalFrame) }
        current = record.restart?.canonicalFrame
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<Void, any Error>) {
        let pending = continuation
        continuation = nil
        current = nil
        pending?.resume(with: result)
    }
}
