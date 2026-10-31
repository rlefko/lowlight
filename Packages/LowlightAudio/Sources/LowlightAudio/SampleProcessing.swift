// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum SampleProcessing {
    /// Centered Kaiser-windowed sinc, matching the frozen resample_poly defaults.
    /// Only the relevant polyphase taps are evaluated; no zero-stuffed buffer exists.
    static func transpose(_ input: [Float], channels: Int, semitones: Int) -> [Float] {
        guard semitones != 0 else { return input }
        let ratio = pow(2, -Double(semitones) / 12)
        var up = 1
        var down = 1
        var closest = Double.infinity
        for denominator in 1...2048 {
            let numerator = Int((ratio * Double(denominator)).rounded(.toNearestOrEven))
            let error = abs(Double(numerator) / Double(denominator) - ratio)
            if error < closest {
                up = numerator
                down = denominator
                closest = error
            }
        }
        let half = 10 * max(up, down)
        let cutoff = 1 / Double(max(up, down))
        let windowScale = bessel(5)
        var coefficients = (0...(2 * half)).map { index in
            let offset = Double(index - half)
            let position = offset * cutoff
            let sinc = position == 0 ? 1 : sin(.pi * position) / (.pi * position)
            return cutoff * sinc * bessel(5 * sqrt(max(0, 1 - pow(offset / Double(half), 2))))
                / windowScale
        }
        let scale = coefficients.reduce(0, +)
        coefficients = coefficients.map { $0 / scale }
        let taps = coefficients.map { Float($0) * Float(up) }
        let inputFrames = input.count / channels
        let outputFrames = (inputFrames * up + down - 1) / down
        var output = [Float](repeating: 0, count: outputFrames * channels)
        for frame in 0..<outputFrames {
            let center = frame * down + half
            let first = max(0, (center - 2 * half + up - 1) / up)
            let last = min(inputFrames - 1, center / up)
            for channel in 0..<channels {
                var sum: Float = 0
                for source in first...last {
                    sum += input[source * channels + channel] * taps[center - source * up]
                }
                output[frame * channels + channel] = sum
            }
        }
        return output
    }

    private static func bessel(_ value: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        for index in 1...32 {
            term *= value * value / (4 * Double(index * index))
            sum += term
            if term < sum * 1e-16 { break }
        }
        return sum
    }

    /// Butterworth high-pass order 2 / low-pass order 4, zero initial state.
    /// Double section state matches scipy.sosfilt; cast only at each filter's output.
    static func filter(_ samples: inout [Float], channels: Int, cutoff: Double, highpass: Bool) {
        let quality = highpass ? [sqrt(0.5)] : [0.541196100146197, 1.306562964876377]
        let tangent = tan(.pi * cutoff / 32_000)
        let sections = quality.map { quality in
            let denominator = 1 + tangent / quality + tangent * tangent
            let gain = (highpass ? 1 : tangent * tangent) / denominator
            return (
                gain, (highpass ? -2 : 2) * gain,
                2 * (tangent * tangent - 1) / denominator,
                (1 - tangent / quality + tangent * tangent) / denominator
            )
        }
        for channel in 0..<channels {
            var first = [Double](repeating: 0, count: sections.count)
            var second = first
            for index in stride(from: channel, to: samples.count, by: channels) {
                var sample = Double(samples[index])
                for section in sections.indices {
                    let (b0, b1, a1, a2) = sections[section]
                    let result = b0 * sample + first[section]
                    first[section] = b1 * sample - a1 * result + second[section]
                    second[section] = b0 * sample - a2 * result
                    sample = result
                }
                samples[index] = Float(sample)
            }
        }
    }
}
