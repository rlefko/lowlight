// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import CPreparationTestSupport
import Foundation
import LowlightPlanning
import Testing

@testable import LowlightAudio

private let preparationRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private enum PreparationFailure: Error { case expected }
private final class PreparationInvocation {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

@Suite(.serialized)
struct PreparationModeTests {
    @Test func modeMatrixRestoresFlagsAcrossValuesNestedNativeCallsAndThrows() throws {
        let halfway = Double(bitPattern: 0x3ff0_0000_1000_0000)
        let small = Float(bitPattern: 0x0080_0000)
        for rounding in UInt32(0)..<4 {
            for flush in 0..<ll_test_flush_modes() {
                for flags in [false, true] {
                    let result = try environment(rounding, flush, flags) {
                        try PreparationMode.perform {
                            let words = arithmetic(halfway, small)
                            ll_test_raise_flags()
                            let before = ll_test_fp_state()
                            do {
                                try PreparationMode.perform { throw PreparationFailure.expected }
                            } catch PreparationFailure.expected {}
                            let gain = ll_song_gain_create(-20.5)
                            ll_song_gain_destroy(gain)
                            let after = ll_test_fp_state()
                            return (
                                words, ll_test_preparation_mode(), gain != nil,
                                before.control == after.control && before.status == after.status
                            )
                        }
                    }
                    #expect(result.0 == [0x3f80_0000, 0x0040_0000])
                    #expect(result.1 && result.2 && result.3)
                    #expect(throws: PreparationFailure.self) {
                        try environment(rounding, flush, flags) {
                            try PreparationMode.perform {
                                ll_test_raise_flags()
                                throw PreparationFailure.expected
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func realPreparationRetainsExactBodiesLayersAndSubnormals() throws {
        let preparer = try bank()
        let cases: [(TonalInstrument, Int, Int, Double)] = [
            (.guitar, 58, 1, 0.5), (.piano, 58, 0, 0.5), (.bass, 31, 1, 0.5),
            (.kick, 0, 1, 0.5), (.snare, 1, 0, 0.5),
            (.hat, 0, 0, 0.719999999), (.hat, 0, 0, 0.72), (.shaker, 0, 3, 0.5),
        ]
        var hats: [[UInt32]] = []
        for (index, item) in cases.enumerated() {
            let expected = try preparer.prepare(
                instrument: item.0, note: item.1, roundRobin: item.2, warmth: 0.785,
                velocity: item.3)
            let actual = try environment(UInt32(index % 3 + 1), ll_test_flush_modes() - 1, true) {
                try preparer.prepare(
                    instrument: item.0, note: item.1, roundRobin: item.2, warmth: 0.785,
                    velocity: item.3)
            }
            let words = actual.samples.map(\.bitPattern)
            #expect(
                actual.channels == expected.channels && words == expected.samples.map(\.bitPattern))
            if item.0 == .hat { hats.append(words) }
            if item.0 == .bass {
                // Exact accepted PR25 body-31-1 tail; gradual preparation must retain all 16.
                #expect(words.filter { $0 & 0x7f80_0000 == 0 && $0 & 0x007f_ffff != 0 }.count == 16)
                #expect(
                    Array(words[70312..<70328]) == [
                        0x807e_f8b6, 0x8067_e9d4, 0x8051_da52, 0x803c_c49e,
                        0x8028_a31d, 0x8015_7030, 0x8003_2632, 0x000e_4083,
                        0x001e_c997, 0x002e_7ab0, 0x003d_596f, 0x004b_6b73,
                        0x0058_b654, 0x0065_3fa1, 0x0071_0ce1, 0x007c_2390,
                    ])
            }
        }
        #expect(hats.count == 2 && hats[0] != hats[1])
    }

    @Test func canonicalEventsKeepFloatConversionAndHatKeysAcrossConstructionModes() throws {
        let preparer = try bank()
        // Canonical integer endpoints and Double values are constructed before hostile entry.
        let events = try score()
        #expect(Float(events[2].velocity).bitPattern == Float(events[3].velocity).bitPattern)
        let reference = try TonalVoiceMixer(
            preparer: preparer, events: events, warmth: 0.785, busEnergy: 0.63)
        let actual = try environment(2, ll_test_flush_modes() - 1, true) {
            try TonalVoiceMixer(preparer: preparer, events: events, warmth: 0.785, busEnergy: 0.63)
        }
        #expect(actual.preparedBytes == reference.preparedBytes)
        let same =
            try render(actual, partitions: [1, 257, 511])
            == render(reference, partitions: [512])
        #expect(same)
        #expect(actual.stolenVoices == 0 && actual.droppedEvents == 0)
    }

    @Test func validationAndDecodeThrowsRestoreTheCaller() throws {
        let preparer = try bank()
        let negative = Double(bitPattern: 0x8000_0000_0000_0001)
        let signaling = Double(bitPattern: 0x7ff0_0000_0000_0001)
        for (warmth, velocity) in [(0.78, negative), (signaling, 0.5)] {
            do {
                _ = try environment(1, ll_test_flush_modes() - 1, true) {
                    try preparer.prepare(
                        instrument: .hat, note: 0, roundRobin: 0,
                        warmth: warmth, velocity: velocity)
                }
                Issue.record("Invalid preparation accepted")
            } catch SamplePreparationError.invalidRequest {}
        }
        for (warmth, energy) in [(0.78, negative), (signaling, 0.5)] {
            do {
                _ = try environment(3, ll_test_flush_modes() - 1, false) {
                    try TonalVoiceMixer(
                        preparer: preparer, events: [], warmth: warmth, busEnergy: energy)
                }
                Issue.record("Invalid mixer accepted")
            } catch VoiceMixerError.invalidScore {}
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["sample_manifest.json", "electric_guitar_manifest.json"] {
            try FileManager.default.copyItem(
                at: preparationRoot.appendingPathComponent("Lowlight/SoundBank/" + name),
                to: temporary.appendingPathComponent(name))
        }
        let missing = try TonalSamplePreparer(bankURL: temporary)
        let events = try score()
        // Failure follows native handle/configuration setup and must unwind its cleanup too.
        #expect(throws: (any Error).self) {
            try environment(1, ll_test_flush_modes() - 1, false) {
                try TonalVoiceMixer(preparer: missing, events: events, warmth: 0.78, busEnergy: 0.5)
            }
        }
    }

    @inline(never)
    private func arithmetic(_ value: Double, _ small: Float) -> [UInt32] {
        [Float(value).bitPattern, (small * 0.5).bitPattern]
    }

    private func environment<Value>(
        _ rounding: UInt32, _ flush: UInt32, _ flags: Bool,
        _ body: () throws -> Value
    ) throws -> Value {
        try withoutActuallyEscaping(body) { work in
            var result: Result<Value, any Error>?
            let invocation = PreparationInvocation { result = Result(catching: work) }
            let audit = withExtendedLifetime(invocation) {
                ll_test_environment(
                    rounding, flush, flags,
                    { context in
                        guard let context else { return }
                        Unmanaged<PreparationInvocation>.fromOpaque(context).takeUnretainedValue()
                            .run()
                    }, Unmanaged.passUnretained(invocation).toOpaque())
            }
            // Assertions execute after C has restored the test thread's initial environment.
            #expect(audit.expected.control == audit.actual.control)
            #expect(audit.expected.status == audit.actual.status)
            return try #require(result).get()
        }
    }

    private func bank() throws -> TonalSamplePreparer {
        try TonalSamplePreparer(
            bankURL: preparationRoot.appendingPathComponent("Lowlight/SoundBank"))
    }

    private func score() throws -> [NoteEvent] {
        let records: [[String: Any]] = ["guitar", "piano", "hat", "hat"].enumerated().map {
            index, kind in
            [
                "formatVersion": 1, "instrument": kind, "role": index < 2 ? "chord" : "drum",
                "articulation": "normal", "note": index < 2 ? 58 : 0, "roundRobin": 0,
                "beat": 0,
                "velocity": index < 2
                    ? Double(bitPattern: 0x3fe0_0000_1000_0000)
                    : (index == 2 ? 0.719999999 : 0.72),
                "pan": Double(bitPattern: 0xbfd0_0000_1000_0000),
                "startFrame": index * 1024, "gateEndFrame": index * 1024 + 4096,
                "releaseEndFrame": index * 1024 + 8192,
            ]
        }
        return try JSONDecoder().decode(
            [NoteEvent].self, from: JSONSerialization.data(withJSONObject: records))
    }

    private func render(_ mixer: TonalVoiceMixer, partitions: [Int]) throws -> [UInt32] {
        var output: [UInt32] = []
        var position = 0
        var block = 0
        var buffer = [RhythmBusFrame](repeating: RhythmBusFrame(), count: partitions.max() ?? 1)
        while position < 16_384 {
            let count = min(partitions[block % partitions.count], 16_384 - position)
            try buffer.withUnsafeMutableBufferPointer {
                try #require(
                    mixer.renderBuses(into: UnsafeMutableBufferPointer(rebasing: $0[..<count])))
            }
            for frame in buffer.prefix(count) {
                output += [
                    frame.guitar.0, frame.guitar.1, frame.piano.0, frame.piano.1,
                    frame.bass.0, frame.bass.1, frame.drums.0, frame.drums.1, frame.duck,
                ].map(\.bitPattern)
            }
            position += count
            block += 1
        }
        return output
    }
}
