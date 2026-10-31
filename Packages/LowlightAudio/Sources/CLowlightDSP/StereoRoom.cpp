// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
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
constexpr double pi = 3.14159265358979323846;
// Frozen render_room.room delays, rounded to the nearest canonical 32 kHz frame.
constexpr uint32_t combFrames[2][8] = {{950, 1110, 1187, 1315, 1398, 1533, 1706, 1898},
                                      {995, 1155, 1232, 1360, 1443, 1577, 1750, 1942}};
constexpr uint32_t allpassFrames[2][3] = {{160, 54, 23}, {166, 60, 29}};
constexpr uint32_t earlyFrames[2][3] = {{618, 1187, 1981}, {718, 1287, 2081}};
constexpr float earlyGains[] = {.10f, .065f, .045f};
constexpr uint32_t predelayFrames = 384;
constexpr uint32_t storageFrames = [] {
    uint32_t result = 2 * predelayFrames;
    for (uint32_t ch = 0; ch < 2; ++ch) {
        for (auto frames : combFrames[ch]) result += frames;
        for (auto frames : allpassFrames[ch]) result += frames;
        result += earlyFrames[ch][2];
    }
    return result;
}();
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
struct Delay {
    uint32_t offset = 0, length = 0, position = 0;
    void configure(uint32_t &cursor, uint32_t frames) { offset = cursor; length = frames; cursor += frames; }
    float peek(const float *storage) const { return storage[offset + position]; }
    float tap(const float *storage, uint32_t age) const {
        return storage[offset + (position >= age ? position - age : position + length - age)];
    }
    void push(float *storage, float value) {
        storage[offset + position] = normal(value);
        if (++position == length) position = 0;
    }
};
struct Comb {
    Delay delay;
    double feedback = 0, state = 0;
    float process(float *storage, float input) {
        const float delayed = delay.peek(storage);
        state = .5 * delayed + .5 * state;
        delay.push(storage, static_cast<float>(input + feedback * state));
        return delayed;
    }
};
struct Channel {
    Comb combs[8];
    Delay allpasses[3], predelay, early;
    float process(float *storage, float input, uint32_t channel) {
        float diffuse = 0;
        for (auto &comb : combs) diffuse += comb.process(storage, input) * .105f;
        for (auto &delay : allpasses) {
            const double value = delay.peek(storage) - .58 * diffuse;
            // Feedback uses the unrounded Double allpass output, as in the Numba recurrence.
            delay.push(storage, static_cast<float>(diffuse + .58 * value));
            diffuse = normal(static_cast<float>(value));
        }
        float wet = predelay.peek(storage);
        predelay.push(storage, diffuse);
        for (uint32_t i = 0; i < 3; ++i) wet += early.tap(storage, earlyFrames[channel][i]) * earlyGains[i];
        early.push(storage, input); // Read the oldest tap before overwriting its slot.
        return wet;
    }
    void reset() {
        for (auto &comb : combs) { comb.delay.position = 0; comb.state = 0; }
        for (auto &delay : allpasses) delay.position = 0;
        predelay.position = early.position = 0;
    }
};
struct Biquad {
    double b0 = 0, b1 = 0, a1 = 0, a2 = 0;
    double first[2]{}, second[2]{};
    void configure(double cutoff, bool highpass) {
        const double tangent = std::tan(pi * cutoff / 32000);
        const double denominator = 1 + tangent / std::sqrt(.5) + tangent * tangent;
        b0 = (highpass ? 1 : tangent * tangent) / denominator;
        b1 = (highpass ? -2 : 2) * b0;
        a1 = 2 * (tangent * tangent - 1) / denominator;
        a2 = (1 - tangent / std::sqrt(.5) + tangent * tangent) / denominator;
    }
    float process(float input, uint32_t channel) {
        const double result = b0 * input + first[channel];
        first[channel] = b1 * input - a1 * result + second[channel];
        second[channel] = b0 * input - a2 * result;
        return normal(static_cast<float>(result));
    }
    void reset() { for (uint32_t ch = 0; ch < 2; ++ch) first[ch] = second[ch] = 0; }
};
void clear(LLGlueFrame *output, uint32_t frames) {
    if (output) for (uint32_t i = 0; i < frames; ++i) output[i] = LLGlueFrame{};
}
bool unitInterval(double value) {
    static_assert(sizeof(double) == sizeof(uint64_t) && std::numeric_limits<double>::is_iec559);
    uint64_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits <= UINT64_C(0x3ff0000000000000) || bits == UINT64_C(0x8000000000000000);
}
bool valid(const LLGlueFrame &frame) {
    // Check the raw Float32 duck range, including negative subnormals under host FTZ/DAZ.
    static_assert(sizeof(float) == sizeof(uint32_t) && std::numeric_limits<float>::is_iec559);
    uint32_t duck;
    std::memcpy(&duck, &frame.duck, sizeof(duck));
    if (duck > 0x3f800000u && duck != 0x80000000u) return false;
    for (uint32_t ch = 0; ch < 2; ++ch)
        if (!std::isfinite(frame.tonal[ch]) || std::abs(frame.tonal[ch]) > LL_ROOM_TONAL_LIMIT ||
            !std::isfinite(frame.bass[ch]) || !std::isfinite(frame.drums[ch])) return false;
    return true;
}
}

