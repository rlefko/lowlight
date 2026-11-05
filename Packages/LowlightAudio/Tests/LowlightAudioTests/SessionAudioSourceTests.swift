// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

/// Diagnostics are worker-owned and may be inspected only after join().
final class SourceTestScore: @unchecked Sendable {
    let preparer: TonalSamplePreparer
    let origins: [UInt64]
    let frames: UInt32
    let successorEntered = DispatchSemaphore(value: 0)
    let successorResume = DispatchSemaphore(value: 0)
    private let holdSuccessor: Bool
    private var index = 0
    var pool: SongPreparationPool?
    weak var session: PreparedSession?
    weak var worker: SessionPreparationWorker?

    init(
        origins: [UInt64] = [0, 16_017], frames: UInt32 = 50_003,
        holdSuccessor: Bool = false
    ) throws {
        self.origins = origins
        self.frames = frames
        self.holdSuccessor = holdSuccessor
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        preparer = try TonalSamplePreparer(
            bankURL: root.appendingPathComponent("Lowlight/SoundBank"))
    }

    func makeWorker() throws -> SessionPreparationWorker {
        let value = try SessionPreparationWorker { token in
            let result = try PreparedSession(
                frameCount: self.frames, preparation: .concurrent, cancellation: token,
                accepted: { self.index += 1 },
                prepare: { pool, cancellation in
                    try #require(self.index < self.origins.count)
                    if self.holdSuccessor && self.index == 2 {
                        self.successorEntered.signal()
                        try #require(self.successorResume.wait(timeout: .now() + 30) == .success)
                    }
                    self.pool = pool
                    let song = try PreparedSongPairTests().make(
                        pool, self.preparer, origin: self.origins[self.index],
                        cancellation: cancellation)
                    return (
                        song,
                        self.index + 1 < self.origins.count
                            ? UInt32(self.origins[self.index + 1]) : self.frames
                    )
                })
            self.session = result
            return result
        }
        worker = value
        return value
    }
}

private final class OfflineSourceGraph {
    let engine = AVAudioEngine()
    let source: SessionAudioSource
    private let buffer: AVAudioPCMBuffer
    private var stopped = false

    init(_ source: SessionAudioSource, rate: Double = 32_000) throws {
        self.source = source
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        buffer = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096))
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 4096)
        engine.attach(source.node)
        engine.connect(source.node, to: engine.mainMixerNode, format: output)
        engine.prepare()
        try engine.start()
    }

    func pull(_ frames: Int) throws -> [Float] {
        let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
        try #require(status == .success && buffer.frameLength == frames)
        let channels = try #require(buffer.floatChannelData)
        return (0..<frames).flatMap { [channels[0][$0], channels[1][$0]] }
    }

    func stop() {
        guard !stopped else { return }
        engine.stop()
        engine.disconnectNodeOutput(source.node)
        engine.detach(source.node)
        stopped = true
    }

    deinit { stop() }
}

struct SessionAudioSourceTests {
    @Test func offline32kMatchesIndependentAudioAcrossPausesIrregularPullsAndEOF() async throws {
        let score = try SourceTestScore()
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: Int(score.frames))
        let worker = try score.makeWorker()
        defer {
            worker.requestStop()
            worker.join()
        }
        let source = try SessionAudioSource(worker: worker)
        #expect(source.status == .ready && source.position == 0)
        #expect(source.format.sampleRate == 32_000 && source.format.channelCount == 2)
        #expect(source.format.commonFormat == .pcmFormatFloat32 && source.format.isInterleaved)
        let graph = try OfflineSourceGraph(source)
        defer { graph.stop() }
        var actual: [Float] = []
        let sizes = [1, 159, 160, 161, 257, 1023, 4096]
        var block = 0
        while actual.count / 2 < score.frames {
            let count = min(sizes[block % sizes.count], Int(score.frames) - actual.count / 2)
            actual += try graph.pull(count)
            #expect(source.position == actual.count / 2)
            block += 1
            if block == 3 || block == 12 {
                graph.engine.pause()
                #expect(worker.suspend())
                let deadline = Date().addingTimeInterval(30)
                while worker.status != .suspended {
                    try #require(Date() < deadline)
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect(source.position == actual.count / 2 && !graph.engine.isRunning)
                #expect(worker.resume())
                try graph.engine.start()
            }
        }
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(graph.engine.manualRenderingSampleTime == Int64(score.frames))
        #expect(source.status == .finished && !source.isFaulted)
        #expect(try graph.pull(257).allSatisfy { $0 == 0 })
        #expect(source.position == score.frames)
        graph.stop()
        worker.requestStop()
        worker.join()
        #expect(score.session?.stolenVoices == 0 && score.session?.droppedEvents == 0)
    }

