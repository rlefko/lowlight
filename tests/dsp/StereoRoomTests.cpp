// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <array>
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
    if (!condition) { std::fprintf(stderr, "Stereo room assertion failed at line %d\n", line); std::abort(); }
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
static bool process(LLRoom *room, const LLGlueFrame *input, LLGlueFrame *output, uint32_t frames) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_room_process(room, input, output, frames);
    auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
struct Room {
    LLRoom *value;
    Room(double space, double warmth) : value(ll_room_create(space, warmth)) { CHECK(value); }
    ~Room() { ll_room_destroy(value); }
    Room(const Room &) = delete;
    Room &operator=(const Room &) = delete;
    void reset() {
        const auto control = floatingControl(), status = floatingStatus(); auditing = true;
        ll_room_reset(value); auditing = false;
        CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    }
};
static LLGlueFrame marked(float value = 7) { return {{value, value}, {value, value}, {value, value}, value}; }
static bool equal(const LLGlueFrame &a, const LLGlueFrame &b) {
    static_assert(sizeof(LLGlueFrame) == 7 * sizeof(float));
    return std::memcmp(&a, &b, sizeof(a)) == 0;
}
static bool cleared(const LLGlueFrame &frame) { return equal(frame, LLGlueFrame{}); }
static bool same(const std::vector<LLGlueFrame> &a, const std::vector<LLGlueFrame> &b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), equal);
}
static std::vector<LLGlueFrame> inputs(uint32_t count) {
    std::vector<LLGlueFrame> result(count);
    for (uint32_t i = 0; i < count; ++i) {
        const float left = static_cast<float>(static_cast<int>(i % 31) - 15) / 128;
        const float right = static_cast<float>(static_cast<int>(i % 23) - 11) / 256;
        result[i] = {{left, right}, {left * 2, -right}, {-left, right * 3}, static_cast<float>(i % 5) / 4};
    }
    return result;
}
static std::vector<LLGlueFrame> render(Room &room, const std::vector<LLGlueFrame> &input,
                                      const std::vector<uint32_t> &blocks = {4096}) {
    std::vector<LLGlueFrame> output(input.size() + 1, marked());
    uint32_t offset = 0; std::size_t block = 0;
    CHECK(process(room.value, nullptr, nullptr, 0));
    while (offset < input.size()) {
        const uint32_t frames = std::min(static_cast<uint32_t>(input.size()) - offset,
                                        blocks[block++ % blocks.size()]);
        CHECK(process(room.value, input.data() + offset, output.data() + offset, frames)); offset += frames;
    }
    CHECK(equal(output.back(), marked())); output.pop_back();
    for (const auto &frame : output) {
        CHECK(std::isfinite(frame.duck));
        for (uint32_t ch = 0; ch < 2; ++ch)
            CHECK(std::isfinite(frame.tonal[ch]) && std::isfinite(frame.bass[ch]) && std::isfinite(frame.drums[ch]));
    }
    return output;
}

static void parametersAndPartitioning() {
    for (const double invalid : {-1., 1.01, -std::numeric_limits<double>::denorm_min(), std::numeric_limits<double>::infinity(),
                                 -std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()}) {
        CHECK(!ll_room_create(invalid, .5) && !ll_room_create(.5, invalid));
    }
    ll_room_reset(nullptr); ll_room_destroy(nullptr);
    for (const auto controls : {std::array<double, 2>{0, 0}, {0, 1}, {1, 0}, {1, 1}, {.4, .78}}) {
        Room room(controls[0], controls[1]);
        for (const uint32_t count : {0u, 1u, 2u, 255u, 256u, 257u, 617u, 618u, 718u, 4097u, 65537u}) {
            const auto input = inputs(count); room.reset();
            const auto whole = render(room, input, {std::max(1u, count)});
            for (uint32_t i = 0; i < count; ++i) {
                for (uint32_t ch = 0; ch < 2; ++ch) {
                    CHECK(whole[i].bass[ch] == input[i].bass[ch] && whole[i].drums[ch] == input[i].drums[ch]);
                    if (i < (ch ? 718u : 618u)) CHECK(whole[i].tonal[ch] == input[i].tonal[ch] * .92f);
                }
                CHECK(whole[i].duck == input[i].duck);
            }
            room.reset(); CHECK(same(whole, render(room, input, {1, 17, 255, 256, 257, 503, 4096})));
            if (count > 4096) {
                room.reset(); std::vector<LLGlueFrame> partial(4096);
                CHECK(process(room.value, input.data(), partial.data(), 4096));
                room.reset(); CHECK(same(whole, render(room, input)));
            }
        }
    }
}

