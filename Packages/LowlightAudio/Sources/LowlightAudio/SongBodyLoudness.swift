// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

public enum SongBodyLoudnessError: Error { case incompleteSong }

/// Single-owner, off-callback body selection from sequential post-HP32 song frames.
/// Input uses logical coordinates after removing glue startup, before fixed gain
/// and peak protection. Only the selected body enters fresh K-weighting history.
public final class SongBodyLoudness {
    public static let inputLimit = SongLoudnessMeter.inputLimit
    public let layout: SongRenderLayout
    public private(set) var position: UInt32 = 0
    private let meter: SongLoudnessMeter
    private var measurement: SongLoudnessMeasurement?

    public init(layout: SongRenderLayout) throws {
        self.layout = layout
        meter = try SongLoudnessMeter(
            bodyFrames: layout.bodyFrames.upperBound - layout.bodyFrames.lowerBound)
    }

    /// Consume interleaved stereo without retaining song PCM. Validate the entire
    /// call, including samples outside the body, before advancing any progress.
    /// Rejected dimensions, excess length, or nonfinite/out-of-domain input leave
    /// the cursor and meter unchanged. Empty input succeeds until finalization.
    public func process(_ input: UnsafeBufferPointer<Float>) -> Bool {
        guard measurement == nil, input.count.isMultiple(of: 2),
            input.count / 2 <= Int(layout.inputFrames - position)
        else { return false }
        // Unsigned Float magnitudes are ordered; bit checks also reject NaN/Inf
        // without changing caller FP status for samples outside the native meter.
        let maximumMagnitude = Self.inputLimit.bitPattern
        guard input.allSatisfy({ ($0.bitPattern & 0x7fff_ffff) <= maximumMagnitude }) else {
            return false
        }
        let end = position + UInt32(input.count / 2)
        let lower = max(position, layout.bodyFrames.lowerBound)
        let upper = min(end, layout.bodyFrames.upperBound)
        if lower < upper {
            let samples = Int(lower - position) * 2..<Int(upper - position) * 2
            guard meter.process(UnsafeBufferPointer(rebasing: input[samples])) else { return false }
        }
        position = end
        return true
    }

    /// Requires every declared logical frame, including the tail. An incomplete
    /// attempt preserves progress. Success is repeatable and closes processing
    /// until reset; the measurement can prepare the existing SongFixedGain.
    public func finish() throws -> SongLoudnessMeasurement {
        if let measurement { return measurement }
        guard position == layout.inputFrames else { throw SongBodyLoudnessError.incompleteSong }
        let result = try meter.finish()
        measurement = result
        return result
    }

    /// Rewinds this analysis only. The caller separately resets its upstream rack.
    public func reset() {
        meter.reset()
        position = 0
        measurement = nil
    }
}