struct LLRoom {
    float storage[storageFrames]{};
    Channel channels[2];
    Biquad highpass, lowpass;
    float wetGain = 0;
};

LLRoom *ll_room_create(double space, double warmth) {
    FlushSubnormals mode;
    if (!unitInterval(space) || !unitInterval(warmth)) return nullptr;
    auto *room = new (std::nothrow) LLRoom;
    if (!room) return nullptr;
    uint32_t cursor = 0;
    const double decay = 1.65 + .85 * space;
    for (uint32_t ch = 0; ch < 2; ++ch) {
        auto &channel = room->channels[ch];
        for (uint32_t i = 0; i < 8; ++i) {
            channel.combs[i].delay.configure(cursor, combFrames[ch][i]);
            channel.combs[i].feedback = std::pow(10., -3. * combFrames[ch][i] / 32000 / decay);
        }
        for (uint32_t i = 0; i < 3; ++i) channel.allpasses[i].configure(cursor, allpassFrames[ch][i]);
        channel.predelay.configure(cursor, predelayFrames);
        channel.early.configure(cursor, earlyFrames[ch][2]);
    }
    room->highpass.configure(145, true);
    room->lowpass.configure(1700 - 700 * warmth, false);
    room->wetGain = static_cast<float>(.60 + .8 * space);
    return room;
}
void ll_room_destroy(LLRoom *room) { delete room; }
void ll_room_reset(LLRoom *room) {
    if (!room) return;
    for (auto &value : room->storage) value = 0;
    for (auto &channel : room->channels) channel.reset();
    room->highpass.reset(); room->lowpass.reset();
}
bool ll_room_process(LLRoom *room, const LLGlueFrame *input, LLGlueFrame *output, uint32_t frames) {
    FlushSubnormals mode;
    const auto a = reinterpret_cast<uintptr_t>(input), b = reinterpret_cast<uintptr_t>(output);
    const uint64_t bytes = uint64_t{frames} * sizeof(*input);
    if (!room || (frames && (!input || !output)) || (a <= b ? b - a < bytes : a - b < bytes)) {
        clear(output, frames); return false;
    }
    for (uint32_t i = 0; i < frames; ++i) if (!valid(input[i])) { clear(output, frames); return false; }
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset) {
            const auto &frame = input[offset];
            const float mid = (frame.tonal[0] + frame.tonal[1]) * .5f;
            const float side = (frame.tonal[0] - frame.tonal[1]) * .5f;
            output[offset] = frame;
            for (uint32_t ch = 0; ch < 2; ++ch) {
                const float excitation = mid + side * (ch ? -.55f : .55f);
                float wet = room->channels[ch].process(room->storage, excitation, ch);
                wet = room->highpass.process(wet, ch);
                wet = room->lowpass.process(wet, ch);
                output[offset].tonal[ch] = normal(frame.tonal[ch] * .92f + wet * room->wetGain);
            }
        }
    }
    return true;
}
