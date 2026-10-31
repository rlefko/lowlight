// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct Grammar: Decodable, Sendable {
    static let version = 1
    let schemaVersion: Int
    let chords: [String: Voicing]
    let families: [Family]
    let contours: [[Int]]
    let keys, forms: [Int]
    let phraseArcs: [[Double]]
    let names: [String]
    let presets: [String: Controls]

    struct Voicing: Decodable, Sendable {
        let root: Int
        let voices, tops: [Int]
    }
    struct Family: Decodable, Sendable {
        let id, mode: String
        let baseKey: Int
        let progression: [String]
    }
    enum LoadError: Error { case missingResource, invalidCatalog }

    static func bundled() throws -> Grammar {
        guard let url = Bundle.module.url(forResource: "grammar-v1", withExtension: "json") else {
            throw LoadError.missingResource
        }
        let grammar = try JSONDecoder().decode(Grammar.self, from: Data(contentsOf: url))
        guard grammar.schemaVersion == version, grammar.chords.count == 16,
            grammar.families.count == 26, Set(grammar.families.map(\.id)).count == 26,
            grammar.families.filter({ $0.mode == "major" }).count == 14,
            grammar.families.filter({ $0.mode == "minor" }).count == 12,
            grammar.keys == [0, 2, 3, 5, 7, 10], grammar.forms == [28, 36, 36, 44],
            grammar.contours.count == 6,
            grammar.contours.allSatisfy({ $0.count == 8 && $0.allSatisfy { (0...2).contains($0) } }
            ),
            grammar.phraseArcs.count == 3,
            grammar.phraseArcs.allSatisfy({
                $0.count == 4 && $0.allSatisfy { $0.isFinite && (0.8...1.1).contains($0) }
            }),
            grammar.names.count == 12, grammar.names.allSatisfy({ !$0.isEmpty }),
            Set(grammar.presets.keys)
                == Set(["Focus", "Relax", "Commute", "Workout", "Reflective"]),
            grammar.chords.values.allSatisfy({
                $0.voices.count == 4 && $0.tops.count == 4
                    && ([$0.root] + $0.voices + $0.tops).allSatisfy { (0...127).contains($0) }
            }),
            grammar.families.allSatisfy({
                !$0.id.isEmpty && (0...11).contains($0.baseKey) && $0.progression.count == 8
                    && $0.progression.allSatisfy { grammar.chords[$0] != nil }
            })
        else { throw LoadError.invalidCatalog }
        for controls in grammar.presets.values {
            guard try controls.normalized() == controls else { throw LoadError.invalidCatalog }
        }
        return grammar
    }
}
