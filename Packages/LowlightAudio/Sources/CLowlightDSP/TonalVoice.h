// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "FloatingPointMode.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace lowlight {
constexpr uint32_t tonalKeys = 100, warmthBins = 101;
// Five mono articulations, each admitting MIDI 50 through 69 on the keys bus.
inline bool bandKey(uint32_t key) {
    return key >= 256 && key < 356;
}
inline bool tonalFormat(uint32_t key, uint32_t channels) {
    if (bandKey(key))
        return channels == 1;
    return key < tonalKeys && channels == (key < 80 ? 1u : 2u);
}
struct TonalSection {
    double b0, b1, a1, a2;
    static TonalSection design(double tangent, double quality) {
        const double denominator = 1 + tangent / quality + tangent * tangent;
        const double gain = tangent * tangent / denominator;
        return {gain, 2 * gain, 2 * (tangent * tangent - 1) / denominator,
                (1 - tangent / quality + tangent * tangent) / denominator};
    }
    TonalSection toward(const TonalSection &other, double fraction) const {
        return {b0 + (other.b0 - b0) * fraction, b1 + (other.b1 - b1) * fraction,
                a1 + (other.a1 - a1) * fraction, a2 + (other.a2 - a2) * fraction};
    }
};
struct TonalCoefficients {
    TonalSection sections[2];
};
}

// Immutable, fully initialized off the render thread. Both racks can borrow this table.
struct LLTonalCalibration {
    float gains[lowlight::tonalKeys][lowlight::warmthBins];
    lowlight::TonalCoefficients filters[3][lowlight::warmthBins];
    double pianoShape[32000];
};

namespace lowlight {
struct TonalSetting {
    const LLTonalCalibration *table = nullptr;
    TonalCoefficients filters[3]{};
    uint32_t lower = 0, upper = 0;
    double fraction = 0, position = -1;
    void set(double bin) {
        if (position == bin)
            return;
        position = bin;
        lower = static_cast<uint32_t>(bin);
        upper = std::min(warmthBins - 1, lower + 1);
        fraction = bin - lower;
        for (uint32_t instrument = 0; instrument < 3; ++instrument) {
            const auto &from = table->filters[instrument][lower];
            if (!fraction) {
                filters[instrument] = from;
                continue;
            }
            for (uint32_t section = 0; section < 2; ++section)
                filters[instrument].sections[section] = from.sections[section].toward(
                    table->filters[instrument][upper].sections[section], fraction);
        }
    }
    float gain(uint32_t key) const {
        if (bandKey(key))
            return 1.f; // Band PCM is level-matched at import.
        const float from = table->gains[key][lower];
        if (!fraction)
            return from;
        return static_cast<float>(from + (static_cast<double>(table->gains[key][upper]) - from) *
                                             fraction);
    }
};
struct TonalFilterState {
    double first = 0, second = 0;
    double process(double input, const TonalSection &section) {
        const double result = section.b0 * input + first;
        first = section.b1 * input - section.a1 * result + second;
        second = section.b0 * input - section.a2 * result;
        return result;
    }
};
// Raw HP PCM and the LP4 output used to cross Float32 boundaries during gradual-underflow
// preparation. Preserve those roundings under render FTZ/DAZ without changing the rest
// of the mixer's numeric mode. Only the outer, admitted PCM is flushed as before.
inline double tonalInput(float sample) {
    uint32_t bits;
    std::memcpy(&bits, &sample, sizeof(bits));
    if ((bits & 0x7f800000u) == 0)
        return (bits >> 31 ? -0x1p-149 : 0x1p-149) * (bits & 0x7fffffu);
    return sample;
}
inline float admittedTonal(double value) {
    constexpr double minimum = std::numeric_limits<float>::min();
    if (std::abs(value) >= minimum)
        return static_cast<float>(value);
    // Float rounds the midpoint upward to the even minimum normal. Render FTZ may
    // instead flush before rounding on some targets; final admitted PCM must agree.
    return std::abs(value) >= minimum - 0x1p-150
               ? std::copysign(std::numeric_limits<float>::min(), value)
               : 0.f;
}
inline float calibratedTonal(double value, float gain) {
    constexpr double minimum = std::numeric_limits<float>::min();
    if (std::abs(value) >= 4 * minimum)
        return static_cast<float>(value) * gain;
    // Only near underflow, reproduce the gradual Float boundary before multiplying
    // by the Float calibration. A subnormal LP output can become normal at gain > 1.
    const double rounded = std::abs(value) < minimum
                               ? std::nearbyint(value * 0x1p149) * 0x1p-149
                               : static_cast<double>(static_cast<float>(value));
    return admittedTonal(rounded * gain);
}
struct TonalHistory {
    TonalFilterState channels[2][2]{};
    float process(float sample, uint32_t channel, const TonalCoefficients &filter, float gain) {
        auto &sections = channels[channel];
        const double first = sections[0].process(tonalInput(sample), filter.sections[0]);
        return calibratedTonal(sections[1].process(first, filter.sections[1]), gain);
    }
};
}
