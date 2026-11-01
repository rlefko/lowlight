// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <cmath>
#include <cstring>
#include <new>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif

namespace {
struct GainMode {
#if defined(__aarch64__)
    uint64_t control, status;
    GainMode() {
        asm volatile("mrs %0, fpcr" : "=r"(control) : : "memory");
        asm volatile("mrs %0, fpsr" : "=r"(status) : : "memory");
        const uint64_t next = (control | (uint64_t{1} << 24)) & ~(uint64_t{3} << 22);
        asm volatile("msr fpcr, %0" : : "r"(next) : "memory");
    }
    ~GainMode() {
        asm volatile("msr fpcr, %0" : : "r"(control) : "memory");
        asm volatile("msr fpsr, %0" : : "r"(status) : "memory");
    }
#elif defined(__SSE2__)
    unsigned previous = _mm_getcsr();
    GainMode() { _mm_setcsr((previous | 0x8040u) & ~0x6000u); }
    ~GainMode() { _mm_setcsr(previous); }
#else
#error Lowlight requires an ARM64 or SSE2 floating-point target
#endif
};
void clear(float *output, uint32_t frames) {
    if (output) for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) output[i] = 0;
}
}

struct LLSongGain { LLSongGainValues values; };

LLSongGain *ll_song_gain_create(double bodyLUFS) {
    GainMode mode;
    if (!std::isfinite(bodyLUFS) || bodyLUFS < -70) return nullptr;
    const double decibels = -20.5 - bodyLUFS;
    const double multiplier = std::pow(10.0, decibels / 20.0);
    if (!std::isfinite(multiplier) || multiplier <= 0) return nullptr;
    return new (std::nothrow) LLSongGain{{decibels, multiplier}};
}
void ll_song_gain_destroy(LLSongGain *gain) { delete gain; }
bool ll_song_gain_get(const LLSongGain *gain, LLSongGainValues *values) {
    if (values) std::memset(values, 0, sizeof(*values));
    if (!gain || !values) return false;
    *values = gain->values;
    return true;
}
bool ll_song_gain_process(const LLSongGain *gain, const float *input, float *output, uint32_t frames) {
    GainMode mode;
    const auto a = reinterpret_cast<uintptr_t>(input), b = reinterpret_cast<uintptr_t>(output);
    const uint64_t bytes = uint64_t{frames} * 2 * sizeof(float);
    if (!gain || (frames && (!input || !output)) || (a <= b ? b - a < bytes : a - b < bytes)) {
        clear(output, frames); return false;
    }
    for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
        if (!std::isfinite(input[i]) || std::abs(input[i]) > LL_SONG_GAIN_INPUT_LIMIT) {
            clear(output, frames); return false;
        }
    // Measurable LUFS >=-70 bounds the multiplier by 10^(49.5/20)<299;
    // the complete input domain therefore produces finite magnitudes below 3e8.
    // The original scale is a strong np.float64 scalar, so do not round it or
    // the product to Float until the final store.
    for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
        output[i] = static_cast<float>(static_cast<double>(input[i]) * gain->values.linear_multiplier);
    return true;
}
