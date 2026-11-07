// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

#if LOWLIGHT_PLAYBACK_COMPARISON
    import AVFAudio
    import AudioToolbox
    import CryptoKit
    import Foundation

    struct ComparisonFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct ComparisonFixture: Decodable {
        static let sampleRate = 32_000
        static let seed: UInt64 = 91_031
        static let requiredRecipe = "evolving-2.band-1"
        let performanceRecipe: String?
        let schemaVersion: Int
        let preset: String
        let seed: UInt64
        let codec: String
        let sampleRate: Int
        let channels: Int
        let durationSeconds: Int
        let frames: UInt64
        let pcmSha256: String
        let aacSha256: String

        static func load(from directory: URL) throws -> Self {
            let manifest = directory.appending(path: "manifest.json")
            let reference = directory.appending(path: "reference.m4a")
            let attributes = try manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 65_536
            else { throw ComparisonFailure("Invalid reference manifest file.") }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let fixture = try decoder.decode(Self.self, from: Data(contentsOf: manifest))
            guard fixture.schemaVersion == 2, fixture.performanceRecipe == requiredRecipe else {
                throw ComparisonFailure(
                    "Reference recipe has changed. Prepare and stage a current fixture.")
            }
            guard fixture.seed == Self.seed, fixture.preset == "Focus",
                fixture.codec == "aac", fixture.sampleRate == Self.sampleRate,
                fixture.channels == 2,
                fixture.durationSeconds > 0,
                fixture.frames / UInt64(Self.sampleRate) == UInt64(fixture.durationSeconds),
                fixture.frames % UInt64(Self.sampleRate) == 0,
                validDigest(fixture.pcmSha256), validDigest(fixture.aacSha256)
            else {
                throw ComparisonFailure(
                    "Manifest must describe the matched 32 kHz stereo Focus reference.")
            }
            guard try reference.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { throw ComparisonFailure("Missing reference.m4a.") }
            guard try sha256(of: reference) == fixture.aacSha256 else {
                throw ComparisonFailure("AAC SHA-256 does not match manifest.json.")
            }
            let audio = try AVAudioFile(forReading: reference)
            let format = audio.fileFormat
            guard format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                format.channelCount == 2, format.sampleRate == Double(Self.sampleRate),
                audio.length > 0, abs(Double(fixture.frames) - Double(audio.length)) <= 1024
            else { throw ComparisonFailure("AAC format or duration does not match manifest.json.") }
            return fixture
        }

        static func sha256(of url: URL) throws -> String {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let bytes = try file.read(upToCount: 256 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                digest.update(data: bytes)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private static func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64
                && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
#endif
