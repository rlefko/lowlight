// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import CLowlightDSP
import Foundation

/// Shared immutable metadata. Native mixers borrow this table for their complete lifetime.
/// First access happens during prepared rack construction, before callback publication.
final class LiveTonalCalibration: @unchecked Sendable {
    static let shared = Result { try LiveTonalCalibration() }
    let handle: OpaquePointer

    private init() throws {
        guard let url = Bundle.module.url(forResource: "warmth-v1", withExtension: "f32") else {
            throw SamplePreparationError.invalidBank
        }
        let data = try Data(contentsOf: url)
        guard data.count == 40_400,
            TonalCalibrationBank.digest(data)
                == "eabf569987e7e511f46b59bc9db5da26b3d3e158d46a9e8619a9a5c3d7ca1333"
        else { throw SamplePreparationError.invalidBank }
        let gains = data.withUnsafeBytes { bytes in
            (0..<10_100).map { index in
                Float(
                    bitPattern: UInt32(
                        littleEndian: bytes.loadUnaligned(
                            fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
        guard
            let handle = gains.withUnsafeBufferPointer({
                ll_tonal_calibration_create($0.baseAddress, UInt32($0.count))
            })
        else {
            throw SamplePreparationError.invalidBank
        }
        self.handle = handle
    }

    deinit { ll_tonal_calibration_destroy(handle) }
}
