// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightAudio

/// Test synchronization is outside render; the production endpoint never waits on these gates.
private final class SessionBarrier: @unchecked Sendable {
    let arrived = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let preparing = DispatchSemaphore(value: 0)
    let progressed = DispatchSemaphore(value: 0)

    func pause() throws {
        arrived.signal()
        try Self.wait(resume)
    }

    static func wait(_ semaphore: DispatchSemaphore) throws {
        try #require(semaphore.wait(timeout: .now() + 30) == .success)
    }
}

final class SessionConsumer: @unchecked Sendable {
    private let body: @Sendable () throws -> [Float]
    private var thread: pthread_t?
    private var result: Result<[Float], any Error>?
    let finished = DispatchSemaphore(value: 0)

    init(_ body: @escaping @Sendable () throws -> [Float]) throws {
        self.body = body
        let status = pthread_create(
            &thread, nil,
            { pointer in
                let consumer = Unmanaged<SessionConsumer>.fromOpaque(pointer).takeUnretainedValue()
                consumer.result = Result(catching: consumer.body)
                consumer.finished.signal()
                return nil
            }, Unmanaged.passUnretained(self).toOpaque())
        try #require(status == 0)
    }

    func join() throws -> [Float] {
        if let thread {
            try #require(pthread_join(thread, nil) == 0)
            self.thread = nil
        }
        return try #require(result).get()
    }
}

struct ConcurrentSessionTests {
    private enum Injected: Error, Equatable { case preparation }
    private let frames = 70_017

    @Test func twoThreadsPreserveEarlyLateAndTiedSuccessorAudio() throws {
        for (origin, late) in [(UInt64(50_001), false), (50_001, true), (40_001, true)] {
            try exercise(origin: origin, late: late, fail: false, teardown: false)
        }
    }

    @Test func workerFailureReleasesReservationAndRetriesTheSamePendingSong() throws {
        try exercise(origin: 50_001, late: true, fail: true, teardown: false)
    }

    @Test func unconsumedRequestAndReadyResultAreDestroyedOnTheWorker() throws {
        for publish in [false, true] {
            try exercise(origin: 50_001, late: true, fail: false, teardown: true, publish: publish)
        }
    }

