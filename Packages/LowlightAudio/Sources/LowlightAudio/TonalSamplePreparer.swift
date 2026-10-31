// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import Foundation

public enum TonalInstrument: String, Codable, Sendable { case guitar, piano, bass }

public enum SamplePreparationError: Error { case invalidRequest, invalidBank, invalidAudio }

/// Owned interleaved PCM at the canonical 32 kHz rate, before the note envelope/pan.
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
    private let guitar, piano, bass: [Entry]

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
    }

    private static func manifest(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 262_145), data.count <= 262_144 else {
            throw SamplePreparationError.invalidBank
        }
        return data
    }

    public func prepare(instrument: TonalInstrument, note: Int, roundRobin: Int, warmth: Double)
        throws
        -> PreparedTonalSample
    {
        guard (0...10).contains(roundRobin), warmth.isFinite else {
            throw SamplePreparationError.invalidRequest
        }
        if instrument == .bass { return try prepareBass(note: note, roundRobin: roundRobin) }
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
