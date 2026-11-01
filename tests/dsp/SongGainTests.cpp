// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <array>
#include <cfenv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <vector>
#if defined(__x86_64__)
#include <xmmintrin.h>
#endif

static bool auditing = false;
static unsigned allocations = 0, deallocations = 0;
void *operator new(std::size_t bytes) {
    if (auditing) ++allocations;
    void *pointer = std::malloc(bytes ? bytes : 1);
    if (!pointer) std::abort();
    return pointer;
}
void *operator new[](std::size_t bytes) { return ::operator new(bytes); }
void *operator new(std::size_t bytes, const std::nothrow_t &) noexcept { return ::operator new(bytes); }
void *operator new[](std::size_t bytes, const std::nothrow_t &) noexcept { return ::operator new(bytes); }
void operator delete(void *pointer) noexcept { if (auditing) ++deallocations; std::free(pointer); }
void operator delete[](void *pointer) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }

static void require(bool condition, int line) {
    if (!condition) { std::fprintf(stderr, "Song gain assertion failed at line %d\n", line); std::abort(); }
}
#define CHECK(condition) require((condition), __LINE__)
static uint64_t floatingControl() {
#if defined(__aarch64__) || defined(__arm64__)
    uint64_t value; __asm__ volatile("mrs %0, fpcr" : "=r"(value)); return value;
#elif defined(__x86_64__)
    return _mm_getcsr();
#else
    return 0;
#endif
}
static void setFloatingControl(uint64_t value) {
#if defined(__aarch64__) || defined(__arm64__)
    __asm__ volatile("msr fpcr, %0" : : "r"(value) : "memory");
#elif defined(__x86_64__)
    _mm_setcsr(static_cast<unsigned>(value));
#else
    (void)value;
#endif
}
static uint64_t floatingStatus() {
#if defined(__aarch64__) || defined(__arm64__)
    uint64_t value; __asm__ volatile("mrs %0, fpsr" : "=r"(value)); return value;
#else
    return 0; // SSE control already includes its exception flags.
#endif
}
static void setFloatingStatus(uint64_t value) {
#if defined(__aarch64__) || defined(__arm64__)
    __asm__ volatile("msr fpsr, %0" : : "r"(value) : "memory");
#else
    (void)value;
#endif
}
static LLSongGain *create(double measured) {
    const auto control = floatingControl(), status = floatingStatus();
    auto *result = ll_song_gain_create(measured);
    CHECK(floatingControl() == control && floatingStatus() == status); return result;
}
static bool process(const LLSongGain *gain, const float *input, float *output, uint32_t frames) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_song_gain_process(gain, input, output, frames); auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
static bool get(const LLSongGain *gain, LLSongGainValues *values) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_song_gain_get(gain, values); auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
struct Gain {
    LLSongGain *value;
    explicit Gain(double measured = -30.318919941908316) : value(create(measured)) { CHECK(value); }
    ~Gain() { ll_song_gain_destroy(value); }
    Gain(const Gain &) = delete; Gain &operator=(const Gain &) = delete;
    LLSongGainValues values() const { LLSongGainValues result{}; CHECK(get(value, &result)); return result; }
};
static uint32_t bits(float value) { uint32_t result; std::memcpy(&result, &value, sizeof(result)); return result; }
static bool same(const LLSongGainValues &a, const LLSongGainValues &b) { return std::memcmp(&a, &b, sizeof(a)) == 0; }
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
static bool zero(float value) { return value == 0; }
static std::vector<float> source(uint32_t frames) {
    std::vector<float> result(2 * frames);
    for (uint32_t i = 0; i < frames; ++i) { result[2 * i] = float(int(i % 31) - 15) / 64; result[2 * i + 1] = float(int(i % 17) - 8) / 32; }
    return result;
}
static std::vector<float> render(const Gain &gain, const std::vector<float> &input, const std::vector<uint32_t> &partitions) {
    std::vector<float> output(input.size() + 1, 7); std::size_t offset = 0, block = 0;
    while (offset < input.size() / 2) {
        const auto count = std::min(uint32_t(input.size() / 2 - offset), partitions[block++ % partitions.size()]);
        CHECK(process(gain.value, input.data() + 2 * offset, output.data() + 2 * offset, count)); offset += count;
    }
    CHECK(output.back() == 7); output.pop_back(); return output;
}
static void originalProbes() {
    // Captured from unchanged render_song before native comparisons; .1 and the
    // small probe distinguish its strong np.float64 scale from a Float factor.
    struct Probe { double measured, decibels, multiplier; uint32_t large, small; };
    const Probe probes[]{
        {-70, 49.5, 298.538261891796, 1106171043u, 1032070207u},
        {-20.5, 0, 1, 1036831949u, 962764857u},
        {0, -20.5, .09440608762859236, 1008381129u, 933963949u},
        {120, -140.5, 9.440608762859226e-8, 841101373u, 766736670u},
        {-30.318919941908316, 9.818919941908316, 3.0970341705847546, 0x3e9e9172u, 0x3a2f778eu}
    };
    const std::vector<float> input{.1f, -.1f, .00021612727141473442f, -.00021612727141473442f};
    for (const auto &probe : probes) {
        Gain gain(probe.measured); const auto values = gain.values(); const auto output = render(gain, input, {1});
        CHECK(std::abs(values.gain_db - probe.decibels) <= 1e-12);
        CHECK(std::abs(values.linear_multiplier - probe.multiplier) <= probe.multiplier * 2e-15);
        CHECK(bits(output[0]) == probe.large && bits(output[1]) == (probe.large | 0x80000000u));
        CHECK(bits(output[2]) == probe.small && bits(output[3]) == (probe.small | 0x80000000u));
    }
}
static void partitionAndDomain() {
    CHECK(LL_SONG_GAIN_INPUT_LIMIT == 1e6f); Gain gain; const auto values = gain.values();
    for (const uint32_t frames : {1u, 2u, 7u, 255u, 256u, 257u, 1025u, 8193u, 65537u}) {
        const auto input = source(frames), expected = render(gain, input, {frames});
        CHECK(same(expected, render(gain, input, {1, 17, 256, 1023}))); CHECK(same(values, gain.values()));
    }
    Gain unity(-20.5); const std::vector<float> exact{-0.f, 0.f, 1e6f, -1e6f, .1234567f, 1e-7f};
    const auto unchanged = render(unity, exact, {1});
    CHECK(std::memcmp(exact.data(), unchanged.data(), exact.size() * sizeof(float)) == 0);
    Gain maximum(-70); const auto amplified = render(maximum, exact, {3});
    CHECK(maximum.values().gain_db == 49.5 && maximum.values().linear_multiplier < 299);
    CHECK(amplified[2] > 2.98e8f && amplified[2] < 3e8f && amplified[3] == -amplified[2]);
    Gain tiny(6000); CHECK(tiny.values().linear_multiplier > 0);
    const auto attenuated = render(tiny, exact, {3}); CHECK(std::all_of(attenuated.begin(), attenuated.end(), zero));
}
static void invalidInputsAndPointers() {
    const double infinity = std::numeric_limits<double>::infinity();
    for (const double measured : {-infinity, infinity, std::numeric_limits<double>::quiet_NaN(),
                                  std::nextafter(-70., -INFINITY), 10000., std::numeric_limits<double>::max()}) CHECK(!create(measured));
    ll_song_gain_destroy(nullptr); Gain gain; const auto prepared = gain.values();
    LLSongGainValues values{7, 7}; CHECK(!get(nullptr, &values) && same(values, LLSongGainValues{})); CHECK(!get(gain.value, nullptr));
    CHECK(process(gain.value, nullptr, nullptr, 0)); float output[5]{7, 7, 7, 7, 7};
    CHECK(!process(nullptr, nullptr, output, 2) && output[0] == 0 && output[3] == 0 && output[4] == 7);
    const auto input = source(1025); const auto expected = render(gain, input, {1025});
    CHECK(!process(gain.value, input.data(), nullptr, 1)); CHECK(!process(gain.value, nullptr, output, 2));
    for (uint32_t channel = 0; channel < 2; ++channel) for (const float value : {
            INFINITY, -INFINITY, std::numeric_limits<float>::quiet_NaN(),
            std::nextafter(LL_SONG_GAIN_INPUT_LIMIT, INFINITY), -std::nextafter(LL_SONG_GAIN_INPUT_LIMIT, INFINITY)}) {
        auto invalid = input; invalid[invalid.size() - 2 + channel] = value;
        std::vector<float> cleared(invalid.size() + 1, 7);
        CHECK(!process(gain.value, invalid.data(), cleared.data(), 1025));
        CHECK(std::all_of(cleared.begin(), cleared.end() - 1, zero) && cleared.back() == 7);
        CHECK(same(prepared, gain.values()) && same(expected, render(gain, input, {17, 256})));
    }
    for (const auto offsets : {std::array<unsigned, 2>{0, 0}, {0, 1}, {1, 0}, {0, 3}}) {
        std::array<float, 12> shared{}; shared.fill(7);
        CHECK(!process(gain.value, shared.data() + offsets[0], shared.data() + offsets[1], 2));
        for (unsigned i = 0; i < shared.size(); ++i) CHECK(shared[i] == (i >= offsets[1] && i < offsets[1] + 4 ? 0 : 7));
    }
    struct Adjacent { float input[4], output[4]; } adjacent{{.125f, -.25f, .5f, -.125f}, {}};
    CHECK(process(gain.value, adjacent.input, adjacent.output, 2));
    struct Reverse { float output[4], input[4]; } reverse{{}, {.125f, -.25f, .5f, -.125f}};
    CHECK(process(gain.value, reverse.input, reverse.output, 2)); CHECK(std::memcmp(adjacent.output, reverse.output, sizeof(adjacent.output)) == 0);
    CHECK(process(gain.value, output, output, 0) && same(prepared, gain.values()));
}
static void floatingModes() {
    const auto original = floatingControl(), originalStatus = floatingStatus(); const int originalRounding = std::fegetround();
#if defined(__aarch64__) || defined(__arm64__)
    const uint64_t flushMask = uint64_t{1} << 24, statusMask = 0;
#elif defined(__x86_64__)
    const uint64_t flushMask = 0x8040, statusMask = 0x3f;
#else
    const uint64_t flushMask = 0, statusMask = 0;
#endif
    Gain reference; const auto input = source(1025), expected = render(reference, input, {1025}); const auto prepared = reference.values();
    for (const int mode : {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO}) {
        CHECK(std::fesetround(mode) == 0); const auto rounded = floatingControl();
        for (const uint64_t flush : {uint64_t{0}, flushMask}) for (const uint64_t flags : {uint64_t{0}, uint64_t{1}}) {
            setFloatingControl((rounded & ~(flushMask | statusMask)) | flush | (flags & statusMask)); setFloatingStatus(flags);
            Gain gain; CHECK(same(prepared, gain.values()) && same(expected, render(gain, input, {1, 257})));
            CHECK(!create(10000)); float bad[4]{0, 0, 0, INFINITY}, output[4]{7, 7, 7, 7};
            CHECK(!process(gain.value, bad, output, 2) && std::all_of(output, output + 4, zero));
            CHECK(std::fegetround() == mode);
        }
    }
    CHECK(std::fesetround(originalRounding) == 0); setFloatingControl(original); setFloatingStatus(originalStatus);
    Gain gain; const auto tiny = std::numeric_limits<float>::denorm_min(); float inputTiny[2]{tiny, -tiny}, output[2]{};
    CHECK(process(gain.value, inputTiny, output, 1) && output[0] == 0 && output[1] == 0);
}
int main() {
    originalProbes(); partitionAndDomain(); invalidInputsAndPointers(); floatingModes();
    std::puts("Song gain frozen math/staging, partitions, domains/aliases, FP restoration and allocation audits passed");
}
