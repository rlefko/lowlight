// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation
import Testing

@testable import LowlightAudio

private final class ConfigurationGraph {
    let engine = AVAudioEngine()
    var unavailable = false

    init() throws { try setRate(32_000) }

    func setRate(_ rate: Double) throws {
        engine.stop()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    }

    var node: AVAudioSourceNode? {
        autoreleasepool {
            engine.attachedNodes.compactMap { $0 as? AVAudioSourceNode }.first
        }
    }

    func pull(_ frames: Int) throws -> [Float] {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        try #require(engine.renderOffline(AVAudioFrameCount(frames), to: buffer) == .success)
        try #require(buffer.frameLength == frames)
        let channels = try #require(buffer.floatChannelData)
        return (0..<frames).flatMap { [channels[0][$0], channels[1][$0]] }
    }
}

private final class ConfigurationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

struct SessionAudioEngineConfigurationTests {
    @Test func reconnectPreservesTheSameOwnersAndExactCanonicalAudio() throws {
        let score = try SourceTestScore()
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: Int(score.frames))
        let graph = try ConfigurationGraph()
        let owner = try SessionAudioEngine(worker: score.makeWorker(), engine: graph.engine)
        defer { owner.stop() }
        let node = ObjectIdentifier(try #require(graph.node))
        let worker = ObjectIdentifier(try #require(score.worker))
        try owner.play()
        var actual = try graph.pull(257)
        for size in [159, 160, 161, 1023] {
            let position = owner.position
            try owner.reconfigureOutput()
            try owner.reconfigureOutput()
            #expect(owner.state == .paused && owner.position == position)
            #expect(ObjectIdentifier(try #require(graph.node)) == node)
            #expect(ObjectIdentifier(try #require(score.worker)) == worker)
            try owner.play()
            actual += try graph.pull(size)
        }
        while actual.count / 2 < Int(score.frames) {
            actual += try graph.pull(min(4096, Int(score.frames) - actual.count / 2))
        }
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        #expect(owner.position == score.frames && owner.sourceStatus == .finished)
        owner.stop()
        #expect(throws: SessionAudioEngineError.stopped) { try owner.reconfigureOutput() }
        #expect(graph.node == nil && score.worker == nil && score.session == nil)
        #expect(score.pool?.reservedRacks == 0)
    }

    @Test func realOutputRateChangesKeepCanonicalPositionAndResumeExact32kSuffix() throws {
        let score = try SourceTestScore()
        let expected = try ConcurrentSessionTests().independent(
            score.preparer, origins: score.origins, count: Int(score.frames))
        let graph = try ConfigurationGraph()
        let owner = try SessionAudioEngine(worker: score.makeWorker(), engine: graph.engine)
        defer { owner.stop() }
        let node = ObjectIdentifier(try #require(graph.node))
        for rate in [32_000.0, 48_000.0, 44_100.0, 32_000.0] {
            owner.pause()
            let position = owner.position
            try graph.setRate(rate)
            try owner.reconfigureOutput()
            #expect(owner.position == position && owner.state == .paused)
            #expect(ObjectIdentifier(try #require(graph.node)) == node)
            #expect(graph.node?.outputFormat(forBus: 0).sampleRate == rate)
            try owner.play()
            let deviceTime = graph.engine.manualRenderingSampleTime
            let pcm = try graph.pull(2048)
            #expect(pcm.allSatisfy(\.isFinite) && pcm.contains { $0 != 0 })
            #expect(graph.engine.manualRenderingSampleTime - deviceTime == 2048)
            #expect(owner.position > position && owner.position < score.frames)
            if rate == 32_000 {
                #expect(owner.position == position + 2048)
                let slice = expected[Int(position) * 2..<Int(owner.position) * 2]
                #expect(pcm.map(\.bitPattern) == slice.map(\.bitPattern))
            }
        }
        // The converter may have prefetched canonical frames on the prior route. The
        // retained DSP continues exactly from its observed cursor, without rewinding.
        let position = owner.position
        var suffix: [Float] = []
        while owner.position < score.frames {
            suffix += try graph.pull(min(4096, Int(score.frames - owner.position)))
        }
        let expectedSuffix = expected[(Int(position) * 2)...].map(\.bitPattern)
        #expect(suffix.map(\.bitPattern) == expectedSuffix)
        #expect(try graph.pull(4096).allSatisfy { $0 == 0 })
        #expect(owner.sourceStatus == .finished)
    }

    @Test func unavailableOutputRetainsPausedOwnersForExplicitRecovery() throws {
        let score = try SourceTestScore()
        let graph = try ConfigurationGraph()
        let owner = try SessionAudioEngine(
            worker: score.makeWorker(), engine: graph.engine,
            outputFormat: { graph.unavailable ? nil : $0.manualRenderingFormat })
        defer { owner.stop() }
        let node = ObjectIdentifier(try #require(graph.node))
        try owner.play()
        _ = try graph.pull(257)
        graph.unavailable = true
        #expect(throws: SessionAudioEngineError.outputUnavailable) { try owner.reconfigureOutput() }
        #expect(owner.state == .paused && owner.position == 257)
        #expect(ObjectIdentifier(try #require(graph.node)) == node && score.worker != nil)
        graph.unavailable = false
        try owner.reconfigureOutput()
        try owner.play()
        #expect(try graph.pull(257).allSatisfy(\.isFinite))
        #expect(owner.position == 514 && owner.playbackError == nil)
    }

    @Test func configurationObservationFiltersItsEngineAndCancelsSynchronously() throws {
        let score = try SourceTestScore()
        let graph = try ConfigurationGraph()
        let center = NotificationCenter()
        let owner = try SessionAudioEngine(
            worker: score.makeWorker(), engine: graph.engine, notificationCenter: center)
        defer { owner.stop() }
        let counter = ConfigurationCounter()
        var observation: PlaybackAudioSessionObservation? = owner.observeConfigurationChanges {
            counter.increment()
        }
        center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        #expect(counter.value == 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: graph.engine)
        #expect(counter.value == 1)
        observation?.cancel()
        observation?.cancel()
        observation = nil
        center.post(name: .AVAudioEngineConfigurationChange, object: graph.engine)
        #expect(counter.value == 1)
    }
}
