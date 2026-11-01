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
    @Test func preparedAirReplaysOnIOSWithLocalPhaseAndAbsoluteFades() throws {
        let origin: UInt64 = 3_200_017
        let fades = SongRackFades(
            tonalOutStartFrame: Double(origin + 3200), tonalOutEndFrame: Double(origin + 12800),
            rhythmOutFrame: Double(origin + 8000))
        let air = try QuietAir(
            takeSeed: 1_278_560_406, inputFrames: 19_200, frameOrigin: origin, texture: 0.09,
            rackFades: fades)
        let carrier = [Float](repeating: 0.01, count: 38_400)
        var output = carrier
        #expect(output.withUnsafeMutableBufferPointer { air.add(to: $0) })
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite && output.prefix(25_600).contains { $0 != 0.01 })
        #expect(output.suffix(12_800).allSatisfy { $0 == 0.01 })
        air.reset()
        var replay = carrier
        #expect(replay.withUnsafeMutableBufferPointer { air.add(to: $0) })
        #expect(output == replay)
        let local = try QuietAir(
            takeSeed: 1_278_560_406, inputFrames: 19_200, frameOrigin: 0, texture: 0.09,
            rackFades: SongRackFades(
                tonalOutStartFrame: 3200, tonalOutEndFrame: 12800, rhythmOutFrame: 8000))
        var localOutput = carrier
        #expect(localOutput.withUnsafeMutableBufferPointer { local.add(to: $0) })
        #expect(localOutput == output)
    }

    @Test func bundledInstrumentVoicesRenderOnIOS() throws {
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
               "round_robin":0,"release":0.05,"articulation":"normal"},
              {"instrument":"kick","note":0,"beat":0,"time":0,"local_time":0,
               "duration":0.1,"velocity":0.5,"role":"drum","pan":0,
               "round_robin":1,"release":0,"articulation":"normal"},
              {"instrument":"snare","note":1,"beat":0,"time":0,"local_time":0,
               "duration":0.1,"velocity":0.4,"role":"drum","pan":-0.1,
               "round_robin":1,"release":0,"articulation":"normal"},
              {"instrument":"hat","note":0,"beat":0,"time":0,"local_time":0,
               "duration":0.1,"velocity":0.8,"role":"drum","pan":0.2,
               "round_robin":1,"release":0,"articulation":"normal"},
              {"instrument":"shaker","note":0,"beat":0,"time":0,"local_time":0,
               "duration":0.1,"velocity":0.3,"role":"drum","pan":0.4,
               "round_robin":3,"release":0,"articulation":"normal"}
            ]
            """.utf8)
        let mixer = try TonalVoiceMixer(
            preparer: TonalSamplePreparer(bankURL: bank),
            events: NoteEvent.importReference(score), warmth: 0.78, busEnergy: 0.35)
        var output = [Float](repeating: .nan, count: 99_200 * 2)
        #expect(output.withUnsafeMutableBufferPointer { mixer.render(into: $0) })
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite && output.contains { abs($0) > 0.001 })
        // Other voices and recorded bass touch have ended; the bass oscillator continues.
        let sustained = output[(95_000 * 2)..<(96_000 * 2)].contains { abs($0) > 0.0001 }
        #expect(sustained)
        let silent = output[(97_600 * 2)...].allSatisfy { $0 == 0 }
        #expect(silent && mixer.activeVoices == 0 && mixer.position == 99_200)
        #expect(mixer.stolenVoices == 0 && mixer.droppedEvents == 0)
        mixer.reset()
        var buses = [RhythmBusFrame](repeating: RhythmBusFrame(), count: 99_200)
        #expect(buses.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
        #expect(buses[0].duck == Float(0.945) && buses[8960].duck == 1)
        #expect(buses.contains { abs($0.drums.0) > 0.001 && $0.duck < 1 })
        #expect(buses[95_000..<96_000].contains { abs($0.bass.0) > 0.0001 })
        let busFinite = buses.allSatisfy { frame in
            [
                frame.guitar.0, frame.guitar.1, frame.piano.0, frame.piano.1,
                frame.bass.0, frame.bass.1, frame.drums.0, frame.drums.1, frame.duck,
            ]
            .allSatisfy(\.isFinite)
        }
        #expect(busFinite && mixer.activeVoices == 0 && mixer.position == 99_200)
        try verifyHarmonicGlue(buses)
        try verifyRackFades(bank: bank, score: score)
    }

    private func verifyRackFades(bank: URL, score: Data) throws {
        let mixer = try TonalVoiceMixer(
            preparer: TonalSamplePreparer(bankURL: bank),
            events: NoteEvent.importReference(score), warmth: 0.78, busEnergy: 0.35,
            rackFades: SongRackFades(
                tonalOutStartFrame: 1000, tonalOutEndFrame: 4000, rhythmOutFrame: 3200))
        var buses = [RhythmBusFrame](repeating: RhythmBusFrame(), count: 6400)
        #expect(buses.withUnsafeMutableBufferPointer { mixer.renderBuses(into: $0) })
        #expect(buses[4000...].allSatisfy { $0.guitar == (0, 0) && $0.piano == (0, 0) })
        #expect(buses[3200...].allSatisfy { $0.bass == (0, 0) })
        #expect(buses[3200..<3300].contains { $0.drums != (0, 0) })
        #expect(buses[3200].duck < 1 && mixer.activeVoices > 0)
        let glue = try HarmonicGlue(inputFrames: UInt64(buses.count), focus: .guitar)
        var compressed = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: buses.count)
        #expect(
            compressed.withUnsafeMutableBufferPointer { destination in
                buses.withUnsafeBufferPointer { glue.process($0, into: destination) }
            })
        let room = try StereoRoom(space: 0.70, warmth: 0.78)
        var reverberated = compressed
        #expect(
            reverberated.withUnsafeMutableBufferPointer { destination in
                compressed.withUnsafeBufferPointer { room.process($0, into: destination) }
            })
        let tail = (4000 + HarmonicGlue.latencyFrames)..<buses.count
        #expect(compressed[tail].allSatisfy { $0.tonal == (0, 0) })
        #expect(reverberated[tail].contains { $0.tonal != (0, 0) })
    }

    private func verifyHarmonicGlue(_ buses: [RhythmBusFrame]) throws {
        let glue = try HarmonicGlue(inputFrames: UInt64(buses.count), focus: .piano)
        let latency = HarmonicGlue.latencyFrames
        var output = [HarmonicGlueFrame](
            repeating: HarmonicGlueFrame(), count: buses.count + latency)
        output.withUnsafeMutableBufferPointer { destination in
            #expect(
                buses.withUnsafeBufferPointer {
                    glue.process(
                        $0, into: UnsafeMutableBufferPointer(rebasing: destination[..<buses.count]))
                })
            #expect(
                glue.drain(
                    into: UnsafeMutableBufferPointer(rebasing: destination[buses.count...]))
                    == latency)
        }
        let neutral = output.prefix(latency).allSatisfy {
            $0.tonal.0 == 0 && $0.tonal.1 == 0 && $0.bass.0 == 0 && $0.bass.1 == 0
                && $0.drums.0 == 0 && $0.drums.1 == 0 && $0.duck == 1
        }
        #expect(neutral)
        let finite = output.allSatisfy {
            [$0.tonal.0, $0.tonal.1, $0.bass.0, $0.bass.1, $0.drums.0, $0.drums.1, $0.duck]
                .allSatisfy(\.isFinite)
        }
        #expect(finite && output.contains { abs($0.tonal.0) > 0.001 })
        let aligned = buses.indices.allSatisfy { index in
            let actual = output[index + latency]
            let input = buses[index]
            return actual.bass == input.bass && actual.drums == input.drums
                && actual.duck == input.duck
        }
        #expect(aligned)
        try verifyStereoRoom(output)
    }

    private func verifyStereoRoom(_ input: [HarmonicGlueFrame]) throws {
        let room = try StereoRoom(space: 0.70, warmth: 0.78)
        var output = [HarmonicGlueFrame](repeating: HarmonicGlueFrame(), count: input.count)
        #expect(
            output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { room.process($0, into: destination) }
            })
        let finite = output.allSatisfy {
            [$0.tonal.0, $0.tonal.1, $0.bass.0, $0.bass.1, $0.drums.0, $0.drums.1, $0.duck]
                .allSatisfy(\.isFinite)
        }
        let aligned = input.indices.allSatisfy {
            output[$0].bass == input[$0].bass && output[$0].drums == input[$0].drums
                && output[$0].duck == input[$0].duck
        }
        #expect(finite && aligned)
        #expect(output.prefix(HarmonicGlue.latencyFrames).allSatisfy { $0.tonal == (0, 0) })
        #expect(input.suffix(1600).allSatisfy { $0.tonal == (0, 0) })
        // Voices have retired, but the causal room still contains their release tails.
        #expect(output.suffix(1600).contains { $0.tonal.0 != 0 || $0.tonal.1 != 0 })
        try verifySongMix(output)
        try verifyPeakProtection(output)
    }

    private func verifySongMix(_ delayed: [HarmonicGlueFrame]) throws {
        // The glue drain is already present; consume exactly N logical song frames.
        let input = Array(delayed.dropFirst(HarmonicGlue.latencyFrames))
        let mix = try SongMix(
            takeSeed: 1_278_560_406, inputFrames: UInt32(input.count), frameOrigin: 0,
            texture: 0.09,
            rackFades: SongRackFades(
                tonalOutStartFrame: 70_000, tonalOutEndFrame: 80_000, rhythmOutFrame: 75_000))
        var output = [Float](repeating: .nan, count: input.count * 2)
        #expect(
            output.withUnsafeMutableBufferPointer { destination in
                input.withUnsafeBufferPointer { mix.process($0, into: destination) }
            })
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite && output.contains { abs($0) > 0.001 })
        #expect(output.suffix(3200).contains { $0 != 0 })
        mix.reset()
        var replay = [Float](repeating: .nan, count: output.count)
        input.withUnsafeBufferPointer { source in
            replay.withUnsafeMutableBufferPointer { destination in
                for start in stride(from: 0, to: input.count, by: 127) {
                    let end = min(start + 127, input.count)
                    #expect(
                        mix.process(
                            UnsafeBufferPointer(rebasing: source[start..<end]),
                            into: UnsafeMutableBufferPointer(
                                rebasing: destination[(start * 2)..<(end * 2)])))
                }
            }
        }
        #expect(replay == output)
    }

    private func verifyPeakProtection(_ buses: [HarmonicGlueFrame]) throws {
        // Driven diagnostic input, not the future production mixing/gain-analysis stage.
        let input: [Float] = buses.flatMap { frame -> [Float] in
            let left = (frame.tonal.0 + frame.bass.0) * frame.duck + frame.drums.0
            let right = (frame.tonal.1 + frame.bass.1) * frame.duck + frame.drums.1
            return [left * 16, right * 16]
        }
        let protector = try PeakProtector(mode: .song)
        let latency = PeakProtector.latencyFrames
        var output = [Float](repeating: .nan, count: input.count + latency * 2)
        output.withUnsafeMutableBufferPointer { destination in
            #expect(
                input.withUnsafeBufferPointer {
                    protector.process(
                        $0, into: UnsafeMutableBufferPointer(rebasing: destination[..<input.count]))
                })
            #expect(
                protector.drain(
                    into: UnsafeMutableBufferPointer(
                        rebasing: destination[input.count...])) == latency)
        }
        let finite = output.allSatisfy(\.isFinite)
        #expect(finite)
        #expect(output.prefix((HarmonicGlue.latencyFrames + latency) * 2).allSatisfy { $0 == 0 })
        let inputPeak = input.map { abs($0) }.max() ?? 0
        let outputPeak = output.map { abs($0) }.max() ?? 0
        #expect(inputPeak > 0.6 && outputPeak > 0 && outputPeak < inputPeak)
        #expect(input.indices.allSatisfy { abs(output[$0 + latency * 2]) <= abs(input[$0]) })
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
