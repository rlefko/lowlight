// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include "../../Packages/LowlightAudio/Sources/CLowlightDSP/NumpyRandom.h"
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
    if (!condition) { std::fprintf(stderr, "Quiet air assertion failed at line %d\n", line); std::abort(); }
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
static uint32_t bits(float value) { uint32_t result; std::memcpy(&result, &value, sizeof(result)); return result; }
static uint64_t hashFloat(uint64_t hash, float value) {
    const uint32_t word = bits(value);
    for (uint32_t shift = 0; shift < 32; shift += 8) { hash ^= (word >> shift) & 255; hash *= 1099511628211ULL; }
    return hash;
}
static void randomVectors() {
    // Frozen from pinned NumPy 2.3.5, independently of this implementation.
    struct Vector { uint32_t seed; uint64_t raw[8], hashes[2]; uint32_t first[2][16]; };
    const Vector vectors[] = {
        {0,
            {0x4878219abc2b5007ULL, 0xe90635315b0fbceaULL, 0xd1be9f5d1af903deULL, 0x4ae2f9c8d0e2617aULL, 0xd5b8fcfe80f01226ULL, 0xe794ddfd283fe529ULL, 0x48c3c686d4f36142ULL, 0xe49e15e6d49ed594ULL},
            {0xabcd51cc5bb979eeULL, 0x3b66e5a1df57a2a3ULL}, {
                {0x3dfb4e16u, 0x3f39780cu, 0xbfa7f3b0u, 0xbf023085u, 0x3f196204u, 0xbe5cc54eu, 0xbe9bcb21u, 0xbe7757d1u, 0xbf1ef44fu, 0xbf17a27cu, 0x3f28b8f2u, 0x3f3d8051u, 0x3da14e42u, 0x3fb45566u, 0xbf556fb3u, 0x3f192f01u},
                {0xbed972f6u, 0x3f23d323u, 0xbfa13f02u, 0x3f983911u, 0x3f3b8dedu, 0x3f345699u, 0xbff0a80cu, 0xbfe36d04u, 0x3fe88922u, 0xbfd19228u, 0x3efc0e2bu, 0x3eac5d03u, 0xc044bbb4u, 0xbeabafa1u, 0xbe3bd5e9u, 0x3da5d213u},
            }},
        {1,
            {0x99d23e1572f477f9ULL, 0x136b0708f5c28193ULL, 0x59ae9f5b7d86f995ULL, 0x5567c9cf674df7bfULL, 0x09b8ddffa1d55167ULL, 0xdb833629b19db45aULL, 0x08f625e0405d4beeULL, 0x00b3456aa351179aULL},
            {0x34fcadfe62d7fc9bULL, 0xb62a86f1c30d8ea8ULL}, {
                {0xc01c5d7cu, 0xbf817770u, 0xbfacb1e2u, 0xbfaca685u, 0xbed4be55u, 0x3f8cdd33u, 0xbf3e6f40u, 0xbd19eb31u, 0xbe808903u, 0xbe55517cu, 0xbec98fb7u, 0x3fb4f944u, 0x3f24607cu, 0xbe51a44eu, 0xbfb4a68du, 0xbf57cb84u},
                {0x3fd309bdu, 0x3fbc21d7u, 0xbf3beca6u, 0x3c9f141au, 0xbf81e52au, 0xbf15a760u, 0xbd04d1e5u, 0x3f8512a0u, 0x3d91d127u, 0x3eb41785u, 0xbde8f0d2u, 0xbed41d80u, 0x3f8fbc28u, 0x3f8c3dc0u, 0xbf4bf568u, 0x3e403dfcu},
            }},
        {1278560406,
            {0x98b6b37a04e71871ULL, 0x25ed8a8b8fbfb1adULL, 0xc2f583efc208f018ULL, 0xa4c78d2a199a0464ULL, 0xea50f477edd10acfULL, 0xd566a77248b0765bULL, 0xca2ec3c9a5128bc6ULL, 0xd8e679d2c0edce04ULL},
            {0x521ea49e5563593dULL, 0x9d1dedcfce2b9c2eULL}, {
                {0x3f8dcef2u, 0xbeb09b04u, 0x3d8ba542u, 0x3e4e18f1u, 0x3f33ba1du, 0x3f5c4f66u, 0xbf29b777u, 0x3e95733bu, 0x3f84dac1u, 0xbf5242feu, 0x3f3803b3u, 0x3eac0953u, 0x3f7182b0u, 0xbe10b910u, 0x3f5fe9d1u, 0x3e4ae304u},
                {0xbe4dd8fdu, 0x3ee01962u, 0xbd89c459u, 0x3ef66f72u, 0xbeca7fdeu, 0x3f3bab5fu, 0x3d1ddae3u, 0xbf1e4ddeu, 0x3dc1cd19u, 0x3f4e08ddu, 0xbe927821u, 0xbe9a3a41u, 0xbdd6dc62u, 0xbf1725b0u, 0xbf1efe48u, 0x40009605u},
            }},
        {2147483647,
            {0xa7117225a9307a9cULL, 0xd3cec553739418b9ULL, 0xa3ca5e1ad0ddbc09ULL, 0x44fdd23b23baa8ebULL, 0xf947259e1a6208dbULL, 0x773e7ab0b44b4cf2ULL, 0x51dec1877515bc8fULL, 0x2afe3eef7a10ec77ULL},
            {0x7149b05e971bc38aULL, 0xc684fffaf475fa10ULL}, {
                {0x3ec3d95au, 0x3f9b7d69u, 0x3d7729f8u, 0x3eced03eu, 0x3feb03c1u, 0x400059e1u, 0x3f6a41cau, 0x3f01b0fau, 0x3e9e5f4du, 0x3ee00f68u, 0x3f66248fu, 0x3fcf4ec0u, 0x3f1b340eu, 0xbfdc080eu, 0xbfd9743du, 0xbf819e7eu},
                {0x3ee21030u, 0x3ea51e03u, 0x3f3f625fu, 0x3fd841e0u, 0xbf3a00cfu, 0x3e77c02bu, 0x3f982b2fu, 0xbf09f475u, 0x3e9a61dbu, 0xbfaf6f22u, 0xbf838a29u, 0xbf3f3f72u, 0x3f7719a4u, 0x3f9aa552u, 0xbe693815u, 0x3de2b8e4u},
            }},
    };
    for (const auto &v : vectors) {
        lowlight::NumpyRandom raw(v.seed), normal(v.seed);
        for (const auto expected : v.raw) CHECK(raw.nextRaw() == expected);
        auto checkpoint = normal;
        for (uint32_t channel = 0; channel < 2; ++channel) {
            if (channel) checkpoint = normal;
            uint64_t hash = 14695981039346656037ULL;
            for (uint32_t i = 0; i < 16385; ++i) {
                float value = 7; auditing = true; const bool ok = normal.nextFloat(value); auditing = false;
                CHECK(ok && allocations == 0 && deallocations == 0);
                if (i < 16) CHECK(bits(value) == v.first[channel][i]);
                hash = hashFloat(hash, value);
            }
            CHECK(hash == v.hashes[channel]);
        }
        uint64_t hash = 14695981039346656037ULL;
        for (uint32_t i = 0; i < 16385; ++i) {
            double value; CHECK(checkpoint.nextDoubleNormal(value)); hash = hashFloat(hash, float(value));
        }
        CHECK(hash == v.hashes[1]); // Right begins after all left draws, including rejections.
    }
}
struct WordSource {
    const uint64_t *words; uint32_t count, position = 0;
    static uint64_t next(void *context) {
        auto &source = *static_cast<WordSource *>(context);
        CHECK(source.position < source.count); return source.words[source.position++];
    }
};
static void randomBranchesAndExhaustion() {
    // Expected bits/draw counts invoke NumPy's unchanged compiled random_standard_normal.
    struct Branch { uint64_t words[5]; uint32_t draws, expected; };
    const Branch branches[] = {
        {{0x0200000000000080ULL}, 1, 0x3dc4861bu}, // fast-positive
        {{0x0200000000000180ULL}, 1, 0xbdc4861bu}, // fast-negative
        {{0x1000000000000001ULL, 0x0000000000000000ULL}, 2, 0x3ddc685fu}, // wedge-accept
        {{0x1ffffffffffffe01ULL, 0xffffffffffffffffULL, 0x0200000000000080ULL}, 3, 0x3dc4861bu}, // wedge-reject-then-fast
        {{0x1ffffffffffffe00ULL, 0x8000000000000000ULL, 0x8000000000000000ULL}, 3, 0xc076017bu}, // tail-negative
        {{0x1ffffffffffdfe00ULL, 0x0000000000000000ULL, 0x0000000000000000ULL, 0x8000000000000000ULL, 0x8000000000000000ULL}, 5, 0x4076017bu}, // tail-retry-positive
    };
    for (const auto &branch : branches) {
        WordSource source{branch.words, branch.draws}; double value = 7;
        CHECK(lowlight::detail::boundedDoubleNormal(&source, WordSource::next, value));
        CHECK(source.position == branch.draws && bits(float(value)) == branch.expected);
    }
    uint64_t words[64]; std::fill_n(words, 64, UINT64_MAX);
    WordSource wedge{words, 64}; double value = 7;
    CHECK(!lowlight::detail::boundedDoubleNormal(&wedge, WordSource::next, value));
    CHECK(wedge.position == 64 && value == 0); // Outer rejection and its uniforms share one budget.
    words[0] = UINT64_MAX & ~uint64_t{255};
    for (uint32_t i = 1; i < 64; ++i) words[i] = i % 2 ? UINT64_MAX : 0;
    WordSource tail{words, 64}; value = 7;
    CHECK(!lowlight::detail::boundedDoubleNormal(&tail, WordSource::next, value));
    CHECK(tail.position == 64 && value == 0); // The partial last uniform pair cannot overrun the cap.
    CHECK(!lowlight::detail::boundedDoubleNormal(nullptr, nullptr, value) && value == 0);
}

