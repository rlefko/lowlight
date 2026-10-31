// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import AVFAudio
import CryptoKit
import Foundation
import LowlightAudio
import LowlightPlanning
import Testing

private struct Inventory: Decodable {
    let schemaVersion, assetCount, compressedBytes: Int
    let pcmEncoding: String
    let assets: [Asset]
    struct Asset: Decodable {
        let path, sha256, pcmSha256, license: String
        let bytes, frames, channels, sampleRate: Int
    }
}

struct SoundBankTests {
    @Test func bundledTonalVoicesRenderOnIOS() throws {
        let bank = try #require(Bundle.main.resourceURL).appendingPathComponent("SoundBank")
        let score = Data(
            """
            [
              {"instrument":"guitar","note":57,"beat":0,"time":0,"local_time":0,
               "duration":0.1,"velocity":0.5,"role":"melody","pan":-0.2,
               "round_robin":0,"release":0.05,"articulation":"normal"},
              {"instrument":"piano","note":60,"beat":0,"time":0,"local_time":0,
               "duration":0.1,"velocity":0.4,"role":"chord","pan":0.2,
               "round_robin":0,"release":0.05,"articulation":"normal"},
              {"instrument":"bass","note":41,"beat":0,"time":0,"local_time":0,
               "duration":3,"velocity":0.5,"role":"bass","pan":0,
               "round_robin":0,"release":0.05,"articulation":"normal"}
            ]
            """.utf8)
        let mixer = try TonalVoiceMixer(
            preparer: TonalSamplePreparer(bankURL: bank),
            events: NoteEvent.importReference(score), warmth: 0.78)
        var output = [Float](repeating: .nan, count: 99_200 * 2)
        #expect(output.withUnsafeMutableBufferPointer { mixer.render(into: $0) })
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite && output.contains { abs($0) > 0.001 })
        // Guitar/piano and recorded bass touch have ended; the bass oscillator continues.
        let sustained = output[(95_000 * 2)..<(96_000 * 2)].contains { abs($0) > 0.0001 }
        #expect(sustained)
        let silent = output[(97_600 * 2)...].allSatisfy { $0 == 0 }
        #expect(silent && mixer.activeVoices == 0 && mixer.position == 99_200)
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
    }

    @Test func bundledTonalSamplesPrepareOnIOS() throws {
        let bank = try #require(Bundle.main.resourceURL).appendingPathComponent("SoundBank")
        let preparer = try TonalSamplePreparer(bankURL: bank)
        for (instrument, note, channels) in [
            (TonalInstrument.guitar, 50, 1), (.piano, 61, 2),
        ] {
            let sample = try preparer.prepare(
                instrument: instrument, note: note, roundRobin: 0, warmth: 0.78)
            #expect(sample.channels == channels)
            #expect(sample.frames > 32_000)
            #expect(sample.samples.count == sample.frames * sample.channels)
            let finite = sample.samples.allSatisfy(\.isFinite)
            #expect(finite)
            #expect(sample.samples.contains { abs($0) > 0.01 })
        }
    }

    @Test func bundledBankDecodesWithoutChangingSamples() throws {
        let app = try #require(Bundle.main.resourceURL)
        let bank = app.appendingPathComponent("SoundBank")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inventory = try decoder.decode(
            Inventory.self, from: Data(contentsOf: bank.appendingPathComponent("inventory.json")))
        #expect(inventory.schemaVersion == 1)
        #expect(inventory.pcmEncoding == "interleaved float32 little-endian")
        #expect(inventory.assetCount == 77 && inventory.assets.count == 77)
        #expect(inventory.compressedBytes == 8_825_758)
        #expect(inventory.assets.reduce(0) { $0 + $1.bytes } == inventory.compressedBytes)
        let paths = Set(inventory.assets.map(\.path))
        #expect(paths.count == 77)
        let metadata: Set<String> = [
            "inventory.json", "manifest-checksums.json", "sample_manifest.json",
            "electric_guitar_manifest.json", "licenses/FreePats_Electric_Jazz_LICENSE.txt",
            "licenses/FreePats_Electric_Jazz_README.txt", "licenses/VCSL_CC0.txt",
            "licenses/VSCO_CC0.txt",
        ]
        #expect(try files(in: bank) == paths.union(metadata))
        let bundled = try files(in: app)
        #expect(
            Set(bundled.filter { $0.hasSuffix(".flac") }) == Set(paths.map { "SoundBank/" + $0 }))
        #expect(
            !bundled.contains { path in
                ["py", "pyc", "wav", "m4a", "mp3", "zip"].contains(
                    URL(fileURLWithPath: path).pathExtension)
                    || path.lowercased().contains("fixtures/")
                    || path.lowercased().contains("reference/")
            })
        for asset in inventory.assets {
            try autoreleasepool {
                let url = bank.appendingPathComponent(asset.path)
                let compressed = try Data(contentsOf: url)
                #expect(compressed.count == asset.bytes, "\(asset.path)")
                #expect(hex(SHA256.hash(data: compressed)) == asset.sha256, "\(asset.path)")
                #expect(asset.license == "CC0-1.0" && asset.sampleRate == 32_000)
                try verifyPCM(url, asset: asset)
            }
        }
    }

    private func verifyPCM(_ url: URL, asset: Inventory.Asset) throws {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        #expect(file.processingFormat.sampleRate == Double(asset.sampleRate), "\(asset.path)")
        try #require(Int(file.processingFormat.channelCount) == asset.channels, "\(asset.path)")
        #expect(file.length == Int64(asset.frames), "\(asset.path)")
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var hash = SHA256()
        var frames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            let pointer = try #require(buffer.floatChannelData?[0])
            let samples = UnsafeBufferPointer(
                start: pointer, count: Int(buffer.frameLength) * asset.channels)
            let finite = samples.allSatisfy(\.isFinite)
            #expect(finite, "\(asset.path)")
            let littleEndianWords = samples.map { $0.bitPattern.littleEndian }
            littleEndianWords.withUnsafeBytes { hash.update(bufferPointer: $0) }
            frames += Int(buffer.frameLength)
        }
        #expect(frames == asset.frames, "\(asset.path)")
        #expect(hex(hash.finalize()) == asset.pcmSha256, "\(asset.path)")
    }

    private func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func files(in directory: URL) throws -> Set<String> {
        let enumerator = try #require(FileManager.default.enumerator(atPath: directory.path))
        return try Set(
            enumerator.allObjects.compactMap { item -> String? in
                let path = try #require(item as? String)
                let values = try directory.appendingPathComponent(path).resourceValues(forKeys: [
                    .isRegularFileKey
                ])
                return values.isRegularFile == true ? path : nil
            })
    }
}
