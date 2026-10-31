// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum EventError: Error, Equatable {
    case invalidEvent, invalidReference, capacityExceeded, unsupportedVersion
}

public struct NoteEvent: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let capacity = 2048

    public enum Instrument: String, Codable, CaseIterable, Sendable {
        case guitar, piano, bass, kick, snare, hat, shaker
        var harmonic: Bool { self == .guitar || self == .piano }
    }
    public enum Role: String, Codable, Sendable {
        case chord, support, melody, answer, bass, drum, ghost
    }
    public enum Articulation: String, Codable, Sendable { case normal, soft, connected }

    public let instrument: Instrument
    public let role: Role
    public let articulation: Articulation
    public let note, roundRobin: Int
    public let beat, velocity, pan: Double
    public let startFrame, gateEndFrame, releaseEndFrame: Int64
    private let version = NoteEvent.formatVersion

    private enum CodingKeys: String, CodingKey {
        case version = "formatVersion"
        case instrument, role, articulation, note, roundRobin, beat, velocity, pan
        case startFrame, gateEndFrame, releaseEndFrame
    }

    init(_ event: EventDraft) throws {
        try event.validate()
        instrument = event.instrument
        role = event.role
        articulation = event.articulation
        note = event.note
        roundRobin = event.roundRobin
        beat = event.beat
        velocity = event.velocity
        pan = event.pan
        startFrame = try MusicalTime.frame(event.time)
        gateEndFrame = try MusicalTime.frame(event.time + event.duration)
        releaseEndFrame = try MusicalTime.frame(event.time + event.duration + event.release)
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The independently frozen, unversioned native fixture records are version 1.
        if values.contains(.version),
            try values.decode(Int.self, forKey: .version) != Self.formatVersion
        {
            throw EventError.unsupportedVersion
        }
        instrument = try values.decode(Instrument.self, forKey: .instrument)
        role = try values.decode(Role.self, forKey: .role)
        articulation = try values.decode(Articulation.self, forKey: .articulation)
        note = try values.decode(Int.self, forKey: .note)
        roundRobin = try values.decode(Int.self, forKey: .roundRobin)
        beat = try values.decode(Double.self, forKey: .beat)
        velocity = try values.decode(Double.self, forKey: .velocity)
        pan = try values.decode(Double.self, forKey: .pan)
        startFrame = try values.decode(Int64.self, forKey: .startFrame)
        gateEndFrame = try values.decode(Int64.self, forKey: .gateEndFrame)
        releaseEndFrame = try values.decode(Int64.self, forKey: .releaseEndFrame)
        try validate()
    }

    public func validate() throws {
        try Self.validateMetadata(
            instrument: instrument, role: role, note: note, roundRobin: roundRobin,
            beat: beat, velocity: velocity, pan: pan)
        guard startFrame >= 0, startFrame < gateEndFrame, gateEndFrame <= releaseEndFrame,
            releaseEndFrame <= 1 << 52, gateEndFrame - startFrame <= 16 * 32_000,
            releaseEndFrame - gateEndFrame <= 5 * 32_000
        else { throw EventError.invalidEvent }
    }

    static func validateMetadata(
        instrument: Instrument, role: Role, note: Int, roundRobin: Int,
        beat: Double, velocity: Double, pan: Double
    ) throws {
        let allowedNote: Bool
        let allowedRole: Bool
        switch instrument {
        case .guitar, .piano:
            allowedNote = (50...69).contains(note)
            allowedRole = [.chord, .support, .melody, .answer].contains(role)
        case .bass:
            allowedNote = (31...57).contains(note)
            allowedRole = role == .bass
        case .kick, .snare, .hat, .shaker:
            allowedNote = note == (instrument == .snare ? 1 : 0)
            allowedRole = role == .drum || role == .ghost
        }
        guard allowedNote, allowedRole, (0...10).contains(roundRobin),
            beat.isFinite, (0..<176).contains(beat), velocity.isFinite,
            (0...1).contains(velocity), pan.isFinite, (-1...1).contains(pan)
        else { throw EventError.invalidEvent }
    }

    /// Imports the reviewed v9 score directly; no native plan or RNG is consulted.
    public static func importReference(_ data: Data) throws -> [Self] {
        guard data.count <= 2_097_152 else { throw EventError.invalidReference }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let drafts = try decoder.decode([EventDraft].self, from: data)
        guard !drafts.isEmpty, drafts.count <= capacity else { throw EventError.invalidReference }
        var previous = -Double.infinity
        let origin = drafts[0].time - drafts[0].localTime
        for event in drafts {
            try event.validate()
            guard event.time >= previous,
                abs(event.time - event.localTime - origin) <= max(1e-9, event.time.ulp * 4)
            else { throw EventError.invalidReference }
            previous = event.time
        }
        return try drafts.map(Self.init)
    }
}

struct EventDraft: Decodable {
    var instrument: NoteEvent.Instrument
    var note: Int
    var beat, time, localTime, duration, velocity: Double
    var role: NoteEvent.Role
    var pan: Double
    var roundRobin: Int
    var release: Double
    var articulation: NoteEvent.Articulation

    func validate() throws {
        try NoteEvent.validateMetadata(
            instrument: instrument, role: role, note: note, roundRobin: roundRobin,
            beat: beat, velocity: velocity, pan: pan)
        guard time.isFinite, time >= 0, localTime.isFinite, localTime >= 0,
            localTime <= time + max(1e-9, time.ulp * 4), duration.isFinite,
            duration > 0, duration <= 16, release.isFinite, (0...5).contains(release)
        else { throw EventError.invalidEvent }
    }
}
