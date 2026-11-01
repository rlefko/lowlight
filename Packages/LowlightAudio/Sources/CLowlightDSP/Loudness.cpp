// Modifications Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only AND MIT AND BSD-3-Clause
// Meter/filter staging adapted from pyloudnorm 0.1.1 (Christian J. Steinmetz),
// with its MIT notice in Lowlight/ThirdParty/Pyloudnorm-Notices.txt.
// Pairwise reduction adapted from NumPy 2.3.5 loops_utils.h.src, commit
// c3d60fc8393f3ca3306b8ce8b6453d43737e3d90; NumPy Developers, all rights reserved.
// Full NumPy notice: Lowlight/ThirdParty/NumPy-Random-Notices.txt.
#include "LowlightDSP.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif

namespace {
constexpr uint32_t window = 12800, hop = 3200, maximumBlocks = 1807;
struct AnalysisMode {
#if defined(__aarch64__)
    uint64_t control, status;
    AnalysisMode() {
        asm volatile("mrs %0, fpcr" : "=r"(control) : : "memory");
        asm volatile("mrs %0, fpsr" : "=r"(status) : : "memory");
        const uint64_t next = (control | (uint64_t{1} << 24)) & ~(uint64_t{3} << 22);
        asm volatile("msr fpcr, %0" : : "r"(next) : "memory");
    }
    ~AnalysisMode() {
        asm volatile("msr fpcr, %0" : : "r"(control) : "memory");
        asm volatile("msr fpsr, %0" : : "r"(status) : "memory");
    }
#elif defined(__SSE2__)
    unsigned previous = _mm_getcsr();
    AnalysisMode() { _mm_setcsr((previous | 0x8040u) & ~0x6000u); }
    ~AnalysisMode() { _mm_setcsr(previous); }
#else
#error Lowlight requires an ARM64 or SSE2 floating-point target
#endif
};
struct Filter {
    double b0, b1, b2, a1, a2;
    float process(float sample, double (&state)[2]) const {
        const double input = sample;
        const double output = state[0] + b0 * input;
        // Preserve scipy.signal.lfilter's grouping and Double feedback, then
        // the original Float assignment between the two weighting stages.
        state[0] = (state[1] + input * b1) - output * a1;
        state[1] = input * b2 - output * a2;
        return static_cast<float>(output);
    }
};
// Pinned pyloudnorm default K weighting at 32 kHz, not its DeMan alternative.
constexpr Filter shelf{1.5113213110197885, -2.4657134435972035, 1.0421171358466643,
                       -1.5395728725402202, .6272978758094697};
constexpr Filter highpass{.9925802295471099, -1.9851604590942198, .9925802295471099,
                          -1.985132830001248, .9851880881871911};

// Preserve NumPy's logical order across ring wrapping and partial EOF blocks.
// Summing physical ring halves separately would change Float rounding.
template <typename Value, typename Read>
Value pairwise(const Read &read, uint32_t offset, uint32_t count) {
    if (count < 8) {
        Value result = -Value{0};
        for (uint32_t i = 0; i < count; ++i) result += read(offset + i);
        return result;
    }
    if (count <= 128) {
        Value lanes[8];
        for (uint32_t i = 0; i < 8; ++i) lanes[i] = read(offset + i);
        uint32_t i = 8;
        for (; i < count - count % 8; i += 8)
            for (uint32_t lane = 0; lane < 8; ++lane) lanes[lane] += read(offset + i + lane);
        Value result = ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3])) +
                       ((lanes[4] + lanes[5]) + (lanes[6] + lanes[7]));
        for (; i < count; ++i) result += read(offset + i);
        return result;
    }
    uint32_t half = count / 2;
    half -= half % 8;
    const Value left = pairwise<Value>(read, offset, half);
    return left + pairwise<Value>(read, offset + half, count - half);
}
double loudness(double left, double right) {
    const double power = left + right;
    return power == 0 ? -std::numeric_limits<double>::infinity() : -.691 + 10 * std::log10(power);
}
}

struct LLLoudness {
    float powers[2][window]{};
    double bins[2][maximumBlocks]{};
    double shelfState[2][2]{}, highpassState[2][2]{};
    uint32_t frames = 0, blocks = 0, position = 0, nextBlock = 0;
    bool finished = false;
    LLLoudnessResult result{};