static double energy(const std::vector<LLGlueFrame> &output, uint32_t begin, uint32_t end) {
    double total = 0;
    for (uint32_t i = begin; i < end; ++i)
        for (const float value : output[i].tonal) total += static_cast<double>(value) * value;
    return total / (2 * (end - begin));
}
static void impulseDelayAndTail() {
    Room room(1, 1);
    std::vector<LLGlueFrame> input(96000, LLGlueFrame{{}, {}, {}, 1}); input[0].tonal[0] = .5f;
    const auto output = render(room, input, {static_cast<uint32_t>(input.size())});
    CHECK(output[0].tonal[0] == .5f * .92f && output[0].tonal[1] == 0);
    for (uint32_t i = 1; i < 618; ++i) CHECK(output[i].tonal[0] == 0);
    for (uint32_t i = 1; i < 718; ++i) CHECK(output[i].tonal[1] == 0);
    CHECK(output[618].tonal[0] > 0 && output[718].tonal[1] > 0);
    CHECK(energy(output, 64000, 96000) > 1e-16);
    CHECK(energy(output, 64000, 96000) < energy(output, 16000, 32000));
    room.reset();
    std::vector<LLGlueFrame> first(input.begin(), input.begin() + 1000);
    const auto prefix = render(room, first, {1, 257});
    std::vector<LLGlueFrame> zeros(input.begin() + 1000, input.end());
    const auto tail = render(room, zeros, {1, 17, 256, 1023});
    CHECK(std::equal(prefix.begin(), prefix.end(), output.begin(), equal));
    CHECK(std::equal(tail.begin(), tail.end(), output.begin() + 1000, equal));
    room.reset();
    const auto silence = render(room, zeros);
    for (const auto &frame : silence) CHECK(frame.tonal[0] == 0 && frame.tonal[1] == 0);
}

static void independentImpulseProbes() {
    // Captured from unchanged v9 render_room.room plus its original dry/wet
    // expression: 256,000 frames, tonal[0]=[.5,0], every later tonal input zero.
    struct Probe { double space, warmth; uint32_t frame; float expected[2]; };
    const Probe probes[] = {
        {0, 0, 618, {0.0005105604068376124f, 0.f}},
        {0, 0, 718, {4.770780287799425e-05f, 0.0001482272055000067f}},
        {0, 0, 1334, {-7.146503048716113e-05f, -4.863557478529401e-05f}},
        {0, 0, 1379, {-8.764439553488046e-05f, -2.445988684485201e-05f}},
        {0, 0, 2048, {0.0001179555911221541f, 2.697103082027752e-05f}},
        {0, 0, 8192, {-4.104640538571402e-05f, 8.478960808133706e-05f}},
        {0, 0, 64000, {6.250734685409043e-08f, -2.897739825868939e-09f}},
        {0, 0, 128000, {-1.05446051196223e-11f, -1.382824518954273e-12f}},
        {0, 0, 255999, {-9.116657383918968e-19f, 3.212627650605604e-20f}},
        {1, 1, 618, {0.0004488875856623054f, 0.f}},
        {1, 1, 718, {9.941652388079092e-05f, 0.0001303221943089738f}},
        {1, 1, 1334, {-1.125897142628673e-05f, -0.000126690894830972f}},
        {1, 1, 1379, {-0.0001971663587028161f, -1.641477138036862e-05f}},
        {1, 1, 2048, {-0.0003193958546034992f, -3.250664235565637e-07f}},
        {1, 1, 8192, {-8.780720236245543e-05f, 0.000271287135547027f}},
        {1, 1, 64000, {2.037747890426544e-06f, 1.496331520911554e-07f}},
        {1, 1, 128000, {-7.00792801566763e-09f, -7.556746339787423e-10f}},
        {1, 1, 255999, {-1.651615855798733e-13f, 2.752529065067652e-15f}},
    };
    std::vector<LLGlueFrame> input(256000, LLGlueFrame{{}, {}, {}, 1}); input[0].tonal[0] = .5f;
    for (const double endpoint : {0., 1.}) {
        Room room(endpoint, endpoint); const auto output = render(room, input, {257, 1023});
        for (const auto &probe : probes) {
            if (probe.space != endpoint) continue;
            for (uint32_t ch = 0; ch < 2; ++ch) {
                const double expected = probe.expected[ch];
                CHECK(std::abs(output[probe.frame].tonal[ch] - expected) <= std::max(1e-22, std::abs(expected) * 2e-4));
            }
        }
    }
}

