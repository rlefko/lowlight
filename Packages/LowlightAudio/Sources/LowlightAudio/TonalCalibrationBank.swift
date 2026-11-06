// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

/// The calibration rows describe the original tonal assets and their manifest ordering.
/// Verify them once per preparer, on the setup thread before any calibrated rack is admitted.
final class TonalCalibrationBank: @unchecked Sendable {
    private let bank: URL
    private let assets: [(String, String)]
    private let matches: Bool
    private let lock = NSLock()
    private var verified = false

    init(bank: URL, guitarManifest: Data, sampleManifest: Data, assets: [(String, String)]) {
        self.bank = bank
        self.assets = assets
        matches =
            Self.digest(guitarManifest)
            == "1af1164e3d02bf340015e9a79427c40247b34fc87f1da3991e6c3468ad726faf"
            && Self.digest(sampleManifest)
                == "f7c139c9d6c2f26bda5d6864e44361bf3848a12a736960c64921d3e4baa303e3"
    }

    func verify() throws {
        try lock.withLock {
            guard !verified else { return }
            guard matches, assets.count == 42 else { throw SamplePreparationError.invalidBank }
            for (asset, expected) in assets {
                let file = try FileHandle(forReadingFrom: bank.appendingPathComponent(asset))
                defer { try? file.close() }
                guard let bytes = try file.read(upToCount: 2_000_001), bytes.count <= 2_000_000,
                    Self.digest(bytes) == expected
                else { throw SamplePreparationError.invalidBank }
            }
            verified = true
        }
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
