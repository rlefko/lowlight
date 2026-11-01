// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <new>

namespace {
constexpr uint32_t window = 800, delay = LL_GLUE_LATENCY + 1;
constexpr uint64_t inputLimit = (uint64_t{1} << 52) - LL_GLUE_LATENCY;
float normal(float value) { return std::abs(value) < std::numeric_limits<float>::min() ? 0 : value; }

void clear(LLGlueFrame *output, uint32_t frames) {
    if (output) for (uint32_t i = 0; i < frames; ++i) output[i] = LLGlueFrame{};
}
bool overlaps(const void *first, uint64_t firstBytes, const void *second, uint64_t secondBytes) {
    if (!firstBytes || !secondBytes) return false;
    const auto a = reinterpret_cast<uintptr_t>(first), b = reinterpret_cast<uintptr_t>(second);
    // Ordered differences avoid overflowing an end address or forming out-of-array pointers.
    return a <= b ? b - a < firstBytes : a - b < secondBytes;
}
}

struct LLGlue {
    uint64_t total = 0, consumed = 0;
    uint32_t drained = 0;
    float guitarGain = 1, pianoGain = .94f;
    float powers[window]{};
    LLGlueFrame pending[delay]{};
    double sum = 0, gainDB = 0;
    double attack = std::exp(-1 / (.012 * 32000)), release = std::exp(-1 / (.22 * 32000));

    bool prepare(const LLBusFrame &input, LLGlueFrame &frame, float &power) const {
        if (!lowlight::unitInterval(input.duck)) return false;
        for (uint32_t ch = 0; ch < 2; ++ch) {
            if (!std::isfinite(input.guitar[ch]) || !std::isfinite(input.piano[ch]) ||
                !std::isfinite(input.bass[ch]) || !std::isfinite(input.drums[ch])) return false;
            frame.tonal[ch] = normal(input.guitar[ch] * guitarGain + input.piano[ch] * pianoGain);
            frame.bass[ch] = normal(input.bass[ch]); frame.drums[ch] = normal(input.drums[ch]);
        }
        frame.duck = normal(input.duck);
        power = (frame.tonal[0] * frame.tonal[0] + frame.tonal[1] * frame.tonal[1]) * .5f;
        return std::isfinite(power);
    }
    float powerAt(int64_t index) const {
        const int64_t length = static_cast<int64_t>(total);
        if (index < 0 || index >= length) {
            const int64_t period = 2 * length;
            index %= period;
            if (index < 0) index += period;
            if (index >= length) index = period - 1 - index;
        }
        return powers[static_cast<uint64_t>(index) % window];
    }
    LLGlueFrame advance(uint64_t time, float power) {
        // Read the departing value before overwriting its circular-buffer slot.
        const float previous = time > LL_GLUE_LATENCY ? powerAt(static_cast<int64_t>(time) - window) : 0;
        powers[time % window] = power;
        if (time < LL_GLUE_LATENCY) {
            LLGlueFrame silence{}; silence.duck = 1; return silence;
        }
        if (time == LL_GLUE_LATENCY) {
            // SciPy's even centered window is [-400,399], with endpoint reflection.
            for (int64_t i = -400; i < 400; ++i) sum += static_cast<double>(powerAt(i));
        } else sum += static_cast<double>(power) - static_cast<double>(previous);
        const float mean = static_cast<float>(sum / window);
        const float env = std::sqrt(std::max(mean, 0.f) + 1e-14f);
        const float over = 20.f * std::log10(env / .024f);
        constexpr float slope = static_cast<float>(1 - 1 / 2.3);
        const float knee = over + 3.f;
        const float reduction = over < -3.f ? 0 :
            (over > 3.f ? slope * over : slope * (knee * knee) / 12.f);
        const float target = -std::min(reduction, 5.f);
        const double coefficient = target < gainDB ? attack : release;
        gainDB = coefficient * gainDB + (1 - coefficient) * target;
        const float gain = std::pow(10.f, static_cast<float>(gainDB) / 20.f);
        auto result = pending[(time - LL_GLUE_LATENCY) % delay];
        for (auto &channel : result.tonal) channel = normal(channel * gain);
        return result;
    }
};

LLGlue *ll_glue_create(uint64_t inputFrames, uint8_t focus) {
    if (inputFrames > inputLimit || focus > 1) return nullptr;
    lowlight::FloatingPointMode mode;
    auto *glue = new (std::nothrow) LLGlue;
    if (glue) {
        glue->total = inputFrames;
        if (focus) { glue->guitarGain = .85f; glue->pianoGain = 1.08f; }
    }
    return glue;
}
void ll_glue_destroy(LLGlue *glue) { delete glue; }
void ll_glue_reset(LLGlue *glue) {
    if (!glue) return;
    glue->consumed = 0; glue->drained = 0; glue->sum = 0; glue->gainDB = 0;
    for (auto &power : glue->powers) power = 0;
    for (auto &frame : glue->pending) frame = LLGlueFrame{};
}
bool ll_glue_process(LLGlue *glue, const LLBusFrame *input, LLGlueFrame *output, uint32_t frames) {
    lowlight::FloatingPointMode mode;
    if (!glue || (frames && (!input || !output)) || frames > glue->total - glue->consumed ||
        overlaps(input, uint64_t{frames} * sizeof(*input), output, uint64_t{frames} * sizeof(*output))) {
        clear(output, frames); return false;
    }
    LLGlueFrame frame{}; float power = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        if (!glue->prepare(input[i], frame, power)) { clear(output, frames); return false; }
    }
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset) {
            glue->prepare(input[offset], frame, power);
            glue->pending[glue->consumed % delay] = frame;
            output[offset] = glue->advance(glue->consumed++, power);
        }
    }
    return true;
}
bool ll_glue_drain(LLGlue *glue, LLGlueFrame *output, uint32_t capacity, uint32_t *written) {
    lowlight::FloatingPointMode mode;
    if (written && overlaps(output, uint64_t{capacity} * sizeof(*output), written, sizeof(*written))) {
        clear(output, capacity); return false;
    }
    if (written) *written = 0;
    clear(output, capacity);
    if (!glue || !written || (capacity && !output) || glue->consumed != glue->total) return false;
    const uint32_t remaining = glue->total ? LL_GLUE_LATENCY - glue->drained : 0;
    const uint32_t frames = std::min(capacity, remaining);
    for (uint32_t i = 0; i < frames; ++i) {
        const uint64_t time = glue->consumed + glue->drained;
        output[i] = glue->advance(time, glue->powerAt(static_cast<int64_t>(time)));
        ++glue->drained;
    }
    *written = frames;
    return true;
}