static const LLRackFades flat{0, 0, double((uint64_t{1} << 52) - 1), double(uint64_t{1} << 52), 0, double(uint64_t{1} << 52)};
static bool add(LLAir *air, float *buffer, uint32_t frames) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_air_add(air, buffer, frames); auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
static LLAir *create(uint32_t seed, uint32_t count, uint64_t origin, double texture, const LLRackFades *fades) {
    const auto control = floatingControl(), status = floatingStatus();
    auto *result = ll_air_create(seed, count, origin, texture, fades);
    CHECK(floatingControl() == control && floatingStatus() == status); return result;
}
struct Air {
    LLAir *value;
    explicit Air(uint32_t frames, uint32_t seed = 0, double texture = .09, uint64_t origin = 0,
                 const LLRackFades &fades = flat) : value(create(seed, frames, origin, texture, &fades)) { CHECK(value); }
    ~Air() { ll_air_destroy(value); }
    Air(const Air &) = delete; Air &operator=(const Air &) = delete;
    void reset() {
        const auto control = floatingControl(), status = floatingStatus(); auditing = true;
        ll_air_reset(value); auditing = false;
        CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    }
};
static bool zero(float value) { return value == 0; }
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
static std::vector<float> input(uint32_t count) {
    std::vector<float> result(2 * count);
    for (uint32_t i = 0; i < count; ++i) {
        result[2 * i] = float(int(i % 19) - 9) / 128; result[2 * i + 1] = float(int(i % 13) - 6) / 256;
    }
    return result;
}
static std::vector<float> render(Air &air, std::vector<float> samples, const std::vector<uint32_t> &blocks = {256}) {
    uint32_t offset = 0; std::size_t block = 0;
    while (offset < samples.size() / 2) {
        const uint32_t count = std::min(uint32_t(samples.size() / 2) - offset, blocks[block++ % blocks.size()]);
        CHECK(add(air.value, samples.data() + 2 * offset, count)); offset += count;
    }
    CHECK(std::all_of(samples.begin(), samples.end(), [](float x) { return std::isfinite(x); }));
    return samples;
}
static void independentRoundingProbes() {
    // Captured from unchanged v9 air; these samples differ by one ULP if either
    // normalization uses a Double product or air is rounded before adding the carrier.
    const LLRackFades tinyFades{4096, 4098.375, 4097.25, 4101.75, 4096, 4101.75};
    Air tiny(7, 2147483647, 1, 4096, tinyFades);
    const auto normalized = render(tiny, std::vector<float>(14));
    CHECK(bits(normalized[2 * 3]) == 0x393fd5dau);
    CHECK(bits(normalized[2 * 4]) == 0x3937973cu);
    CHECK(bits(normalized[2 * 5]) == 0x38f4f839u);
    const LLRackFades fades{0, 2730.375, 2047.25, 8189.75, 0, 8189.75};
    Air air(8191, 0, 1, 0, fades);
    std::vector<float> carrier(2 * 8191);
    for (uint32_t i = 0; i < 8191; ++i)
        for (uint32_t channel = 0; channel < 2; ++channel)
            carrier[2 * i + channel] = float(int((i * 17 + channel * 11) % 31) - 15) / 256;
    const auto combined = render(air, carrier, {1, 257, 511});
    CHECK(bits(combined[2 * 187]) == 0x3bff9887u);
    CHECK(bits(combined[2 * 401]) == 0x3d503fc5u);
    CHECK(bits(combined[2 * 827 + 1]) == 0x3d4144e1u);
}
static void lifecycleAndPartitioning() {
    for (const uint32_t count : {1u, 2u, 7u, 8u, 127u, 128u, 129u, 255u, 256u, 257u,
                                 1023u, 1024u, 1025u, 8191u, 8192u, 8193u, 65537u}) {
        const auto source = input(count); Air air(count, 1278560406, .4);
        const auto whole = render(air, source, {count}); CHECK(!same(whole, source));
        CHECK(add(air.value, nullptr, 0)); float after[2]{7, 7};
        CHECK(!add(air.value, after, 1) && after[0] == 0 && after[1] == 0);
        air.reset(); CHECK(same(whole, render(air, source, {1, 17, 255, 256, 257, 1023})));
        air.reset(); auto prefix = input(std::min(37u, count)); render(air, prefix); air.reset();
        CHECK(same(whole, render(air, source, {513})));
    }
    Air muted(4097, 0, 0); const auto source = input(4097); CHECK(same(source, render(muted, source)));
    Air extreme(2, 0, 1); std::vector<float> large(4, std::numeric_limits<float>::max());
    large[1] = -large[1]; large[3] = -large[3]; CHECK(same(large, render(extreme, large)));
    Air maximum(LL_AIR_MAX_FRAMES, 2147483647, .1, (uint64_t{1} << 52) - LL_AIR_MAX_FRAMES);
    CHECK(add(maximum.value, nullptr, 0)); render(maximum, input(2)); maximum.reset();
}
static void invalidSetupAndRollback() {
    constexpr uint32_t count = 4097, prefix = 513, batch = 257;
    for (const uint32_t length : {0u, uint32_t(LL_AIR_MAX_FRAMES + 1), UINT32_MAX})
        CHECK(!create(0, length, 0, .5, &flat));
    CHECK(!create(uint32_t{1} << 31, 1, 0, .5, &flat)); CHECK(!create(UINT32_MAX, 1, 0, .5, &flat));
    CHECK(!create(0, 1, uint64_t{1} << 52, .5, &flat) && !create(0, 1, UINT64_MAX, .5, &flat));
    CHECK(!create(0, 1, 0, .5, nullptr));
    for (const double texture : {-1., -std::numeric_limits<double>::denorm_min(), 1.01,
            std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()})
        CHECK(!create(0, 1, 0, texture, &flat));
    auto badFade = flat; badFade.tonal_out_end_frame = badFade.tonal_out_start_frame;
    CHECK(!create(0, 1, 0, .5, &badFade));
    badFade = flat; badFade.rhythm_out_frame = std::numeric_limits<double>::quiet_NaN();
    CHECK(!create(0, 1, 0, .5, &badFade));
    ll_air_reset(nullptr); ll_air_destroy(nullptr); float clearing[4]{7, 7, 7, 7};
    CHECK(!add(nullptr, clearing, 2) && std::all_of(clearing, clearing + 4, zero));
    const auto source = input(count); Air reference(count); const auto expected = render(reference, source);
    for (const float invalid : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                                -std::numeric_limits<float>::infinity()}) {
        for (uint32_t channel = 0; channel < 2; ++channel) {
            Air air(count); auto actual = source; CHECK(add(air.value, actual.data(), prefix));
            std::vector<float> attempt(source.begin() + 2 * prefix, source.begin() + 2 * (prefix + batch));
            attempt[2 * (batch - 1) + channel] = invalid;
            CHECK(!add(air.value, attempt.data(), batch) && std::all_of(attempt.begin(), attempt.end(), zero));
            CHECK(!add(air.value, nullptr, 1));
            std::vector<float> overrun(2 * (count - prefix + 1), 7);
            CHECK(!add(air.value, overrun.data(), count - prefix + 1));
            CHECK(std::all_of(overrun.begin(), overrun.end(), zero));
            CHECK(add(air.value, actual.data() + 2 * prefix, count - prefix)); CHECK(same(actual, expected));
        }
    }
}
static void originFadesAndChannelOrder() {
    constexpr uint32_t count = 8193;
    const uint64_t origin = (uint64_t{1} << 52) - count;
    LLRackFades local{0, 2048, 4096, 8192, 0, 6000};
    LLRackFades shifted{double(origin), double(origin + 2048), double(origin + 4096), double(origin + 8192), 0, 0};
    Air a(count, 1, .5, 0, local), b(count, 1, .5, origin, shifted);
    local.tonal_out_end_frame = 1; shifted.tonal_out_end_frame = 1; // Both descriptors were copied.
    const auto source = input(count), one = render(a, source), two = render(b, source, {1, 257, 511});
    CHECK(same(one, two)); // Absolute fade placement changes; RNG and modulation remain song-local.
    CHECK(one[0] == source[0] && one[1] == source[1] && one[2 * 8192] == source[2 * 8192]);
    Air stereo(count, 1, .5); const auto noise = render(stereo, std::vector<float>(2 * count));
    bool channelsDiffer = false;
    for (uint32_t i = 0; i < count; ++i) channelsDiffer |= noise[2 * i] != noise[2 * i + 1];
    CHECK(channelsDiffer);
}
static void floatingModes() {
    const auto original = floatingControl(), originalStatus = floatingStatus();
    const int originalRounding = std::fegetround();
#if defined(__aarch64__) || defined(__arm64__)
    const uint64_t flushMask = uint64_t{1} << 24;
#elif defined(__x86_64__)
    const uint64_t flushMask = 0x8040;
#else
    const uint64_t flushMask = 0;
#endif
    auto source = input(1025); source[0] = std::numeric_limits<float>::denorm_min();
    Air reference(1025, 123456789, .4); const auto expected = render(reference, source);
    for (const int rounding : {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO}) {
        CHECK(std::fesetround(rounding) == 0);
        const auto roundedControl = floatingControl();
        for (const uint64_t flush : {uint64_t{0}, flushMask}) {
            setFloatingControl((roundedControl & ~flushMask) | flush);
            setFloatingStatus(1); Air air(1025, 123456789, .4);
            CHECK(same(expected, render(air, source, {1, 255, 256, 513}))); air.reset();
            auto rejected = source; rejected.back() = std::numeric_limits<float>::infinity();
            CHECK(!add(air.value, rejected.data(), 1025));
            CHECK(same(expected, render(air, source)));
            CHECK(!create(0, 1, 0, -std::numeric_limits<double>::denorm_min(), &flat));
            CHECK(std::fegetround() == rounding);
        }
    }
    CHECK(std::fesetround(originalRounding) == 0);
    setFloatingControl(original); setFloatingStatus(originalStatus);
}
int main() {
    randomVectors(); randomBranchesAndExhaustion(); lifecycleAndPartitioning(); invalidSetupAndRollback();
    originFadesAndChannelOrder(); independentRoundingProbes(); floatingModes();
    std::puts("Quiet air RNG, rejection bounds, finite preparation/replay, origin/fades, FP and allocation audits passed");
}
