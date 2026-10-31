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
    if (!condition) { std::fprintf(stderr, "Song mix assertion failed at line %d\n", line); std::abort(); }
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
static const LLRackFades flat{0, 0, double((uint64_t{1} << 52) - 1), double(uint64_t{1} << 52), 0, 0};
static bool process(LLSongMix *mix, const LLGlueFrame *input, float *output, uint32_t frames) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_song_mix_process(mix, input, output, frames); auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
static LLSongMix *create(uint32_t seed, uint32_t frames, uint64_t origin, double texture, const LLRackFades *fades) {
    const auto control = floatingControl(), status = floatingStatus();
    auto *result = ll_song_mix_create(seed, frames, origin, texture, fades);
    CHECK(floatingControl() == control && floatingStatus() == status); return result;
}
struct Mix {
    LLSongMix *value;
    explicit Mix(uint32_t frames, double texture = .3, uint32_t seed = 1278560406, uint64_t origin = 0,
                 const LLRackFades &fades = flat) : value(create(seed, frames, origin, texture, &fades)) { CHECK(value); }
    ~Mix() { ll_song_mix_destroy(value); }
    Mix(const Mix &) = delete; Mix &operator=(const Mix &) = delete;
    void reset() {
        const auto control = floatingControl(), status = floatingStatus(); auditing = true;
        ll_song_mix_reset(value); auditing = false;
        CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    }
};
static bool zero(float value) { return value == 0; }
static uint32_t bits(float value) { uint32_t result; std::memcpy(&result, &value, sizeof(result)); return result; }
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
static std::vector<LLGlueFrame> inputs(uint32_t count) {
    std::vector<LLGlueFrame> result(count);
    for (uint32_t i = 0; i < count; ++i) {
        const float left = float(int(i % 31) - 15) / 64, right = float(int(i % 17) - 8) / 32;
        result[i] = {{left, right}, {right / 2, -left / 2}, {left / 4, right / 4}, float(i % 5) / 4};
    }
    return result;
}
static std::vector<float> render(Mix &mix, const std::vector<LLGlueFrame> &input,
                                 const std::vector<uint32_t> &blocks = {256}) {
    std::vector<float> result(2 * input.size() + 1, 7); uint32_t offset = 0; std::size_t block = 0;
    while (offset < input.size()) {
        const uint32_t frames = std::min(uint32_t(input.size()) - offset, blocks[block++ % blocks.size()]);
        CHECK(process(mix.value, input.data() + offset, result.data() + 2 * offset, frames)); offset += frames;
    }
    CHECK(result.back() == 7); result.pop_back();
    CHECK(std::all_of(result.begin(), result.end(), [](float x) { return std::isfinite(x); })); return result;
}
static void originalProbes() {
    // Frozen directly from unchanged session_render.render_song after HP32.
    const LLRackFades firstFades{0, 0, 0, 1, 0, 1}, secondFades{0, 0, 0, 2, 0, 2};
    Mix first(1, 0, 0, 0, firstFades);
    const auto one = render(first, {{{.5f, -.25f}, {.125f, -.0625f}, {.03125f, .015625f}, .5f}});
    CHECK(bits(one[0]) == 0x3eaf3844u && bits(one[1]) == 0xbe0f5c95u);
    Mix second(2, 1, 2147483647, 0, secondFades);
    const auto two = render(second, {{{.03125f, -.015625f}, {.0078125f, 0}, {0, .00390625f}, .9375f},
                                    {{0, .03125f}, {-.0078125f, 0}, {.001953125f, 0}, .75f}}, {1});
    CHECK(bits(two[0]) == 0x3d15c3bau && bits(two[1]) == 0xbc2dd37du);
    CHECK(bits(two[2]) == 0xbb7c6a05u && bits(two[3]) == 0x3cc38df2u);
    std::vector<LLGlueFrame> input(32000, LLGlueFrame{{}, {}, {}, 1});
    input[0].tonal[0] = .5f; input[257].tonal[1] = -.25f;
    input.back().drums[0] = .03125f; input.back().drums[1] = -.015625f;
    Mix impulse(32000, 0); const auto output = render(impulse, input, {1, 257, 1023});
    struct Probe { uint32_t frame; float left, right; };
    const Probe probes[] = {
        {0, .49778348207473755f, 0}, {1, -.004423158708959818f, 0},
        {257, -.0005899455863982439f, -.24889174103736877f},
        {512, .000295679405098781f, .00030337541829794645f},
        {999, 1.4199405995896086e-5f, -8.122546569211408e-5f},
        {3330, 1.020072470936384e-9f, 1.2163726692548948e-9f},
    };
    for (const auto &probe : probes) {
        CHECK(std::abs(output[2 * probe.frame] - probe.left) <= std::max(1e-14f, std::abs(probe.left) * 2e-6f));
        CHECK(std::abs(output[2 * probe.frame + 1] - probe.right) <= std::max(1e-14f, std::abs(probe.right) * 2e-6f));
    }
}
static void stagingAndDuckRouting() {
    constexpr uint32_t count = 1025;
    // Exact mathematical counterexample: a Double/fused bus expression gives .5,
    // while the reference's three distinct Float operations give zero.
    std::vector<LLGlueFrame> rounded(count, LLGlueFrame{{16777216, -16777216}, {1, -1}, {-8388608, 8388608}, .5f});
    Mix staging(count, 0); const auto zeroMix = render(staging, rounded);
    CHECK(std::all_of(zeroMix.begin(), zeroMix.end(), zero));
    const auto source = inputs(count);
    auto dry = source, ducked = source;
    for (uint32_t i = 0; i < count; ++i) {
        dry[i] = LLGlueFrame{{}, {}, {source[i].drums[0], source[i].drums[1]}, 1};
        ducked[i].duck = 0;
    }
    ducked[0].duck = -0.f;
    ducked[1].duck = std::numeric_limits<float>::denorm_min();
    Mix drums(count, 0), mutedHarmony(count, 0);
    CHECK(same(render(drums, dry), render(mutedHarmony, ducked))); // Drums bypass duck.
    for (auto &frame : dry) frame = LLGlueFrame{{}, {}, {}, 1};
    for (auto &frame : ducked) frame = LLGlueFrame{{}, {}, {}, 0};
    Mix unkeyedAir(count, 1), keyedAir(count, 1);
    const auto noise = render(unkeyedAir, dry);
    CHECK(!std::all_of(noise.begin(), noise.end(), zero));
    CHECK(same(noise, render(keyedAir, ducked))); // Air also bypasses duck.
}
static void lifecycleAndPartitioning() {
    for (const uint32_t count : {1u, 2u, 7u, 127u, 128u, 129u, 255u, 256u, 257u,
                                 398u, 399u, 400u, 401u, 1025u, 8193u, 65537u}) {
        const auto input = inputs(count); Mix mix(count);
        const auto expected = render(mix, input, {count}); CHECK(process(mix.value, nullptr, nullptr, 0));
        float failed[3]{7, 7, 7};
        CHECK(!process(mix.value, input.data(), failed, 1)); CHECK(failed[0] == 0 && failed[1] == 0 && failed[2] == 7);
        mix.reset(); CHECK(same(expected, render(mix, input, {1, 17, 255, 256, 257, 1023})));
        mix.reset(); std::vector<float> partial(2 * count);
        CHECK(process(mix.value, input.data(), partial.data(), std::min(count, 317u)));
        mix.reset(); CHECK(same(expected, render(mix, input)));
    }
    // Continuous HP state must ring beyond silence and the air fade; reset discards it.
    constexpr uint32_t count = 65537;
    std::vector<LLGlueFrame> pulse(count, LLGlueFrame{{}, {}, {}, 1});
    for (uint32_t i = 0; i < 4096; ++i) pulse[i].drums[0] = .5f;
    const LLRackFades fades{0, 0, 0, 1, 0, 0}; Mix hp(count, 0, 0, 0, fades);
    const auto response = render(hp, pulse, {257, 17, 1023});
    CHECK(response[0] > .49f && response[0] < .5f);
    CHECK(std::abs(response[2 * 4095]) < 1e-7f && std::abs(response[2 * 4096]) > .49f);
    CHECK(response[2 * 4500] != 0 && std::abs(response[2 * 8000]) < 1e-7f);
    for (uint32_t i = 0; i < count; ++i) CHECK(response[2 * i + 1] == 0); // No cross-channel HP state.
    hp.reset(); for (auto &frame : pulse) frame.drums[0] = 0;
    const auto silent = render(hp, pulse); CHECK(std::all_of(silent.begin(), silent.end(), zero));
}
static float &field(LLGlueFrame &frame, uint32_t index) {
    if (index < 2) return frame.tonal[index];
    if (index < 4) return frame.bass[index - 2];
    if (index < 6) return frame.drums[index - 4];
    return frame.duck;
}
static void invalidSetupAndRollback() {
    CHECK(LL_SONG_MIX_BUS_LIMIT == 1e20f);
    for (const uint32_t count : {0u, uint32_t(LL_AIR_MAX_FRAMES) + 1, UINT32_MAX})
        CHECK(!create(0, count, 0, .1, &flat));
    for (const uint32_t seed : {uint32_t{1} << 31, UINT32_MAX}) CHECK(!create(seed, 1, 0, .1, &flat));
    for (const uint64_t origin : {uint64_t{1} << 52, UINT64_MAX}) CHECK(!create(0, 1, origin, .1, &flat));
    for (const double texture : {-1., -std::numeric_limits<double>::denorm_min(), 1.01,
                                  std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()})
        CHECK(!create(0, 1, 0, texture, &flat));
    auto badFade = flat; badFade.tonal_out_end_frame = badFade.tonal_out_start_frame;
    CHECK(!create(0, 1, 0, .1, &badFade) && !create(0, 1, 0, .1, nullptr));
    ll_song_mix_reset(nullptr); ll_song_mix_destroy(nullptr);
    constexpr uint32_t count = 4097, prefix = 513, batch = 1025;
    const auto input = inputs(count); Mix baseline(count); const auto expected = render(baseline, input);
    std::vector<LLGlueFrame> invalid;
    for (uint32_t index = 0; index < 7; ++index) {
        for (const float value : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                                  -std::numeric_limits<float>::infinity()}) {
            auto last = input[prefix + batch - 1]; field(last, index) = value; invalid.push_back(last);
        }
        const float bound = index == 6 ? 1.f : LL_SONG_MIX_BUS_LIMIT;
        auto last = input[prefix + batch - 1]; field(last, index) = std::nextafter(bound, INFINITY); invalid.push_back(last);
        field(last, index) = -field(last, index); invalid.push_back(last);
    }
    auto last = input[prefix + batch - 1]; last.duck = -std::numeric_limits<float>::denorm_min(); invalid.push_back(last);
    for (const auto &bad : invalid) {
        Mix mix(count); std::vector<float> output(2 * count, 7);
        CHECK(process(mix.value, input.data(), output.data(), prefix));
        std::vector<LLGlueFrame> attempt(input.begin() + prefix, input.begin() + prefix + batch); attempt.back() = bad;
        CHECK(!process(mix.value, attempt.data(), output.data() + 2 * prefix, batch));
        CHECK(std::all_of(output.begin() + 2 * prefix, output.begin() + 2 * (prefix + batch), zero));
        CHECK(process(mix.value, input.data() + prefix, output.data() + 2 * prefix, count - prefix));
        CHECK(same(output, expected)); // Neither the full-call air cursor nor HP history advanced.
    }
    Mix mix(count); std::vector<float> rejected(2 * (count + 1), 7);
    std::vector<LLGlueFrame> oversized(count + 1, input[0]);
    CHECK(!process(mix.value, oversized.data(), rejected.data(), count + 1));
    CHECK(std::all_of(rejected.begin(), rejected.end(), zero));
    CHECK(!process(mix.value, nullptr, rejected.data(), 1) && rejected[0] == 0 && rejected[1] == 0);
    CHECK(!process(mix.value, input.data(), nullptr, 1));
    CHECK(same(render(mix, input), expected));
}
static void pointersAndOverlap() {
    const auto input = inputs(1025); Mix reference(1025); const auto expected = render(reference, input);
    Mix mix(1025); float output[3]{7, 7, 7};
    CHECK(process(mix.value, nullptr, nullptr, 0));
    CHECK(process(mix.value, input.data(), output, 0) && output[0] == 7);
    CHECK(!process(nullptr, input.data(), output, 1) && output[0] == 0 && output[1] == 0 && output[2] == 7);
    std::vector<float> actual(expected.size());
    CHECK(process(mix.value, input.data(), actual.data(), 37));
    // Live Float storage backs every cleared element; rejected input aliases are never dereferenced.
    alignas(LLGlueFrame) std::array<float, 32> shared{};
    for (const auto offsets : {std::array<uint32_t, 2>{0, 0}, {0, 1}, {1, 0}, {0, 12}}) {
        std::fill(shared.begin(), shared.end(), 7);
        const auto *alias = reinterpret_cast<const LLGlueFrame *>(shared.data() + offsets[0]);
        CHECK(!process(mix.value, alias, shared.data() + offsets[1], 2));
        CHECK(std::all_of(shared.begin() + offsets[1], shared.begin() + offsets[1] + 4, zero));
    }
    CHECK(process(mix.value, input.data() + 37, actual.data() + 74, 1025 - 37));
    CHECK(same(actual, expected));
    struct Adjacent { LLGlueFrame input[2]; float output[4]; } adjacent{{input[0], input[1]}, {7, 7, 7, 7}};
    mix.reset(); CHECK(process(mix.value, adjacent.input, adjacent.output, 2));
    CHECK(std::memcmp(adjacent.output, expected.data(), sizeof(adjacent.output)) == 0);
    struct ReverseAdjacent { float output[4]; LLGlueFrame input[2]; } reverse{{7, 7, 7, 7}, {input[0], input[1]}};
    mix.reset(); CHECK(process(mix.value, reverse.input, reverse.output, 2));
    CHECK(std::memcmp(reverse.output, expected.data(), sizeof(reverse.output)) == 0);
}
static void upstreamAlignment() {
    for (const uint32_t count : {1u, 398u, 399u, 400u, 401u, 8193u}) {
        std::vector<LLBusFrame> input(count);
        for (uint32_t i = 0; i < count; ++i) {
            const float marker = float(int(i % 23) - 11) / 64;
            input[i] = {{marker / 4, -marker / 8}, {marker / 8, marker / 16},
                        {marker, -marker}, {-marker / 2, marker / 4}, float(i % 5) / 4};
        }
        auto *glue = ll_glue_create(count, 0); auto *room = ll_room_create(.8, .4);
        CHECK(glue && room);
        std::vector<LLGlueFrame> physical(count + LL_GLUE_LATENCY), wet(physical.size());
        for (uint32_t offset = 0; offset < count;) {
            const uint32_t frames = std::min(257u, count - offset);
            CHECK(ll_glue_process(glue, input.data() + offset, physical.data() + offset, frames)); offset += frames;
        }
        for (uint32_t offset = 0; offset < LL_GLUE_LATENCY;) {
            uint32_t written = 0; const uint32_t capacity = std::min(97u, uint32_t(LL_GLUE_LATENCY) - offset);
            CHECK(ll_glue_drain(glue, physical.data() + count + offset, capacity, &written));
            CHECK(written == capacity); offset += written;
        }
        for (uint32_t i = 0; i < LL_GLUE_LATENCY; ++i) {
            const LLGlueFrame neutral{{}, {}, {}, 1}; CHECK(std::memcmp(&physical[i], &neutral, sizeof(neutral)) == 0);
        }
        CHECK(ll_room_process(room, physical.data(), wet.data(), uint32_t(physical.size())));
        std::vector<LLGlueFrame> aligned(wet.begin() + LL_GLUE_LATENCY, wet.end()), logical(count);
        ll_room_reset(room);
        for (uint32_t offset = 0; offset < count;) {
            const uint32_t frames = std::min(113u, count - offset);
            CHECK(ll_room_process(room, physical.data() + LL_GLUE_LATENCY + offset, logical.data() + offset, frames));
            offset += frames;
        }
        CHECK(std::memcmp(aligned.data(), logical.data(), count * sizeof(LLGlueFrame)) == 0);
        for (uint32_t i = 0; i < count; ++i) {
            CHECK(aligned[i].bass[0] == input[i].bass[0] && aligned[i].drums[1] == input[i].drums[1]);
            CHECK(aligned[i].duck == input[i].duck);
        }
        Mix one(count, .6), two(count, .6);
        CHECK(same(render(one, aligned, {count}), render(two, logical, {1, 17, 257})));
        CHECK(process(one.value, nullptr, nullptr, 0)); // Exactly N logical frames, not N+399 air samples.
        ll_room_destroy(room); ll_glue_destroy(glue);
    }
}
static void magnitudeAndOrigins() {
    constexpr uint32_t count = 32769;
    std::vector<LLGlueFrame> source(count, LLGlueFrame{{}, {}, {}, 1});
    for (uint32_t i = 0; i < count; ++i) {
        const float value = i < 8192 || i % 2 ? LL_SONG_MIX_BUS_LIMIT : -LL_SONG_MIX_BUS_LIMIT;
        source[i] = LLGlueFrame{{value, -value}, {value, -value}, {value, -value}, 1};
    }
    Mix stress(count, 1); const auto output = render(stress, source, {257, 1023});
    CHECK(output[0] > LL_SONG_MIX_BUS_LIMIT); // No undocumented clipping/peak ceiling.
    constexpr uint32_t shortCount = 4097;
    const uint64_t origin = (uint64_t{1} << 52) - shortCount;
    const LLRackFades local{0, 1024, 2048, 4096, 0, 0};
    const LLRackFades shifted{double(origin), double(origin + 1024), double(origin + 2048), double(origin + 4096), 0, 0};
    Mix a(shortCount, 1, 1, 0, local), b(shortCount, 1, 1, origin, shifted);
    const auto small = inputs(shortCount); CHECK(same(render(a, small), render(b, small, {1, 257})));
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
    auto source = inputs(1025); source[0].drums[0] = std::numeric_limits<float>::denorm_min();
    Mix reference(1025, 1); const auto expected = render(reference, source);
    for (const int rounding : {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO}) {
        CHECK(std::fesetround(rounding) == 0); const auto roundedControl = floatingControl();
        for (const uint64_t flush : {uint64_t{0}, flushMask}) {
            setFloatingControl((roundedControl & ~flushMask) | flush); setFloatingStatus(1);
            Mix mix(1025, 1); CHECK(same(expected, render(mix, source, {1, 255, 256, 513}))); mix.reset();
            auto invalid = source; invalid.back().duck = -std::numeric_limits<float>::denorm_min();
            std::vector<float> rejected(2050, 7); CHECK(!process(mix.value, invalid.data(), rejected.data(), 1025));
            CHECK(std::all_of(rejected.begin(), rejected.end(), zero)); CHECK(same(expected, render(mix, source)));
            CHECK(!create(0, 1, 0, -std::numeric_limits<double>::denorm_min(), &flat));
            CHECK(std::fegetround() == rounding);
        }
    }
    CHECK(std::fesetround(originalRounding) == 0); setFloatingControl(original); setFloatingStatus(originalStatus);
    std::vector<LLGlueFrame> subnormal(17, LLGlueFrame{{}, {}, {}, 1});
    for (auto &frame : subnormal) frame.drums[0] = std::numeric_limits<float>::denorm_min();
    Mix flush(17, 0); const auto silence = render(flush, subnormal); CHECK(std::all_of(silence.begin(), silence.end(), zero));
}
int main() {
    originalProbes(); stagingAndDuckRouting(); lifecycleAndPartitioning(); invalidSetupAndRollback(); pointersAndOverlap();
    upstreamAlignment(); magnitudeAndOrigins(); floatingModes();
    std::puts("Song mix Float staging, duck/air routing, HP tails, alignment, rollback/bounds, FP and allocation audits passed");
}
