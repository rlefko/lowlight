// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import LowlightPlanning

struct GeneratorTests {
    @Test func independentSplitMixVectorsAndOverflow() {
        // Independently calculated from Vigna's reference transition, with direct seed state.
        let vectors: [(UInt64, [UInt64])] = [
            (
                0,
                [
                    0xe220_a839_7b1d_cdaf, 0x6e78_9e6a_a1b9_65f4, 0x06c4_5d18_8009_454f,
                    0xf88b_b8a8_724c_81ec,
                ]
            ),
            (
                .max,
                [
                    0xe4d9_7177_1b65_2c20, 0xe99f_f867_dbf6_82c9, 0x382f_f84c_b272_81e9,
                    0x6d1d_b36c_cba9_82d2,
                ]
            ),
        ]
        for (seed, expected) in vectors {
            var rng = SeededGenerator(seed: seed)
            #expect(expected.map { _ in rng.next() } == expected)
        }
        var unit = SeededGenerator(seed: 0)
        #expect(unit.unit() == 0.8833108082136426)
        var bounded = SeededGenerator(seed: 0)
        let expected = [
            2_459_150_361_376_443_820, 3_348_600_503_766_967_795,
            4_074_553_321_498_378_729, 1_426_408_582_835_774_185,
        ]
        // This bound forces rejected draws; a modulo-only implementation cannot pass.
        #expect(expected.map { _ in bounded.index((1 << 62) + 1) } == expected)
        #expect(bounded.state == 0xb54c_da58_fbbe_e87e)
    }

    @Test func stateEncodingIsCanonicalAndRejectsMalformedInput() throws {
        let encoder = JSONEncoder()
        #expect(try encoder.encode(SeededGenerator(seed: 1)) == Data("\"0000000000000001\"".utf8))
        var rng = SeededGenerator(seed: 91031)
        _ = rng.next()
        var restored = try JSONDecoder().decode(SeededGenerator.self, from: encoder.encode(rng))
        #expect((0..<20).map { _ in rng.next() } == (0..<20).map { _ in restored.next() })
        for invalid in [
            "1", "\"1\"", "\"000000000000000G\"", "\"FFFFFFFFFFFFFFFF\"", "\"10000000000000000\"",
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SeededGenerator.self, from: Data(invalid.utf8))
            }
        }
    }
}
