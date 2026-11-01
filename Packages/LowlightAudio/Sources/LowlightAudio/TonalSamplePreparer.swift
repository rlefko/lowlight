// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation

public enum TonalInstrument: String, Codable, Sendable {
    case guitar, piano, bass, kick, snare, hat, shaker
}

public enum SamplePreparationError: Error { case invalidRequest, invalidBank, invalidAudio }

/// Owned interleaved PCM at 32 kHz, before event gain/pan. Percussion includes fixed hit decay.
public struct PreparedTonalSample: Sendable {
    public let samples: [Float]
    public let channels: Int
    public var frames: Int { samples.count / channels }
}

/// Performs bounded, one-note-at-a-time work off the audio callback. No sample cache.
public struct TonalSamplePreparer: Sendable {
    private struct Entry: Decodable, Sendable {
        let asset: String
        let frames, channels, sampleRate: Int
        let rootMidi: Int?
        let instrument: String?
        let roundRobin: Int?
    }
    private struct GuitarManifest: Decodable { let entries: [Entry] }
    private let bankURL: URL
    private let guitar, piano, bass, percussion: [Entry]

    public init(bankURL: URL) throws {
        guard bankURL.isFileURL else { throw SamplePreparationError.invalidBank }
        self.bankURL = bankURL.resolvingSymlinksInPath().standardizedFileURL
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let guitarData = try Self.manifest(
            self.bankURL.appendingPathComponent("electric_guitar_manifest.json"))
        let sampleData = try Self.manifest(
            self.bankURL.appendingPathComponent("sample_manifest.json"))
        guitar = try decoder.decode(GuitarManifest.self, from: guitarData).entries
        let samples = try decoder.decode([Entry].self, from: sampleData)
        piano = samples.filter {
            $0.instrument == "piano" && $0.asset.contains("_v1_")
        }
        bass = samples.filter { $0.instrument == "bass" && $0.asset.contains("_v1_") }
        percussion = samples.filter {
            $0.instrument == "kick" || $0.instrument == "shaker"
                || ($0.instrument == "snare" && $0.asset.contains("_stick_"))
                || ($0.instrument == "hat" && $0.asset.contains("_HitC_")
                    && ($0.asset.contains("_v1_") || $0.asset.contains("_v2_")))
        }
        guard guitar.count == 32, piano.count == 10,
            bass.compactMap(\.rootMidi) == [34, 34, 49, 49, 38, 38, 28, 28, 44, 44],
            Set(bass.map(\.asset)).count == 10,
            bass.allSatisfy({ $0.channels == 1 && $0.frames <= 80_000 })
        else {
            throw SamplePreparationError.invalidBank
        }
        for entry in guitar + piano + bass {
            let path = self.bankURL.appendingPathComponent(entry.asset).resolvingSymlinksInPath()
                .standardizedFileURL.path
            guard let root = entry.rootMidi,
                entry.asset.hasPrefix("assets/"), path.hasPrefix(self.bankURL.path + "/assets/"),
                entry.sampleRate == 32_000, (1...192_000).contains(entry.frames),
                (1...2).contains(entry.channels), (0...127).contains(root)
            else { throw SamplePreparationError.invalidBank }
        }
        guard Set(percussion.map(\.asset)).count == 12,
            percussion.filter({ $0.instrument == "hat" && $0.asset.contains("_v1_") }).count == 2,
            percussion.filter({ $0.instrument == "hat" && $0.asset.contains("_v2_") }).count == 2
        else { throw SamplePreparationError.invalidBank }
        for (kind, count, frames) in [
            ("kick", 2, 25_600...25_600), ("snare", 2, 22_400...22_400),
            ("hat", 4, 4_160...38_400), ("shaker", 4, 1...5_419),
        ] {
            let entries = percussion.filter { $0.instrument == kind }
            guard entries.count == count else { throw SamplePreparationError.invalidBank }
            for entry in entries {
                let path = self.bankURL.appendingPathComponent(entry.asset)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path
                guard entry.asset.hasPrefix("assets/\(kind)/"),
                    path.hasPrefix(self.bankURL.path + "/assets/\(kind)/"),
                    entry.rootMidi == nil, entry.channels == 1, entry.sampleRate == 32_000,
                    frames.contains(entry.frames)
                else { throw SamplePreparationError.invalidBank }
            }
        }
    }

