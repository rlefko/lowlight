// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

/// Native RNG version 1: SplitMix64, direct seed, low-tail rejection, top-53-bit Double.
/// Algorithm: Sebastiano Vigna (2015), CC0; https://prng.di.unimi.it/splitmix64.c
struct SeededGenerator: Codable, Equatable, Sendable {
    static let version = 1
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var word = state
        word = (word ^ (word >> 30)) &* 0xbf58_476d_1ce4_e5b9
        word = (word ^ (word >> 27)) &* 0x94d0_49bb_1331_11eb
        return word ^ (word >> 31)
    }

    mutating func index(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        let bound = UInt64(upperBound)
        let threshold = (0 &- bound) % bound
        var word = next()
        while word < threshold { word = next() }
        return Int(word % bound)
    }

    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard text.count == 16, text.allSatisfy({ "0123456789abcdef".contains($0) }),
            let value = UInt64(text, radix: 16)
        else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a 16-digit lowercase RNG state")
        }
        state = value
    }

    func encode(to encoder: any Encoder) throws {
        let digits = String(state, radix: 16)
        var container = encoder.singleValueContainer()
        try container.encode(String(repeating: "0", count: 16 - digits.count) + digits)
    }
}