    @Test func offlineDeviceRatesPreserveFiniteStereoAndDeviceDuration() throws {
        let reference = try SourceTestScore(frames: 51_200)
        let expected = try ConcurrentSessionTests().independent(
            reference.preparer, origins: reference.origins, count: Int(reference.frames))
        func energy(_ pcm: [Float], _ frames: Range<Int>, _ channel: Int) -> Double {
            frames.reduce(0) { $0 + Double(pcm[2 * $1 + channel]) * Double(pcm[2 * $1 + channel]) }
        }
        // Before overlap, the original left-panned voice must retain its channel ordering.
        #expect(energy(expected, 3200..<6400, 0) > energy(expected, 3200..<6400, 1))
        for rate in [44_100.0, 48_000.0] {
            let score = try SourceTestScore(frames: reference.frames)
            let worker = try score.makeWorker()
            defer {
                worker.requestStop()
                worker.join()
            }
            let source = try SessionAudioSource(worker: worker)
            let graph = try OfflineSourceGraph(source, rate: rate)
            defer { graph.stop() }
            let frames = Int(score.frames) * Int(rate) / 32_000
            var output: [Float] = []
            while output.count / 2 < frames {
                output += try graph.pull(min(1023, frames - output.count / 2))
            }
            #expect(graph.engine.manualRenderingSampleTime == Int64(frames))
            #expect(graph.engine.manualRenderingFormat.sampleRate == rate)
            #expect(source.format.sampleRate == 32_000 && source.format.isInterleaved)
            #expect(output.allSatisfy(\.isFinite) && output.contains { abs($0) > 0.001 })
            let window = (Int(rate) / 10)..<(Int(rate) / 5)
            #expect(energy(output, window, 0) > energy(output, window, 1))
            let tail = try graph.pull(4096)
            #expect(tail.allSatisfy(\.isFinite) && tail.suffix(2048).allSatisfy { $0 == 0 })
            #expect(
                source.position == score.frames && source.status == .finished && !source.isFaulted)
        }
    }

    @Test func latePreparationInsertsDeviceSilenceWithoutAdvancingMusicalTime() throws {
        let score = try SourceTestScore(
            origins: [0, 16_017, 50_001], frames: 70_017, holdSuccessor: true)
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: Int(score.frames))
        let worker = try score.makeWorker()
        defer {
            score.successorResume.signal()
            worker.requestStop()
            worker.join()
        }
        let source = try SessionAudioSource(worker: worker)
        let graph = try OfflineSourceGraph(source)
        defer { graph.stop() }
        let deadline = Date().addingTimeInterval(30)
        var logical: [Float] = []
        while source.status != .waitingForPreparation {
            try #require(Date() < deadline)
            let before = source.position
            let output = try graph.pull(1023)
            let written = Int(source.position - before)
            logical += output.prefix(2 * written)
            #expect(output.dropFirst(2 * written).allSatisfy { $0 == 0 })
        }
        try #require(score.successorEntered.wait(timeout: .now() + 30) == .success)
        #expect(source.position == 50_001 - PeakProtector.latencyFrames)
        let before = source.position
        let deviceTime = graph.engine.manualRenderingSampleTime
        #expect(try graph.pull(257).allSatisfy { $0 == 0 })
        #expect(
            source.position == before && graph.engine.manualRenderingSampleTime == deviceTime + 257)
        score.successorResume.signal()
        while worker.status == .preparing {
            try #require(Date() < deadline)
            _ = sched_yield()
        }
        #expect(worker.lastError == nil)
        while source.position < source.frameCount {
            try #require(Date() < deadline)
            let before = source.position
            let output = try graph.pull(161)
            let written = Int(source.position - before)
            logical += output.prefix(2 * written)
            #expect(output.dropFirst(2 * written).allSatisfy { $0 == 0 })
        }
        #expect(logical.map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(source.status == .finished && !source.isFaulted)
    }
}
