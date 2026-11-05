// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import LowlightAudio
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
        let deadline = Date().addingTimeInterval(30)
        while !(await condition()) {
            try #require(Date() < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func serialWritesCoalesceToTheNewestIntentEvenWhenReturningToAnOldPosition() async throws
    {
        let values = try intents()
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.restored(values[0])
        saves.submit(values[0])
        #expect(!saves.busy && !saves.failed)
        saves.submit(values[1])
        try await wait { await writer.current == 200 }
        saves.submit(values[2])
        saves.submit(values[3])
        saves.submit(values[0])
        #expect(saves.busy)
        await writer.finish(.success(()))
        try await wait { await writer.current == 100 }
        #expect(saves.lastSaved == values[1])
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved == values[0] && !saves.failed)
        #expect(await writer.frames == [200, 100])
        saves.submit(values[0])
        #expect(!saves.busy)
    }

    @Test func failedWritesRetainTheLatestPendingPositionUntilExplicitRetry() async throws {
        let values = try intents()
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.restored(values[0])
        saves.submit(values[1])
        try await wait { await writer.current == 200 }
        saves.submit(values[2])
        await writer.finish(.failure(CheckpointWriteError.failed))
        try await wait { saves.failed && !saves.busy }
        #expect(saves.lastSaved == values[0])
        saves.submit(values[3])
        #expect(!saves.busy && saves.failed)
        #expect(await writer.frames == [200])
        saves.retry()
        try await wait { await writer.current == 400 }
        saves.retry()
        saves.submit(values[3])
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(!saves.failed && saves.lastSaved == values[3])
        #expect(await writer.frames == [200, 400])
    }

    @Test func failureWithNoNewerCaptureRetriesTheSameCheckpoint() async throws {
        let saved = try intents()[0]
        let writer = CheckpointWriteGate()
        let saves = ListeningSaves(write: { try await writer.write($0) })
        saves.submit(saved)
        try await wait { await writer.current == 100 }
        await writer.finish(.failure(CheckpointWriteError.failed))
        try await wait { saves.failed && !saves.busy }
        saves.retry()
        try await wait { await writer.current == 100 }
        await writer.finish(.success(()))
        try await wait { !saves.busy }
        #expect(saves.lastSaved == saved && !saves.failed)
        #expect(await writer.frames == [100, 100])
    }
}

private enum CheckpointWriteError: Error { case failed }

private actor CheckpointWriteGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var current: UInt64?
    private(set) var frames: [UInt64] = []

    func write(_ intent: SessionRestartIntent) async throws {
        try #require(continuation == nil)
        frames.append(intent.canonicalFrame)
        current = intent.canonicalFrame
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<Void, any Error>) {
        let pending = continuation
        continuation = nil
        current = nil
        pending?.resume(with: result)
    }
}
