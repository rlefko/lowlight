// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOWLIGHT_RACK_FADES_H
#define LOWLIGHT_RACK_FADES_H
#include "LowlightDSP.h"
#include <algorithm>
#include <cmath>
#include <cstring>

namespace lowlight {
constexpr uint64_t frameLimit = uint64_t{1} << 52;
inline uint64_t frameBits(double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits == (uint64_t{1} << 63) ? 0 : bits; // Permit negative zero, not negative subnormals.
}
struct RackFades {
    LLRackFades points{};
    uint64_t rhythmFirst = 0;
    bool configured = false, arrival = false;
    bool configure(const LLRackFades &fades) {
        const double endpoints[] = {fades.tonal_in_start_frame, fades.tonal_in_end_frame,
            fades.tonal_out_start_frame, fades.tonal_out_end_frame, fades.rhythm_in_frame, fades.rhythm_out_frame};
        for (const double endpoint : endpoints)
            if (frameBits(endpoint) > frameBits(static_cast<double>(frameLimit))) return false;
        const bool incoming = frameBits(endpoints[0]) != 0 || frameBits(endpoints[1]) != 0;
        if ((incoming && endpoints[1] - endpoints[0] < 1) || endpoints[3] - endpoints[2] < 1 ||
            frameBits(endpoints[4]) > frameBits(endpoints[5])) return false;
        // Preserve positive subnormal gate endpoints even under caller FTZ/DAZ.
        const uint64_t first = frameBits(endpoints[4]) && endpoints[4] < 1 ? 1 :
            static_cast<uint64_t>(std::ceil(endpoints[4]));
        *this = RackFades{fades, first, true, incoming};
        return true;
    }
    static double linear(double position, double start, double end) {
        if (position <= start) return 0;
        if (position >= end) return 1;
        return (position - start) / (end - start);
    }
    double tonalGain(uint64_t frame) const {
        const double position = static_cast<double>(frame);
        double tonal = 1 - linear(position, points.tonal_out_start_frame, points.tonal_out_end_frame);
        if (arrival) tonal *= linear(position, points.tonal_in_start_frame, points.tonal_in_end_frame);
        return tonal;
    }
    void apply(float (&stems)[7][2], uint64_t frame) const {
        if (!configured) return;
        const double tonal = tonalGain(frame);
        const double rhythm = frame < rhythmFirst ? 0 :
            std::clamp((points.rhythm_out_frame - static_cast<double>(frame)) / 2400, 0.0, 1.0);
        for (uint32_t kind = 0; kind < 7; ++kind)
            for (uint32_t channel = 0; channel < 2; ++channel)
                stems[kind][channel] = static_cast<float>(static_cast<double>(stems[kind][channel]) *
                    (kind < 2 ? tonal : rhythm));
    }
};
}
#endif