    void capture() {
        const uint32_t start = nextBlock * hop, count = position - start;
        for (uint32_t ch = 0; ch < 2; ++ch) {
            const auto read = [&](uint32_t i) { return powers[ch][(start + i) % window]; };
            const float sum = pairwise<float>(read, 0, count);
            // NumPy 2's weak Python scalar keeps this multiplication Float32.
            const float mean = sum * static_cast<float>(1.0 / window);
            bins[ch][nextBlock] = mean;
        }
        ++nextBlock;
    }
    double gatedLoudness(uint32_t count) const {
        double mean[2];
        for (uint32_t ch = 0; ch < 2; ++ch) {
            const auto read = [&](uint32_t i) { return bins[ch][i]; };
            mean[ch] = pairwise<double>(read, 0, count) / count;
        }
        return loudness(mean[0], mean[1]);
    }
};

LLLoudness *ll_loudness_create(uint32_t bodyFrames) {
    AnalysisMode mode;
    if (bodyFrames < LL_LOUDNESS_MIN_FRAMES || bodyFrames > LL_LOUDNESS_MAX_FRAMES) return nullptr;
    auto *meter = new (std::nothrow) LLLoudness;
    if (!meter) return nullptr;
    meter->frames = bodyFrames;
    // Keep the pinned Double duration expression: 24000 frames produces four
    // blocks, unlike rounding an ideal rational half-hop to five blocks.
    meter->blocks = static_cast<uint32_t>(std::nearbyint((bodyFrames / 32000.0 - .4) / (.4 * .25)) + 1);
    return meter;
}
void ll_loudness_destroy(LLLoudness *meter) { delete meter; }
void ll_loudness_reset(LLLoudness *meter) {
    if (!meter) return;
    meter->position = meter->nextBlock = 0;
    meter->finished = false; meter->result = {};
    for (uint32_t ch = 0; ch < 2; ++ch)
        for (uint32_t i = 0; i < 2; ++i) meter->shelfState[ch][i] = meter->highpassState[ch][i] = 0;
    // Every subsequently read ring/bin value is overwritten before use.
}
bool ll_loudness_process(LLLoudness *meter, const float *stereo, uint32_t frames) {
    AnalysisMode mode;
    if (!meter || meter->finished || frames > meter->frames - meter->position || (frames && !stereo)) return false;
    for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
        if (!std::isfinite(stereo[i]) || std::abs(stereo[i]) > LL_LOUDNESS_INPUT_LIMIT) return false;
    // Conservative cascade l1 <9.564e6: bounded input keeps filtered |x|<1e13,
    // and each positive Float window sum <1.28e30, safely below Float overflow.
    // No fallible operation remains after the complete input preflight.
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t ch = 0; ch < 2; ++ch) {
            const float weighted = highpass.process(
                shelf.process(stereo[uint64_t{i} * 2 + ch], meter->shelfState[ch]), meter->highpassState[ch]);
            meter->powers[ch][meter->position % window] = weighted * weighted;
        }
        ++meter->position;
        if (meter->nextBlock < meter->blocks &&
            meter->position == std::min(meter->frames, meter->nextBlock * hop + window)) meter->capture();
    }
    return true;
}
bool ll_loudness_finish(LLLoudness *meter, LLLoudnessResult *result) {
    AnalysisMode mode;
    if (result) std::memset(result, 0, sizeof(*result));
    if (!meter || !result || meter->position != meter->frames) return false;
    if (!meter->finished) {
        meter->result.total_blocks = meter->blocks;
        uint32_t absolute = 0;
        for (uint32_t i = 0; i < meter->blocks; ++i)
            if (loudness(meter->bins[0][i], meter->bins[1][i]) >= -70) {
                for (uint32_t ch = 0; ch < 2; ++ch) meter->bins[ch][absolute] = meter->bins[ch][i];
                ++absolute;
            }
        meter->result.absolute_blocks = absolute;
        if (absolute) {
            const double relative = meter->gatedLoudness(absolute) - 10;
            uint32_t gated = 0;
            for (uint32_t i = 0; i < absolute; ++i) {
                const double level = loudness(meter->bins[0][i], meter->bins[1][i]);
                if (level > relative && level > -70) {
                    for (uint32_t ch = 0; ch < 2; ++ch) meter->bins[ch][gated] = meter->bins[ch][i];
                    ++gated;
                }
            }
            meter->result.gated_blocks = gated;
            if (gated) {
                meter->result.integrated_lufs = meter->gatedLoudness(gated);
                meter->result.measurable = true;
            }
        }
        meter->finished = true;
    }
    *result = meter->result;
    return true;
}
