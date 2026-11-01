// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let bodyRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

struct SongBodyLoudnessTests {
    private struct LayoutValue: Codable, Equatable {
        var id: String?
        let originFrame: UInt64
        let inputFrames, bodyStartFrame, bodyEndFrame: UInt32
        func make() throws -> SongRenderLayout {
            try SongRenderLayout(
                frameOrigin: originFrame, inputFrames: inputFrames,
                bodyFrames: bodyStartFrame..<bodyEndFrame)
        }
        init(_ layout: SongRenderLayout, id: String? = nil) {
            self.id = id
            originFrame = layout.frameOrigin
            inputFrames = layout.inputFrames
            bodyStartFrame = layout.bodyFrames.lowerBound
            bodyEndFrame = layout.bodyFrames.upperBound
        }
    }
    private struct Scalar: Codable {
        let inputFrames, blockCount, absoluteGateCount, relativeGateCount: Int
        let measurable: Bool
        let lufs: Double
    }
    private struct Manifest: Decodable {
        struct Row: Decodable {
            let id, kind: String
            let expected: LayoutValue
            let chainIndex, scheduleIndex: Int?
            let incomingOriginSeconds: Double?
        }
        struct Case: Decodable {
            struct Recipe: Decodable {
                struct Level: Decodable {
                    let start: Int
                    let scale: Float
                }
                let kind: String
                let levels: [Level]?
                let file: String?
            }
            let id, file: String
            let layout: LayoutValue
            let outside: [Float]
            let recipe: Recipe
            let expected: Scalar
        }
        let layouts: [Row]
        let cases: [Case]
    }
    private func manifest() throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            Manifest.self,
            from: Data(
                contentsOf: bodyRoot.appendingPathComponent(
                    "tests/fixtures/song-body-v9/manifest.json")))
    }

    @Test func frozenLayoutsPreserveTheirDeclaredClockPolicy() throws {
        struct Plans: Decodable {
            struct Chain: Decodable { let plans: [SongPlan] }
            let chains: [Chain]
        }
        let plans = try JSONDecoder().decode(
            Plans.self,
            from: Data(
                contentsOf: bodyRoot.appendingPathComponent(
                    "tests/fixtures/planning-v1/events.json")))
        let rows = try manifest().layouts
        try #require(rows.count == 78 && rows.filter { $0.kind == "native" }.count == 5)
        var records: [LayoutValue] = []
        for row in rows {
            let layout: SongRenderLayout
            if row.kind == "native" {
                let chain = plans.chains[try #require(row.chainIndex)].plans
                let index = try #require(row.scheduleIndex)
                var incoming: SongTransition?
                var schedule: SongSchedule?
                for position in 0...index {
                    if position == index, let origin = row.incomingOriginSeconds {
                        incoming = try SongTransition(
                            from: chain[position - 1], to: chain[position], startSeconds: origin)
                    }
                    schedule = try SongSchedule(
                        song: chain[position], successor: chain[position + 1], incoming: incoming)
                    incoming = schedule?.outgoing
                }
                let native = try #require(schedule)
                layout = try SongRenderLayout(schedule: native)
                if row.id == "native-1" {
                    // The native form fits, but its extra five-second render tail does not.
                    let maximum: Int64 = 1 << 52
                    let duration = try native.outgoing.ramp.seconds(at: 16) - native.startSeconds
                    let origin = Double(maximum - 32_000) / 32_000 - duration
                    let incoming = try SongTransition(
                        from: chain[index - 1], to: chain[index], startSeconds: origin)
                    let edge = try SongSchedule(
                        song: chain[index], successor: chain[index + 1], incoming: incoming)
                    let end = try edge.outgoing.ramp.frame(at: 16)
                    #expect(end <= maximum && maximum - end < 160_000)
                    #expect(throws: SongRenderLayoutError.self) {
                        try SongRenderLayout(schedule: edge)
                    }
                }
            } else {
                layout = try row.expected.make()
            }
            #expect(LayoutValue(layout) == row.expected)
            records.append(LayoutValue(layout, id: row.id))
        }
        try export(records, file: "layouts.json")
    }

    @Test func frozenSelectedBodiesMatchOriginalMeter() throws {
        let cases = try manifest().cases
        try #require(cases.count == 4)
        for item in cases {
            let layout = try item.layout.make()
            let input = try inputs(item)
            let meter = try SongBodyLoudness(layout: layout)
            let first = try measure(meter, input: input, partitions: [Int(layout.inputFrames)])
            meter.reset()
            #expect(try measure(meter, input: input, partitions: [1, 17, 127, 1_023]) == first)
            #expect(first.totalBlocks == item.expected.blockCount)
            #expect(first.absoluteBlocks == item.expected.absoluteGateCount)
            #expect(first.gatedBlocks == item.expected.relativeGateCount)
            #expect((first.integratedLUFS != nil) == item.expected.measurable)
            if item.expected.measurable {
                #expect(abs(try #require(first.integratedLUFS) - item.expected.lufs) <= 1e-5)
            }
            try export(
                Scalar(
                    inputFrames: layout.bodyFrames.count, blockCount: Int(first.totalBlocks),
                    absoluteGateCount: Int(first.absoluteBlocks),
                    relativeGateCount: Int(first.gatedBlocks),
                    measurable: first.integratedLUFS != nil, lufs: first.integratedLUFS ?? 0),
                file: item.file)
        }
    }

    @Test func outsideBodyValidationPreservesFloatingPointState() throws {
        var saved = fenv_t()
        fegetenv(&saved)
        defer { fesetenv(&saved) }
        let meter = try SongBodyLoudness(
            layout: SongRenderLayout(
                frameOrigin: 0, inputFrames: 12_802, bodyFrames: 1..<12_801))
        for mode in [FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO] {
            fesetround(mode)
            feclearexcept(FE_ALL_EXCEPT)
            feraiseexcept(FE_DIVBYZERO)
            let before = fetestexcept(FE_ALL_EXCEPT)
            let invalid = [Float(bitPattern: 0x7f80_0001), Float(0)]
            #expect(!invalid.withUnsafeBufferPointer { meter.process($0) })
            #expect(meter.position == 0)
            let tiny = [Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude]
            #expect(tiny.withUnsafeBufferPointer { meter.process($0) })
            #expect(fetestexcept(FE_ALL_EXCEPT) == before && fegetround() == mode)
            meter.reset()
        }
    }

    @Test func finiteLayoutRejectsInvalidRangesAndOverflow() throws {
        let maximum: UInt64 = 1 << 52
        let invalid: [(UInt64, UInt32, Range<UInt32>)] = [
            (0, 0, 0..<0), (0, 12_800, 0..<0), (0, 12_800, 0..<12_799),
            (0, 12_800, 1..<12_801), (0, SongMix.maximumInputFrames + 1, 0..<12_800),
            (maximum - 12_799, 12_800, 0..<12_800), (.max, 12_800, 0..<12_800),
        ]
        for (origin, count, body) in invalid {
            #expect(throws: SongRenderLayoutError.self) {
                try SongRenderLayout(frameOrigin: origin, inputFrames: count, bodyFrames: body)
            }
        }
        let edge = try SongRenderLayout(
            frameOrigin: maximum - 12_800, inputFrames: 12_800, bodyFrames: 0..<12_800)
        #expect(edge.frameOrigin + UInt64(edge.inputFrames) == maximum)
        let longest = try SongRenderLayout(
            frameOrigin: 0, inputFrames: SongMix.maximumInputFrames,
            bodyFrames: 0..<SongLoudnessMeter.maximumBodyFrames)
        #expect(longest.bodyFrames.count == Int(SongMix.maximumInputFrames))
    }

    @Test func wholeCallValidationPreservesBodyAndCursor() throws {
        let layout = try SongRenderLayout(
            frameOrigin: 73, inputFrames: 16_000, bodyFrames: 1_600..<14_400)
        let input: [Float] = (0..<16_000).flatMap { frame in
            frame / 16 % 2 == 0 ? [0.125, -0.0625] : [-0.125, 0.0625]
        }
        let meter = try SongBodyLoudness(layout: layout)
        let expected = try measure(meter, input: input, partitions: [16_000])
        meter.reset()
        #expect(meter.layout == layout && meter.position == 0)
        #expect([Float]().withUnsafeBufferPointer { meter.process($0) })
        try input.withUnsafeBufferPointer { source in
            try #require(meter.process(UnsafeBufferPointer(rebasing: source[..<200])))
            #expect(throws: SongBodyLoudnessError.self) { try meter.finish() }
            #expect(!meter.process(UnsafeBufferPointer(rebasing: source[..<1])))
            #expect(!meter.process(source))
            var invalid = Array(source[200...])
            for index in [0, (1_600 - 100) * 2, invalid.count - 1] {
                let original = invalid[index]
                for value: Float in [
                    .nan, .infinity, -.infinity, SongBodyLoudness.inputLimit.nextUp,
                    -SongBodyLoudness.inputLimit.nextUp,
                ] {
                    invalid[index] = value
                    #expect(!invalid.withUnsafeBufferPointer { meter.process($0) })
                    #expect(meter.position == 100)
                }
                invalid[index] = original
            }
            // Complete the body without the tail: finish must not finalize early.
            try #require(meter.process(UnsafeBufferPointer(rebasing: source[200..<28_800])))
            #expect(meter.position == 14_400)
            #expect(throws: SongBodyLoudnessError.self) { try meter.finish() }
            try #require(meter.process(UnsafeBufferPointer(rebasing: source[28_800...])))
        }
        #expect([Float]().withUnsafeBufferPointer { meter.process($0) })
        #expect(try meter.finish() == expected)
        #expect(try meter.finish() == expected)
        #expect(![Float]().withUnsafeBufferPointer { meter.process($0) })
        #expect(!input.withUnsafeBufferPointer { meter.process($0) })
        meter.reset()
        #expect(try measure(meter, input: input, partitions: [1, 17, 127, 1_023]) == expected)
    }

    @Test func onlyBodyEntersFreshKWeightingAndPreparesOneGain() throws {
        let layout = try SongRenderLayout(
            frameOrigin: 0, inputFrames: 16_000, bodyFrames: 1_600..<14_400)
        var input = [Float](repeating: 0.75, count: 32_000)
        input.replaceSubrange(3_200..<28_800, with: repeatElement(Float(0), count: 25_600))
        let meter = try SongBodyLoudness(layout: layout)
        let silence = try measure(meter, input: input, partitions: [16_000])
        #expect(silence.integratedLUFS == nil && silence.gatedBlocks == 0)
        #expect(throws: SongFixedGainError.self) { try SongFixedGain(measurement: silence) }
        for frame in 1_600..<14_400 {
            input[frame * 2] = (frame - 1_600) / 16 % 2 == 0 ? 0.125 : -0.125
            input[frame * 2 + 1] = -0.5 * input[frame * 2]
        }
        let direct = try SongLoudnessMeter(bodyFrames: 12_800)
        try input.withUnsafeBufferPointer {
            try #require(direct.process(UnsafeBufferPointer(rebasing: $0[3_200..<28_800])))
        }
        let expected = try direct.finish()
        // Each partition pattern crosses the lower, upper, or both boundaries.
        for partitions in [[16_000], [1_599, 2, 12_798, 2], [1_600, 12_800, 1_600], [127]] {
            meter.reset()
            let result = try measure(meter, input: input, partitions: partitions)
            #expect(result == expected)
            let gain = try SongFixedGain(measurement: result)
            #expect(abs(gain.decibels + 20.5 + (try #require(result.integratedLUFS))) <= 1e-12)
        }
    }

    private func inputs(_ item: Manifest.Case) throws -> [Float] {
        let layout = try item.layout.make()
        try #require(item.outside.count == 2)
        let count = Int(layout.inputFrames)
        let start = Int(layout.bodyFrames.lowerBound)
        let end = Int(layout.bodyFrames.upperBound)
        var input = (0..<count).flatMap { _ in item.outside }
        if let file = item.recipe.file {
            let data = try Data(contentsOf: bodyRoot.appendingPathComponent(file))
            try #require(data.count == (end - start) * 8)
            data.withUnsafeBytes { bytes in
                for index in 0..<(end - start) * 2 {
                    input[start * 2 + index] = Float(
                        bitPattern: UInt32(
                            littleEndian:
                                bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                }
            }
        } else {
            for frame in start..<end {
                let local = frame - start
                let scale =
                    item.recipe.kind == "silence"
                    ? Float(0)
                    : item.recipe.levels?.last(where: { $0.start <= local })?.scale ?? 1
                input[frame * 2] = (Float(local % 31 - 15) / 64) * scale
                input[frame * 2 + 1] = (Float(local % 17 - 8) / 32) * scale
            }
        }
        return input
    }

    private func export<T: Encodable>(_ value: T, file: String) throws {
        guard let output = ProcessInfo.processInfo.environment["LOWLIGHT_AUDIO_OUTPUT"] else {
            return
        }
        let directory = URL(fileURLWithPath: output).appendingPathComponent("song-body")
            .resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(file).resolvingSymlinksInPath()
            .standardizedFileURL
        try #require(
            directory.path.hasPrefix(bodyRoot.path + "/.build/")
                && destination.path.hasPrefix(directory.path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: destination, options: .atomic)
    }

    private func measure(_ meter: SongBodyLoudness, input: [Float], partitions: [Int]) throws
        -> SongLoudnessMeasurement
    {
        try input.withUnsafeBufferPointer { source in
            var frame = 0
            var block = 0
            while frame < input.count / 2 {
                let end = min(frame + partitions[block % partitions.count], input.count / 2)
                try #require(
                    meter.process(UnsafeBufferPointer(rebasing: source[frame * 2..<end * 2])))
                frame = end
                block += 1
            }
        }
        return try meter.finish()
    }
}
