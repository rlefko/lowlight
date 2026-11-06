// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@main struct Generate {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw SamplePreparationError.invalidRequest }
        let bank = URL(fileURLWithPath: CommandLine.arguments[1])
        let preparer = try TonalSamplePreparer(bankURL: bank)
        try preparer.calibrationBank.verify()
        let data = try PreparationMode.perform {
            var words: [UInt32] = []
            for key in 0..<100 {
                let instrument = key < 80 ? TonalInstrument.guitar : .piano
                let note = 50 + (key < 80 ? key / 4 : key - 80)
                let source = try preparer.tonalSource(
                    instrument: instrument, note: note, roundRobin: key < 80 ? key % 4 : 0)
                let prefix = Array(source.samples.prefix(28800 * source.channels))
                for bin in 0...100 {
                    let warm = Double(bin) / 100
                    var samples = prefix
                    SampleProcessing.filter(
                        &samples, channels: source.channels,
                        cutoff: instrument == .guitar ? 1300 - 600 * warm : 1200 - 500 * warm,
                        highpass: false)
                    let gain = TonalSamplePreparer.calibrationGain(
                        samples, channels: source.channels, instrument: instrument)
                    words.append(gain.bitPattern.littleEndian)
                }
            }
            return words.withUnsafeBytes { Data($0) }
        }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("Generated \(data.count) bytes, SHA-256 \(TonalCalibrationBank.digest(data))")
    }
}
