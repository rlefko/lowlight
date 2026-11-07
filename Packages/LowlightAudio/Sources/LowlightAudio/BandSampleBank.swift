// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// These are sampled articulations, independent of harmonic bus and event gain.
enum BandVoice: String, CaseIterable, Sendable {
    case electricSoft, electricAccent, vibraphone, tenorLong, tenorShort

    func sampleKey(note: Int) -> UInt32 {
        // The native bank reserves 20 pitches per articulation, beginning at key 256.
        let start: UInt32 =
            switch self {
            case .electricSoft: 256
            case .electricAccent: 276
            case .vibraphone: 296
            case .tenorLong: 316
            case .tenorShort: 336
            }
        return start + UInt32(note - 50)
    }
}

struct BandSampleBank: Sendable {
    private struct Entry: Decodable, Sendable {
        let asset, voice, assetSha256: String
        let rootMidi, channels, frames, sampleRate, bytes: Int
    }
    private struct Manifest: Decodable { let entries: [Entry] }
    private let root: URL
    // Legacy scores and palette comparisons can run with only the original bank.
    private let entries: Result<[Entry], any Error>

    init(root: URL) {
        self.root = root
        entries = Result {
            let url = root.appendingPathComponent("band/manifest.json")
            let data = try Self.read(url, limit: 24_576)
            guard
                TonalCalibrationBank.digest(data)
                    == "ebb29c50cc3ca956de6ec82e29081a11f46cf5beace7e128ec4441fdd3f55d0c"
            else { throw SamplePreparationError.invalidBank }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Manifest.self, from: data).entries
        }
    }

    func prepare(_ voice: BandVoice, note: Int, warmth: Double, live: Bool) throws
        -> PreparedTonalSample
    {
        guard (50...69).contains(note) else { throw SamplePreparationError.invalidRequest }
        let matches = try entries.get().filter { $0.voice == voice.rawValue }
        guard let entry = matches.min(by: { abs($0.rootMidi - note) < abs($1.rootMidi - note) }),
            abs(entry.rootMidi - note) <= 3, entry.channels == 1, entry.sampleRate == 32_000,
            (1...115_200).contains(entry.frames), (1...262_144).contains(entry.bytes)
        else { throw SamplePreparationError.invalidBank }
        let file = root.appendingPathComponent(entry.asset).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/band/"),
            try TonalCalibrationBank.digest(Self.read(file, limit: entry.bytes))
                == entry.assetSha256
        else { throw SamplePreparationError.invalidBank }
        let decoded = try TonalSamplePreparer.decode(file, frames: entry.frames, channels: 1)
        var samples = SampleProcessing.transpose(
            decoded, channels: 1, semitones: note - entry.rootMidi)
        if !live {
            let bin = TonalSamplePreparer.quantizedWarmth(warmth)
            SampleProcessing.filter(
                &samples, channels: 1, cutoff: 4200 - 2500 * bin, highpass: false)
        }
        return PreparedTonalSample(samples: samples, channels: 1)
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        guard let data = try stream.read(upToCount: limit + 1), data.count <= limit else {
            throw SamplePreparationError.invalidBank
        }
        return data
    }
}