    @Test func freeRunningThreadsPublishTwoSuccessorsWithoutExternalHandoffSynchronization() throws
    {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let origins: [UInt64] = [0, 16_017, 50_001, 60_018]
        let count = 90_017
        let expected = try independent(preparer, origins: origins, count: count)
        let worker = pthread_mach_thread_np(pthread_self())
        var pool: SongPreparationPool?
        var index = 0
        var attempts: [Int] = []
        var session: PreparedSession? = try PreparedSession(
            frameCount: UInt32(count), preparation: .concurrent, accepted: { index += 1 },
            prepare: { shared, _ in
                #expect(pthread_mach_thread_np(pthread_self()) == worker)
                try #require(index < origins.count)
                pool = shared
                attempts.append(index)
                let child = try PreparedSongPairTests().make(
                    shared, preparer, origin: origins[index])
                return (
                    child, index + 1 < origins.count ? UInt32(origins[index + 1]) : UInt32(count)
                )
            })
        do {
            let owner = try #require(session)
            let endpoint = try owner.makeRenderEndpoint()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            let consumer = try SessionConsumer {
                #expect(pthread_mach_thread_np(pthread_self()) != worker)
                var output: [Float] = []
                var block = 0
                let sizes = [1, 159, 160, 161, 257, 1023]
                while endpoint.position < count {
                    try #require(ContinuousClock.now < deadline)
                    var buffer = [Float](repeating: .nan, count: 2 * sizes[block % sizes.count])
                    let written = try #require(
                        buffer.withUnsafeMutableBufferPointer { endpoint.render(into: $0) })
                    #expect(buffer.dropFirst(written * 2).allSatisfy { $0 == 0 })
                    output.append(contentsOf: buffer.prefix(written * 2))
                    if written == 0 { _ = sched_yield() }
                    block += 1
                }
                #expect(!endpoint.isFaulted)
                return output
            }
            defer { _ = try? consumer.join() }
            // No per-request semaphore, lock, or barrier publishes readiness to the reader.
            // This semaphore is signaled only after the complete consumer body returns.
            while consumer.finished.wait(timeout: .now()) != .success {
                try #require(ContinuousClock.now < deadline)
                if owner.needsPreparation {
                    try owner.prepareNext()
                    #expect(pool?.reservedRacks == 2 && owner.requiredVoiceSlots == 2)
                } else {
                    _ = sched_yield()
                }
            }
            let actual = try consumer.join()
            #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
            #expect(index == 4 && attempts == [0, 1, 2, 3] && !owner.needsPreparation)
            #expect(owner.stolenVoices == 0 && owner.droppedEvents == 0)
        }
        session = nil
        #expect(pool?.reservedRacks == 0 && pool?.reservedVoiceSlots == 0)
        #expect(pool?.preparedPCMBytes == 0)
    }

    private func exercise(
        origin: UInt64, late: Bool, fail: Bool, teardown: Bool, publish: Bool = true
    ) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
        let origins: [UInt64] = [0, 16_017, origin]
        let expected = teardown ? [] : try independent(preparer, origins: origins)
        let worker = pthread_mach_thread_np(pthread_self())
        let barrier = SessionBarrier()
        var pool: SongPreparationPool?
        weak var oldest: PreparedSong?
        weak var newest: PreparedSong?
        weak var rejected: PreparedSong?
        var index = 0
        var attempts: [Int] = []
        var session: PreparedSession? = try PreparedSession(
            frameCount: UInt32(frames), preparation: .concurrent, accepted: { index += 1 },
            prepare: { shared, _ in
                #expect(pthread_mach_thread_np(pthread_self()) == worker)
                pool = shared
                attempts.append(index)
                if index == 2 {
                    #expect(oldest == nil && shared.reservedRacks == 1)
                    if !late {
                        barrier.preparing.signal()
                        try SessionBarrier.wait(barrier.progressed)
                    }
                }
                let child = try PreparedSongPairTests().make(
                    shared, preparer, origin: origins[index])
                if index == 0 { oldest = child }
                if index == 2 {
                    if fail && attempts.filter({ $0 == 2 }).count == 1 {
                        rejected = child
                        throw Injected.preparation
                    }
                    newest = child
                }
                return (child, index == 0 ? 16_017 : index == 1 ? UInt32(origin) : UInt32(frames))
            })
        do {
            let owner = try #require(session)
            let endpoint = try owner.makeRenderEndpoint()
            #expect(throws: PreparedSessionError.renderEndpointUnavailable) {
                try owner.makeRenderEndpoint()
            }
            var invalid: [Float] = [1, 1]
            #expect(invalid.withUnsafeMutableBufferPointer { owner.render(into: $0) } == nil)
            #expect(invalid == [0, 0])
            let finiteFrames = frames
            let consumer = try SessionConsumer {
                #expect(pthread_mach_thread_np(pthread_self()) != worker)
                var result: [Float] = []
                var block = 0
                let sizes = [1, 159, 160, 161, 257, 1023]
                func pull(to end: UInt32) throws {
                    while endpoint.position < end {
                        let size = min(
                            sizes[block % sizes.count], Int(UInt64(end) - endpoint.position))
                        var output = [Float](repeating: .nan, count: 2 * size)
                        let count = try #require(
                            output.withUnsafeMutableBufferPointer { endpoint.render(into: $0) })
                        try #require(count > 0)
                        #expect(output.dropFirst(count * 2).allSatisfy { $0 == 0 })
                        result.append(contentsOf: output.prefix(count * 2))
                        block += 1
                    }
                }
                try pull(to: 40_001 - 160)
                try barrier.pause()
                if teardown { return result }
                if late {
                    try pull(to: UInt32(origin) - 160)
                    for _ in 0..<3 {
                        var waiting = [Float](repeating: .nan, count: 322)
                        #expect(
                            waiting.withUnsafeMutableBufferPointer { endpoint.render(into: $0) }
                                == 0)
                        #expect(
                            waiting.allSatisfy { $0 == 0 }
                                && endpoint.position == UInt32(origin) - 160)
                    }
                } else {
                    try SessionBarrier.wait(barrier.preparing)
                    try pull(to: 40_001 - 160 + 512)
                    barrier.progressed.signal()
                }
                try barrier.pause()
                try pull(to: UInt32(finiteFrames))
                var eof = [Float](repeating: .nan, count: 514)
                #expect(eof.withUnsafeMutableBufferPointer { endpoint.render(into: $0) } == 0)
                #expect(eof.allSatisfy { $0 == 0 } && !endpoint.isFaulted)
                return result
            }
            defer {
                // Also release every possible test-only wait if a worker assertion throws.
                barrier.preparing.signal()
                barrier.progressed.signal()
                for _ in 0..<3 { barrier.resume.signal() }
                _ = try? consumer.join()
            }
            try SessionBarrier.wait(barrier.arrived)
            #expect(owner.needsPreparation && oldest != nil && pool?.reservedRacks == 2)
            if !teardown {
                barrier.resume.signal()
                if late { try SessionBarrier.wait(barrier.arrived) }
            }
            if fail {
                #expect(throws: Injected.preparation) { try owner.prepareNext() }
                #expect(index == 2 && rejected == nil && oldest == nil && pool?.reservedRacks == 1)
                #expect(owner.needsPreparation)
            }
            if publish {
                try owner.prepareNext()
                #expect(index == 3 && oldest == nil && newest != nil && pool?.reservedRacks == 2)
                if !late { try SessionBarrier.wait(barrier.arrived) }
            }
            barrier.resume.signal()
            let actual = try consumer.join()
            if !teardown {
                #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
                #expect(endpoint.position == frames && !owner.needsPreparation)
                #expect(owner.stolenVoices == 0 && owner.droppedEvents == 0)
            }
            #expect(attempts == (fail ? [0, 1, 2, 2] : publish ? [0, 1, 2] : [0, 1]))
        }
        // Endpoint and consumer have joined/released; the root is still held on this worker.
        #expect(pthread_mach_thread_np(pthread_self()) == worker && pool?.reservedRacks == 2)
        session = nil
        #expect(oldest == nil && newest == nil && pool?.reservedRacks == 0)
        #expect(pool?.reservedVoiceSlots == 0 && pool?.preparedPCMBytes == 0)
    }

    func independent(
        _ preparer: TonalSamplePreparer, origins: [UInt64], count: Int? = nil
    ) throws -> [Float] {
        let frames = count ?? self.frames
        var sum = [Float](repeating: 0, count: 2 * frames)
        let pool = SongPreparationPool()
        for origin in origins {
            let child = try PreparedSongPairTests().make(pool, preparer, origin: origin)
            var pcm = [Float](repeating: .nan, count: 80_002)
            try #require(pcm.withUnsafeMutableBufferPointer { child.render(into: $0) } == 40_001)
            for index in 0..<(2 * min(40_001, frames - Int(origin))) {
                sum[2 * Int(origin) + index] += pcm[index]
            }
        }
        for frame in 0..<frames {
            for channel in 0..<2 {
                let index = 2 * frame + channel
                sum[index] = Float(Double(sum[index]) * min(1, Double(frame) / 12_800))
                sum[index] = Float(Double(sum[index]) * min(1, Double(frames - frame) / 89_600))
            }
        }
        let peak = try PeakProtector(mode: .session)
        var output = [Float](repeating: .nan, count: sum.count + 320)
        try output.withUnsafeMutableBufferPointer { destination in
            try sum.withUnsafeBufferPointer {
                try #require(
                    peak.process(
                        $0, into: UnsafeMutableBufferPointer(rebasing: destination[..<sum.count])))
            }
            try #require(
                peak.drain(into: UnsafeMutableBufferPointer(rebasing: destination[sum.count...]))
                    == 160)
        }
        return Array(output.dropFirst(320))
    }
}