static float &field(LLGlueFrame &frame, uint32_t index) {
    if (index < 2) return frame.tonal[index];
    if (index < 4) return frame.bass[index - 2];
    if (index < 6) return frame.drums[index - 4];
    return frame.duck;
}
static void transactionalFailures() {
    const uint32_t count = 8192, prefix = 2048, batch = 513;
    const auto input = inputs(count); Room reference(.9, .6); const auto expected = render(reference, input);
    std::vector<LLGlueFrame> invalid;
    for (uint32_t index = 0; index < 7; ++index) {
        auto bad = input[prefix + batch - 1]; field(bad, index) = std::numeric_limits<float>::quiet_NaN();
        invalid.push_back(bad); field(bad, index) = std::numeric_limits<float>::infinity(); invalid.push_back(bad);
    }
    auto bad = input[prefix + batch - 1]; bad.duck = -.01f; invalid.push_back(bad);
    bad.duck = 1.01f; invalid.push_back(bad);
    bad.duck = -std::numeric_limits<float>::denorm_min(); invalid.push_back(bad);
    bad = input[prefix + batch - 1];
    bad.tonal[0] = std::nextafter(static_cast<float>(LL_ROOM_TONAL_LIMIT), std::numeric_limits<float>::infinity());
    invalid.push_back(bad); bad.tonal[0] = -bad.tonal[0]; invalid.push_back(bad);
    bad = input[prefix + batch - 1]; bad.tonal[1] = std::numeric_limits<float>::max(); invalid.push_back(bad);
    for (const auto &last : invalid) {
        Room room(.9, .6); std::vector<LLGlueFrame> actual(count, marked());
        CHECK(process(room.value, input.data(), actual.data(), prefix));
        std::vector<LLGlueFrame> attempt(input.begin() + prefix, input.begin() + prefix + batch);
        attempt.back() = last;
        CHECK(!process(room.value, attempt.data(), actual.data() + prefix, batch));
        CHECK(std::all_of(actual.begin() + prefix, actual.begin() + prefix + batch, cleared));
        CHECK(process(room.value, input.data() + prefix, actual.data() + prefix, count - prefix));
        CHECK(same(actual, expected));
    }
}

