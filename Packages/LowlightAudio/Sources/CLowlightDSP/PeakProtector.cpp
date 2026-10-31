// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <new>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif

namespace {
constexpr uint32_t window = LL_PEAK_LATENCY + 1;
float normal(float value) { return std::abs(value) < std::numeric_limits<float>::min() ? 0 : value; }
struct FlushSubnormals {
#if defined(__aarch64__)
    uint64_t control, status;
    FlushSubnormals() {
        asm volatile("mrs %0, fpcr" : "=r"(control) : : "memory");
        asm volatile("mrs %0, fpsr" : "=r"(status) : : "memory");
        const uint64_t next = control | (uint64_t{1} << 24);
        asm volatile("msr fpcr, %0" : : "r"(next) : "memory");
    }
    ~FlushSubnormals() {
        asm volatile("msr fpcr, %0" : : "r"(control) : "memory");
        asm volatile("msr fpsr, %0" : : "r"(status) : "memory");
    }
#elif defined(__SSE2__)
    unsigned previous = _mm_getcsr();
    FlushSubnormals() { _mm_setcsr(previous | 0x8040); }
    ~FlushSubnormals() { _mm_setcsr(previous); }
#else
#error Lowlight requires an ARM64 or SSE2 floating-point target
#endif
};
void clear(float *output, uint32_t frames) {
    if (output) for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) output[i] = 0;
}
bool overlaps(const void *first, uint64_t firstBytes, const void *second, uint64_t secondBytes) {
    if (!firstBytes || !secondBytes) return false;
    const auto a = reinterpret_cast<uintptr_t>(first), b = reinterpret_cast<uintptr_t>(second);
    return a <= b ? b - a < firstBytes : a - b < secondBytes;
}
}

struct LLPeakProtector {
    struct Peak { float value; uint32_t slot; } peaks[window]{};
    float pending[window][2]{};
    uint32_t head = 0, count = 0, cursor = 0, primed = 0, drained = 0;
    bool nonempty = false, closed = false;
    float ceiling = 0, lastPeak = 0;
    double gainDB = 0;
    double attack = std::exp(-1 / (.0007 * 32000)), release = std::exp(-1 / (.100 * 32000));

    void advance(float left, float right, float peak, float *output) {
        // The overwritten slot is oldest. If retained, it is the deque front.
        if (count && peaks[head].slot == cursor) { head = (head + 1) % window; --count; }
        // Retain the latest equal maximum. Each input enters and leaves at most once;
        // even an individual update examines no more than the fixed 161 entries.
        while (count && peaks[(head + count - 1) % window].value <= peak) --count;
        peaks[(head + count) % window] = Peak{peak, cursor}; ++count;
        pending[cursor][0] = left; pending[cursor][1] = right;
        cursor = (cursor + 1) % window;
        if (primed < LL_PEAK_LATENCY) {
            ++primed; output[0] = 0; output[1] = 0; return;
        }
        const float ratio = ceiling / std::max(peaks[head].value, 1e-12f);
        const float target = std::min(0.f, 20.f * std::log10(ratio));
        const double coefficient = target < gainDB ? attack : release;
        gainDB = coefficient * gainDB + (1 - coefficient) * target;
        const float gain = std::pow(10.f, static_cast<float>(gainDB) / 20.f);
        for (uint32_t ch = 0; ch < 2; ++ch) output[ch] = normal(pending[cursor][ch] * gain);
    }
};

LLPeakProtector *ll_peak_create(uint8_t mode) {
    if (mode > LL_PEAK_SESSION) return nullptr;
    FlushSubnormals flush;
    auto *protector = new (std::nothrow) LLPeakProtector;
    if (protector) protector->ceiling = static_cast<float>(std::pow(10.0, (mode ? -2.2 : -5.0) / 20));
    return protector;
}
void ll_peak_destroy(LLPeakProtector *protector) { delete protector; }
void ll_peak_reset(LLPeakProtector *protector) {
    if (!protector) return;
    protector->head = 0; protector->count = 0; protector->cursor = 0;
    protector->primed = 0; protector->drained = 0;
    protector->nonempty = false; protector->closed = false;
    protector->lastPeak = 0; protector->gainDB = 0;
    for (auto &frame : protector->pending) { frame[0] = 0; frame[1] = 0; }
}
bool ll_peak_process(LLPeakProtector *protector, const float *input, float *output, uint32_t frames) {
    FlushSubnormals flush;
    const uint64_t samples = uint64_t{frames} * 2, bytes = samples * sizeof(float);
    if (!protector || protector->closed || (frames && (!input || !output)) ||
        overlaps(input, bytes, output, bytes)) {
        clear(output, frames); return false;
    }
    // At the explicit magnitude bound, ceiling/peak remains a normal Float even
    // with FTZ/DAZ. This keeps the accepted Float log target and Double state finite.
    for (uint64_t i = 0; i < samples; ++i) {
        if (!std::isfinite(input[i]) || std::abs(input[i]) > LL_PEAK_INPUT_LIMIT) {
            clear(output, frames); return false;
        }
    }
    if (frames) protector->nonempty = true;
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset) {
            const uint64_t index = uint64_t{offset} * 2;
            const float left = normal(input[index]), right = normal(input[index + 1]);
            protector->lastPeak = std::max(std::abs(left), std::abs(right));
            protector->advance(left, right, protector->lastPeak, output + index);
        }
    }
    return true;
}
bool ll_peak_drain(LLPeakProtector *protector, float *output, uint32_t capacity, uint32_t *written) {
    FlushSubnormals flush;
    if (written && overlaps(output, uint64_t{capacity} * 2 * sizeof(float), written, sizeof(*written))) {
        clear(output, capacity); return false;
    }
    if (written) *written = 0;
    clear(output, capacity);
    if (!protector || !written || (capacity && !output)) return false;
    protector->closed = true;
    const uint32_t remaining = protector->nonempty ? LL_PEAK_LATENCY - protector->drained : 0;
    const uint32_t frames = std::min(capacity, remaining);
    for (uint32_t i = 0; i < frames; ++i) {
        // Nearest endpoint extension of the detector, with silent audio padding.
        protector->advance(0, 0, protector->lastPeak, output + uint64_t{i} * 2);
        ++protector->drained;
    }
    *written = frames;
    return true;
}
