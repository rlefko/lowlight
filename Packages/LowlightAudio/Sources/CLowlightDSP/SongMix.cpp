// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>

namespace {
float normal(float value) { return std::abs(value) < std::numeric_limits<float>::min() ? 0 : value; }
bool valid(const LLGlueFrame &frame) {
    uint32_t duck;
    std::memcpy(&duck, &frame.duck, sizeof(duck));
    if (duck > 0x3f800000u && duck != 0x80000000u) return false;
    for (uint32_t ch = 0; ch < 2; ++ch)
        if (!std::isfinite(frame.tonal[ch]) || std::abs(frame.tonal[ch]) > LL_SONG_MIX_BUS_LIMIT ||
            !std::isfinite(frame.bass[ch]) || std::abs(frame.bass[ch]) > LL_SONG_MIX_BUS_LIMIT ||
            !std::isfinite(frame.drums[ch]) || std::abs(frame.drums[ch]) > LL_SONG_MIX_BUS_LIMIT) return false;
    return true;
}
void clear(float *output, uint32_t frames) {
    if (output) for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) output[i] = 0;
}
}

struct LLSongMix {
    LLAir *air = nullptr;
    double b0 = 0, b1 = 0, a1 = 0, a2 = 0;
    double first[2]{}, second[2]{};
    uint32_t frames = 0, position = 0;
};

LLSongMix *ll_song_mix_create(uint32_t takeSeed, uint32_t inputFrames, uint64_t frameOrigin,
                            double texture, const LLRackFades *fades) {
    lowlight::FloatingPointMode mode;
    LLAir *air = ll_air_create(takeSeed, inputFrames, frameOrigin, texture, fades);
    if (!air) return nullptr;
    auto *mix = new (std::nothrow) LLSongMix;
    if (!mix) { ll_air_destroy(air); return nullptr; }
    mix->air = air; mix->frames = inputFrames;
    const double tangent = std::tan(3.14159265358979323846 * 32 / 32000);
    const double denominator = 1 + tangent / std::sqrt(.5) + tangent * tangent;
    mix->b0 = 1 / denominator;
    mix->b1 = -2 * mix->b0;
    mix->a1 = 2 * (tangent * tangent - 1) / denominator;
    mix->a2 = (1 - tangent / std::sqrt(.5) + tangent * tangent) / denominator;
    return mix;
}
void ll_song_mix_destroy(LLSongMix *mix) {
    if (!mix) return;
    ll_air_destroy(mix->air); delete mix;
}
void ll_song_mix_reset(LLSongMix *mix) {
    if (!mix) return;
    ll_air_reset(mix->air); mix->position = 0;
    for (uint32_t ch = 0; ch < 2; ++ch) mix->first[ch] = mix->second[ch] = 0;
}
bool ll_song_mix_process(LLSongMix *mix, const LLGlueFrame *input, float *output, uint32_t frames) {
    lowlight::FloatingPointMode mode;
    const auto a = reinterpret_cast<uintptr_t>(input), b = reinterpret_cast<uintptr_t>(output);
    const uint64_t inputBytes = uint64_t{frames} * sizeof(*input), outputBytes = uint64_t{frames} * 2 * sizeof(*output);
    if (!mix || frames > mix->frames - mix->position || (frames && (!input || !output)) ||
        (a <= b ? b - a < inputBytes : a - b < outputBytes)) {
        clear(output, frames); return false;
    }
    for (uint32_t i = 0; i < frames; ++i) if (!valid(input[i])) { clear(output, frames); return false; }
    for (uint32_t i = 0; i < frames; ++i)
        for (uint32_t ch = 0; ch < 2; ++ch) {
            const float sum = input[i].tonal[ch] + input[i].bass[ch];
            const float ducked = sum * input[i].duck;
            output[uint64_t{i} * 2 + ch] = ducked + input[i].drums[ch];
        }
    // Air validates/certifies its finite replay and rolls back the complete call
    // on failure. Keep HP history untouched until that single call succeeds.
    if (!ll_air_add(mix->air, output, frames)) return false;
    // HP32 poles have radius <.996 and numerator l1 <4, giving impulse l1
    // <250,000. Bounded buses plus air stay far below Float overflow; no later
    // fallible operation needs an opaque-air checkpoint or whole-call scratch.
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset)
            for (uint32_t ch = 0; ch < 2; ++ch) {
                const uint64_t i = uint64_t{offset} * 2 + ch;
                const double sample = output[i];
                const double value = mix->b0 * sample + mix->first[ch];
                mix->first[ch] = mix->b1 * sample - mix->a1 * value + mix->second[ch];
                mix->second[ch] = mix->b0 * sample - mix->a2 * value;
                output[i] = normal(static_cast<float>(value));
            }
    }
    mix->position += frames;
    return true;
}