static void pointersAndOverlap() {
    const auto input = inputs(4097); Room reference(.7, .2); const auto expected = render(reference, input);
    for (const auto offsets : {std::array<uint32_t, 2>{0, 0}, {0, 1}, {1, 0}}) {
        Room room(.7, .2); std::vector<LLGlueFrame> actual(input.size());
        CHECK(process(room.value, input.data(), actual.data(), 2048));
        std::array<LLGlueFrame, 3> shared{input[0], input[1], input[2]};
        CHECK(!process(room.value, shared.data() + offsets[0], shared.data() + offsets[1], 2));
        CHECK(cleared(shared[offsets[1]]) && cleared(shared[offsets[1] + 1]));
        CHECK(process(room.value, input.data() + 2048, actual.data() + 2048, 2049)); CHECK(same(actual, expected));
    }
    Room room(.7, .2); std::array<LLGlueFrame, 2> output{marked(), marked()};
    CHECK(process(room.value, input.data(), output.data(), 0)); CHECK(equal(output[0], marked()));
    CHECK(!process(nullptr, input.data(), output.data(), 2)); CHECK(cleared(output[0]) && cleared(output[1]));
    CHECK(!process(room.value, nullptr, output.data(), 2)); CHECK(cleared(output[0]) && cleared(output[1]));
    CHECK(!process(room.value, input.data(), nullptr, 2));
    CHECK(same(render(room, input), expected));
    struct Adjacent { LLGlueFrame input[2], output[2]; } adjacent{};
    adjacent.input[0] = input[0]; adjacent.input[1] = input[1];
    room.reset(); CHECK(process(room.value, adjacent.input, adjacent.output, 2));
    CHECK(equal(adjacent.output[0], expected[0]) && equal(adjacent.output[1], expected[1]));
}

static void magnitudeAndFloatingState() {
    CHECK(LL_ROOM_TONAL_LIMIT == 1024);
    const auto original = floatingControl(), originalStatus = floatingStatus();
#if defined(__aarch64__) || defined(__arm64__)
    const uint64_t flushMask = uint64_t{1} << 24;
#elif defined(__x86_64__)
    const uint64_t flushMask = 0x8040;
#else
    const uint64_t flushMask = 0;
#endif
    for (const auto controls : {std::array<double, 2>{0, 0}, {0, 1}, {1, 0}, {1, 1}}) {
        Room room(controls[0], controls[1]);
        auto input = inputs(131073);
        for (uint32_t i = 0; i < input.size(); ++i) {
            input[i].tonal[0] = i < 65536 ? LL_ROOM_TONAL_LIMIT : -LL_ROOM_TONAL_LIMIT;
            input[i].tonal[1] = i < 65536 ? LL_ROOM_TONAL_LIMIT : (i % 2 ? -LL_ROOM_TONAL_LIMIT : LL_ROOM_TONAL_LIMIT);
        }
        input[0].bass[0] = std::numeric_limits<float>::max();
        input[0].drums[1] = -std::numeric_limits<float>::max();
        const auto output = render(room, input, {131073});
        CHECK(output[0].bass[0] == input[0].bass[0] && output[0].drums[1] == input[0].drums[1]);
        room.reset(); CHECK(same(output, render(room, input, {1, 17, 256, 1023})));
    }
    for (const uint64_t mode : {original & ~flushMask, original | flushMask}) {
        setFloatingControl(mode);
        const double tinyControl = std::numeric_limits<double>::denorm_min();
        CHECK(!ll_room_create(-tinyControl, .5) && !ll_room_create(.5, -tinyControl));
        { Room positiveTiny(tinyControl, tinyControl), negativeZero(-0., -0.); }
        Room room(1, 0); auto input = inputs(2049);
        input[0].tonal[0] = std::numeric_limits<float>::denorm_min();
        render(room, input, {1, 256}); room.reset();
        const float tiny = std::numeric_limits<float>::denorm_min();
        const LLGlueFrame pass{{}, {tiny, -tiny}, {-0.f, std::numeric_limits<float>::max()}, tiny};
        LLGlueFrame copied{};
        CHECK(process(room.value, &pass, &copied, 1) && equal(pass, copied)); room.reset();
        input.back().tonal[0] = std::numeric_limits<float>::max();
        std::vector<LLGlueFrame> rejected(input.size()); setFloatingStatus(0);
        CHECK(!process(room.value, input.data(), rejected.data(), static_cast<uint32_t>(input.size())));
    }
    setFloatingControl(original); setFloatingStatus(originalStatus);
}

int main() {
    parametersAndPartitioning(); impulseDelayAndTail(); independentImpulseProbes();
    transactionalFailures(); pointersAndOverlap();
    magnitudeAndFloatingState();
    std::puts("Stereo room delay/tails, partition/reset, bounds/alias, FP and allocation audits passed");
}
