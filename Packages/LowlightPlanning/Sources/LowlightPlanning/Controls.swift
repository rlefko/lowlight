// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum PlanningError: Error, Equatable {
    case invalidControls, invalidCatalog, invalidCheckpoint, unsupportedVersion
}

public enum Preset: String, CaseIterable, Sendable {
    case focus = "Focus"
    case relax = "Relax"
    case commute = "Commute"
    case workout = "Workout"
    case reflective = "Reflective"
}

public struct Controls: Codable, Equatable, Sendable {
    public var energy, mood, warmth, space, texture, variation: Double
    public var tempo: Double?

    public init(
        energy: Double = 0.35, mood: Double = 0.15, warmth: Double = 0.78,
        space: Double = 0.44, texture: Double = 0.09, variation: Double = 0.55,
        tempo: Double? = nil
    ) {
        self.energy = energy
        self.mood = mood
        self.warmth = warmth
        self.space = space
        self.texture = texture
        self.variation = variation
        self.tempo = tempo
    }

    public func normalized() throws -> Self {
        guard [energy, mood, warmth, space, texture, variation].allSatisfy(\.isFinite),
            tempo?.isFinite != false
        else { throw PlanningError.invalidControls }
        return Self(
            energy: energy.clamped(0...1), mood: mood.clamped(-1...1),
            warmth: warmth.clamped(0...1), space: space.clamped(0...1),
            texture: texture.clamped(0...1), variation: variation.clamped(0...1),
            tempo: tempo.map { $0.clamped(60...100) })
    }

    public static func preset(_ preset: Preset) throws -> Self {
        guard let controls = try Grammar.bundled().presets[preset.rawValue]
        else { throw PlanningError.invalidCatalog }
        return controls
    }
}

extension Double {
    fileprivate func clamped(_ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