    private static func manifest(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 262_145), data.count <= 262_144 else {
            throw SamplePreparationError.invalidBank
        }
        return data
    }

    /// Velocity selects the closed-hat layer; continuous event gain remains in the renderer.
    /// Uses round-to-nearest with gradual underflow, restoring caller FP state on return.
    public func prepare(
        instrument: TonalInstrument, note: Int, roundRobin: Int, warmth: Double,
        velocity: Double = 0.5
    ) throws -> PreparedTonalSample {
        try PreparationMode.perform {
            try prepareInMode(
                instrument: instrument, note: note, roundRobin: roundRobin,
                warmth: warmth, velocity: velocity)
        }
    }

    // Keep numeric work inside the synchronous callback, including validation.
    @inline(never)
    private func prepareInMode(
        instrument: TonalInstrument, note: Int, roundRobin: Int, warmth: Double,
        velocity: Double
    ) throws -> PreparedTonalSample {
        guard (0...10).contains(roundRobin), warmth.isFinite,
            velocity.isFinite, (0...1).contains(velocity)
        else {
            throw SamplePreparationError.invalidRequest
        }
        switch instrument {
        case .bass: return try prepareBass(note: note, roundRobin: roundRobin)
        case .guitar, .piano: break
        default:
            return try preparePercussion(
                instrument: instrument, note: note, roundRobin: roundRobin, velocity: velocity)
        }
        guard (50...69).contains(note) else { throw SamplePreparationError.invalidRequest }
        let pool = instrument == .guitar ? guitar : piano
        // Manifest order is significant for piano ties (58 selects 60, not 56).
        // Guitar ties in this range select the lower root, as in the frozen bank.
        let roots =
            instrument == .guitar
            ? pool.compactMap(\.rootMidi).sorted() : pool.compactMap(\.rootMidi)
        guard let root = roots.min(by: { abs($0 - note) < abs($1 - note) }),
            let entry = pool.first(where: {
                $0.rootMidi == root && (instrument == .piano || $0.roundRobin == roundRobin % 4)
            })
        else { throw SamplePreparationError.invalidBank }
        guard abs(root - note) <= 2 else { throw SamplePreparationError.invalidBank }
        var samples = try decode(entry)
        samples = SampleProcessing.transpose(
            samples, channels: entry.channels, semitones: note - root)
        let warm = Self.quantizedWarmth(warmth)
        SampleProcessing.filter(
            &samples, channels: entry.channels, cutoff: instrument == .guitar ? 100 : 90,
            highpass: true)
        SampleProcessing.filter(
            &samples, channels: entry.channels,
            cutoff: instrument == .guitar ? 1300 - 600 * warm : 1200 - 500 * warm, highpass: false)
        guard samples.count >= 28800 * entry.channels else {
            throw SamplePreparationError.invalidAudio
        }
        let body = samples[(3840 * entry.channels)..<(28800 * entry.channels)]
        let rms = sqrt(body.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(body.count))
        let target = instrument == .guitar ? 0.13 : 0.14
        let gain = Float(
            min(
                instrument == .guitar ? 3.2 : 4,
                max(instrument == .guitar ? 0.45 : 0.35, target / max(rms, 1e-8))))
        for index in samples.indices {
            samples[index] *= gain
            if instrument == .piano {
                let time = Double(index / entry.channels) / 32_000
                samples[index] = Float(
                    Double(samples[index]) * (0.60 + 0.40 * (1 - exp(-time / 0.060))))
            }
        }
        guard samples.allSatisfy(\.isFinite) else { throw SamplePreparationError.invalidAudio }
        return PreparedTonalSample(samples: samples, channels: entry.channels)
    }

    private func preparePercussion(
        instrument: TonalInstrument, note: Int, roundRobin: Int, velocity: Double
    ) throws -> PreparedTonalSample {
        guard note == (instrument == .snare ? 1 : 0) else {
            throw SamplePreparationError.invalidRequest
        }
        let layer = velocity < 0.72 ? "_v1_" : "_v2_"
        let pool = percussion.filter {
            $0.instrument == instrument.rawValue && (instrument != .hat || $0.asset.contains(layer))
        }
        guard !pool.isEmpty else { throw SamplePreparationError.invalidBank }
        var samples = try decode(pool[roundRobin % pool.count])
        if instrument == .kick {
            samples = Array(samples.prefix(16_640))
            SampleProcessing.filter(&samples, channels: 1, cutoff: 260, highpass: false, order: 2)
            var frequencySum = 0.0
            for index in samples.indices {
                let time = Double(index) / 32_000
                frequencySum += 48 + 46 * exp(-time / 0.025)
                let phase = frequencySum / 32_000 * 2 * Double.pi
                let sine = sin(phase) * exp(-time / 0.115) * (1 - exp(-time / 0.0015))
                samples[index] *= 0.18
                samples[index] = Float(0.82 * sine + Double(samples[index]))
            }
        } else if instrument == .hat || instrument == .snare {
            SampleProcessing.filter(
                &samples, channels: 1, cutoff: instrument == .hat ? 6500 : 3200,
                highpass: false, order: 2)
            if instrument == .hat { samples = Array(samples.prefix(4_160)) }
            let decay = instrument == .hat ? 0.052 : 0.085
            for index in samples.indices {
                samples[index] = Float(
                    Double(samples[index]) * exp(-Double(index) / 32_000 / decay))
            }
        }
        guard samples.allSatisfy(\.isFinite) else { throw SamplePreparationError.invalidAudio }
        return PreparedTonalSample(samples: samples, channels: 1)
    }

    private func prepareBass(note: Int, roundRobin: Int) throws -> PreparedTonalSample {
        guard (31...57).contains(note) else { throw SamplePreparationError.invalidRequest }
        // Keep manifest order: ties at 31/36 select 34, and 41 selects 38.
        guard let root = bass.compactMap(\.rootMidi).min(by: { abs($0 - note) < abs($1 - note) }),
            let entry = bass.filter({ $0.rootMidi == root }).dropFirst(roundRobin % 2).first,
            (-3...8).contains(note - root)
        else { throw SamplePreparationError.invalidBank }
        var samples = SampleProcessing.transpose(
            try decode(entry), channels: 1, semitones: note - root)
        guard samples.count <= 89_797 else { throw SamplePreparationError.invalidAudio }
        SampleProcessing.filter(&samples, channels: 1, cutoff: 1800, highpass: false, order: 2)
        // The accepted bass assets are mono; averaging their single channel is an identity.
        SampleProcessing.filter(&samples, channels: 1, cutoff: 180, highpass: true, order: 2)
        SampleProcessing.filter(&samples, channels: 1, cutoff: 650, highpass: false, order: 2)
        for index in samples.indices { samples[index] *= 0.08 }
        guard samples.allSatisfy(\.isFinite) else { throw SamplePreparationError.invalidAudio }
        return PreparedTonalSample(samples: samples, channels: 1)
    }

    // Match Python round(value, 2), including binary values on either side of a decimal tie.
    static func quantizedWarmth(_ value: Double) -> Double {
        let value = min(1, max(0, value))
        let bits = value.bitPattern
        let exponent = Int((bits >> 52) & 0x7ff)
        let shift = 1075 - exponent
        guard shift < 64 else { return 0 }
        let numerator = ((bits & 0x000f_ffff_ffff_ffff) | (1 << 52)) * 100
        var rounded = numerator >> shift
        let remainder = numerator & ((1 << shift) - 1)
        let half: UInt64 = 1 << (shift - 1)
        if remainder > half || (remainder == half && rounded % 2 == 1) { rounded += 1 }
        return Double(rounded) / 100
    }

    private func decode(_ entry: Entry) throws -> [Float] {
        try autoreleasepool {
            let file = try AVAudioFile(
                forReading: bankURL.appendingPathComponent(entry.asset),
                commonFormat: .pcmFormatFloat32, interleaved: true)
            guard file.length == Int64(entry.frames), file.processingFormat.sampleRate == 32_000,
                file.processingFormat.channelCount == entry.channels,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(entry.frames)
                )
            else { throw SamplePreparationError.invalidAudio }
            try file.read(into: buffer)
            guard buffer.frameLength == entry.frames, let data = buffer.floatChannelData?[0] else {
                throw SamplePreparationError.invalidAudio
            }
            let samples = Array(
                UnsafeBufferPointer(start: data, count: entry.frames * entry.channels))
            guard samples.allSatisfy(\.isFinite) else { throw SamplePreparationError.invalidAudio }
            return samples
        }
    }
}
