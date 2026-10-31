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
    if (!condition) { std::fprintf(stderr, "Harmonic glue assertion failed at line %d\n", line); std::abort(); }
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
static bool process(LLGlue *glue, const LLBusFrame *input, LLGlueFrame *output, uint32_t frames) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_glue_process(glue, input, output, frames);
    auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
static bool drain(LLGlue *glue, LLGlueFrame *output, uint32_t capacity, uint32_t *written) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_glue_drain(glue, output, capacity, written);
    auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
struct Glue {
    LLGlue *value;
    explicit Glue(uint64_t frames, uint8_t focus = 0) : value(ll_glue_create(frames, focus)) { CHECK(value); }
    ~Glue() { ll_glue_destroy(value); }
    Glue(const Glue &) = delete;
    Glue &operator=(const Glue &) = delete;
    void reset() {
        const auto control = floatingControl(); auditing = true;
        ll_glue_reset(value); auditing = false;
        CHECK(floatingControl() == control && allocations == 0 && deallocations == 0);
    }
};
static LLGlueFrame marked(float value = 7) { return {{value, value}, {value, value}, {value, value}, value}; }
static bool equal(const LLGlueFrame &a, const LLGlueFrame &b) {
    static_assert(sizeof(LLGlueFrame) == 7 * sizeof(float));
    return std::memcmp(&a, &b, sizeof(a)) == 0;
}
static bool cleared(const LLGlueFrame &value) { return equal(value, LLGlueFrame{}); }
static bool same(const std::vector<LLGlueFrame> &a, const std::vector<LLGlueFrame> &b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), equal);
}
static std::vector<LLBusFrame> inputs(uint32_t count) {
    std::vector<LLBusFrame> result(count);
    for (uint32_t i = 0; i < count; ++i) {
        const float marker = static_cast<float>(i + 1) / 1024;
        result[i] = {{.002f, -.001f}, {.001f, .003f}, {marker, -marker},
                     {-marker * 2, marker * 3}, static_cast<float>(i % 5) / 4};
    }
    return result;
}
static void finish(LLGlue *glue, std::vector<LLGlueFrame> &output, uint32_t inputCount,
                   const std::vector<uint32_t> &blocks) {
    const uint32_t remaining = inputCount ? LL_GLUE_LATENCY : 0;
    const uint32_t maximum = *std::max_element(blocks.begin(), blocks.end());
    std::vector<LLGlueFrame> scratch(maximum + 1, marked());
    uint32_t offset = 0, written = 999; std::size_t block = 0;
    CHECK(drain(glue, nullptr, 0, &written) && written == 0);
    while (offset < remaining) {
        const uint32_t capacity = blocks[block++ % blocks.size()];
        std::fill(scratch.begin(), scratch.end(), marked()); written = 999;
        CHECK(drain(glue, scratch.data(), capacity, &written));
        CHECK(written == std::min(capacity, remaining - offset));
        CHECK(equal(scratch[capacity], marked()));
        for (uint32_t i = written; i < capacity; ++i) CHECK(cleared(scratch[i]));
        std::copy_n(scratch.begin(), written, output.begin() + inputCount + offset); offset += written;
    }
    std::fill(scratch.begin(), scratch.end(), marked()); written = 999;
    CHECK(drain(glue, scratch.data(), maximum, &written) && written == 0);
    CHECK(std::all_of(scratch.begin(), scratch.begin() + maximum, cleared));
    CHECK(equal(scratch[maximum], marked()));
}
static std::vector<LLGlueFrame> render(Glue &glue, const std::vector<LLBusFrame> &input,
                                      const std::vector<uint32_t> &blocks = {4096},
                                      const std::vector<uint32_t> &drainBlocks = {512}) {
    const uint32_t count = static_cast<uint32_t>(input.size());
    std::vector<LLGlueFrame> output(count ? count + LL_GLUE_LATENCY : 0, marked());
    uint32_t offset = 0; std::size_t block = 0;
    CHECK(process(glue.value, nullptr, nullptr, 0));
    while (offset < count) {
        const uint32_t frames = std::min(count - offset, blocks[block++ % blocks.size()]);
        CHECK(process(glue.value, input.data() + offset, output.data() + offset, frames)); offset += frames;
    }
    finish(glue.value, output, count, drainBlocks);
    return output;
}

static void lifecycleAndDelay() {
    CHECK(LL_GLUE_LATENCY == 399);
    for (const uint32_t count : {0u, 1u, 2u, 399u, 400u, 401u, 799u, 800u, 801u, 4097u, 65537u}) {
        const auto input = inputs(count);
        for (const uint8_t focus : {0, 1}) {
            Glue glue(count, focus);
            const auto whole = render(glue, input, {std::max(1u, count)});
            CHECK(whole.size() == (count ? count + LL_GLUE_LATENCY : 0));
            for (uint32_t i = 0; i < (count ? LL_GLUE_LATENCY : 0); ++i) {
                LLGlueFrame neutral{}; neutral.duck = 1; CHECK(equal(whole[i], neutral));
            }
            for (uint32_t i = 0; i < count; ++i) {
                const auto &actual = whole[i + LL_GLUE_LATENCY];
                for (uint32_t ch = 0; ch < 2; ++ch) {
                    // This quiet constant is below the knee; no compression should occur.
                    const float expected = input[i].guitar[ch] * (focus ? .85f : 1.f) +
                                           input[i].piano[ch] * (focus ? 1.08f : .94f);
                    CHECK(actual.tonal[ch] == expected);
                    CHECK(actual.bass[ch] == input[i].bass[ch] && actual.drums[ch] == input[i].drums[ch]);
                }
                CHECK(actual.duck == input[i].duck);
            }
            glue.reset();
            CHECK(same(whole, render(glue, input, {1, 17, 255, 256, 257, 503}, {1, 17, 257})));
        }
    }
}

static void cappedLinkedGain() {
    const uint32_t count = 32000;
    std::vector<LLBusFrame> input(count, LLBusFrame{{.5f, -.5f}, {}, {}, {}, 1});
    Glue glue(count); const auto whole = render(glue, input, {count});
    const double attack = std::exp(-1.0 / (.012 * 32000));
    float previous = 1;
    for (uint32_t i = 0; i < count; ++i) {
        const auto &actual = whole[i + LL_GLUE_LATENCY];
        // A constant loud signal always requests the 5 dB cap. Solve the smoother
        // analytically, independent of the processor's detector/window/state code.
        const double gain = std::pow(10.0, -5 * (1 - std::pow(attack, i + 1)) / 20);
        CHECK(std::abs(actual.tonal[0] - .5 * gain) < 2e-7);
        CHECK(actual.tonal[0] == -actual.tonal[1]); // Opposite polarity must not cancel linked power.
        CHECK(actual.tonal[0] <= previous && actual.tonal[0] >= .5f * .5623412f);
        previous = actual.tonal[0];
    }
    glue.reset(); CHECK(same(whole, render(glue, input, {1, 257, 1023}, {19, 400})));
}

static void reflectedBoundaryOracle() {
    // Captured from unchanged v9 render_room.glue by verify-glue.py. The complete
    // independent inputs/outputs and hashes are in tests/fixtures/glue-v9.
    struct Probe { uint32_t frames; uint8_t focus; float first[2], last[2]; };
    const Probe probes[] = {
        {1, 0, {-.440589874983f, .278957039118f}, {-.440589874983f, .278957039118f}},
        {2, 1, {.865578174591f, -.458063721657f}, {-.356432557106f, .245514720678f}},
        {399, 0, {.154214605689f, -.047762822360f}, {-.350483417511f, .221906632185f}},
        {400, 1, {.139902800322f, -.036224834621f}, {-.300757169724f, .207164898515f}},
        {401, 0, {.154253065586f, -.047774732113f}, {-.350567162037f, .221959650517f}},
        {799, 1, {.139920577407f, -.036229439080f}, {-.325718998909f, .224358886480f}},
        {800, 0, {.154253065586f, -.047774732113f}, {-.376322388649f, .238266423345f}},
        {801, 1, {.140000000596f, -.036250002682f}, {-.325732171535f, .224367961287f}},
    };
    for (const auto &probe : probes) {
        std::vector<LLBusFrame> input(probe.frames,
            LLBusFrame{{.00390625f, -.001953125f}, {.001953125f, .00390625f}, {}, {}, 1});
        input[0] = {{.125f, -.0625f}, {.03125f, .015625f}, {}, {}, 1};
        input[(probe.frames - 1) / 2] = {{1, -.5f}, {.015625f, -.03125f}, {}, {}, 1};
        input.back() = {{-.5f, .25f}, {.0625f, .03125f}, {}, {}, 1};
        Glue glue(probe.frames, probe.focus);
        const auto output = render(glue, input, {1, 17, 256}, {257});
        for (uint32_t channel = 0; channel < 2; ++channel) {
            CHECK(std::abs(output[LL_GLUE_LATENCY].tonal[channel] - probe.first[channel]) <= 2e-6f);
            CHECK(std::abs(output.back().tonal[channel] - probe.last[channel]) <= 2e-6f);
        }
    }
}

static float &field(LLBusFrame &frame, uint32_t index) {
    if (index < 2) return frame.guitar[index];
    if (index < 4) return frame.piano[index - 2];
    if (index < 6) return frame.bass[index - 4];
    if (index < 8) return frame.drums[index - 6];
    return frame.duck;
}
static void transactionalFailures() {
    const uint32_t count = 1400, prefix = 417, batch = 257;
    auto input = inputs(count);
    for (uint32_t i = 0; i < count; ++i) input[i].guitar[0] = i % 101 < 70 ? .3f : .001f;
    Glue baseline(count, 1); const auto expected = render(baseline, input);
    std::vector<LLBusFrame> invalid;
    for (uint32_t index = 0; index < 9; ++index) {
        auto bad = input[prefix + batch - 1]; field(bad, index) = std::numeric_limits<float>::quiet_NaN();
        invalid.push_back(bad); field(bad, index) = std::numeric_limits<float>::infinity(); invalid.push_back(bad);
    }
    auto bad = input[prefix + batch - 1]; bad.duck = -.1f; invalid.push_back(bad);
    bad.duck = 1.1f; invalid.push_back(bad);
    bad = input[prefix + batch - 1]; bad.piano[0] = std::numeric_limits<float>::max(); invalid.push_back(bad);
    bad.guitar[0] = std::numeric_limits<float>::max(); bad.piano[0] /= 2; invalid.push_back(bad);
    bad = input[prefix + batch - 1]; bad.guitar[0] = 1e20f; invalid.push_back(bad);
    bad.guitar[0] = bad.guitar[1] = 1.7e19f; invalid.push_back(bad);
    for (const auto &last : invalid) {
        Glue glue(count, 1);
        std::vector<LLGlueFrame> actual(count + LL_GLUE_LATENCY, marked());
        CHECK(process(glue.value, input.data(), actual.data(), prefix));
        std::vector<LLBusFrame> attempt(input.begin() + prefix, input.begin() + prefix + batch);
        attempt.back() = last;
        CHECK(!process(glue.value, attempt.data(), actual.data() + prefix, batch));
        CHECK(std::all_of(actual.begin() + prefix, actual.begin() + prefix + batch, cleared));
        uint32_t written = 99;
        CHECK(!drain(glue.value, actual.data() + prefix, batch, &written) && written == 0);
        CHECK(std::all_of(actual.begin() + prefix, actual.begin() + prefix + batch, cleared));
        CHECK(process(glue.value, input.data() + prefix, actual.data() + prefix, count - prefix));
        std::array<LLGlueFrame, 3> rejected{marked(), marked(), marked()};
        CHECK(!drain(glue.value, rejected.data(), 3, nullptr));
        CHECK(std::all_of(rejected.begin(), rejected.end(), cleared));
        CHECK(!process(glue.value, input.data(), rejected.data(), 1) && cleared(rejected[0]));
        finish(glue.value, actual, count, {7, 256});
        CHECK(same(actual, expected));
    }
    // Reset during both input and reflected drain discards all partial history.
    Glue reset(count, 1); std::vector<LLGlueFrame> partial(count);
    CHECK(process(reset.value, input.data(), partial.data(), prefix));
    reset.reset(); CHECK(same(render(reset, input), expected));
    reset.reset(); CHECK(process(reset.value, input.data(), partial.data(), count));
    uint32_t written = 99;
    CHECK(drain(reset.value, partial.data(), 17, &written) && written == 17);
    reset.reset(); CHECK(same(render(reset, input), expected));
}

static void boundsAndPointers() {
    CHECK(!ll_glue_create(1, 2) && !ll_glue_create(1, 255));
    constexpr uint64_t maximum = (uint64_t{1} << 52) - LL_GLUE_LATENCY;
    CHECK(!ll_glue_create(maximum + 1, 0) && !ll_glue_create(UINT64_MAX, 0));
    { Glue large(maximum); }
    ll_glue_reset(nullptr); ll_glue_destroy(nullptr);
    Glue glue(1); const auto input = inputs(2);
    std::array<LLGlueFrame, 2> output{marked(), marked()}; uint32_t written = 99;
    CHECK(process(glue.value, input.data(), output.data(), 0));
    CHECK(equal(output[0], marked()) && equal(output[1], marked()));
    CHECK(!process(nullptr, input.data(), output.data(), 2));
    CHECK(cleared(output[0]) && cleared(output[1]));
    CHECK(!process(glue.value, nullptr, output.data(), 1) && cleared(output[0]));
    CHECK(!process(glue.value, input.data(), nullptr, 1));
    CHECK(!process(glue.value, input.data(), output.data(), 2));
    CHECK(!drain(glue.value, nullptr, 0, &written) && written == 0);
    CHECK(!drain(nullptr, output.data(), 2, &written) && written == 0);
    CHECK(cleared(output[0]) && cleared(output[1]));
    output[1] = marked();
    CHECK(process(glue.value, input.data(), output.data(), 1));
    CHECK(equal(output[1], marked()));
    CHECK(!drain(glue.value, nullptr, 1, &written) && written == 0);
    CHECK(drain(glue.value, output.data(), 1, &written) && written == 1);
    CHECK(!process(glue.value, input.data(), output.data(), 1) && cleared(output[0]));
    std::vector<LLGlueFrame> tail(399, marked());
    CHECK(drain(glue.value, tail.data(), 399, &written) && written == 398);
    CHECK(tail[397].bass[0] == input[0].bass[0] && cleared(tail[398]));
    CHECK(drain(glue.value, output.data(), 2, &written) && written == 0);
    CHECK(cleared(output[0]) && cleared(output[1]));
    CHECK(process(glue.value, nullptr, nullptr, 0));
}

static void overlappingBuffers() {
    const uint32_t count = 801, prefix = 417;
    const auto input = inputs(count);
    Glue reference(count); const auto expected = render(reference, input);
    for (const auto offsets : {std::array<uint32_t, 2>{0, 0}, {0, 1}, {1, 0}}) {
        Glue glue(count); std::vector<LLGlueFrame> actual(count + LL_GLUE_LATENCY);
        CHECK(process(glue.value, input.data(), actual.data(), prefix));
        // Output objects are live and aligned. The aliased input pointer must be
        // rejected by address, without reading it as a different object type.
        alignas(LLBusFrame) std::array<LLGlueFrame, 4> shared{};
        auto *bytes = reinterpret_cast<unsigned char *>(shared.data()) + offsets[0] * sizeof(LLGlueFrame);
        std::memcpy(bytes, input.data(), 2 * sizeof(LLBusFrame));
        auto *output = shared.data() + offsets[1];
        CHECK(!process(glue.value, reinterpret_cast<const LLBusFrame *>(bytes), output, 2));
        CHECK(cleared(output[0]) && cleared(output[1]));
        CHECK(process(glue.value, input.data() + prefix, actual.data() + prefix, count - prefix));
        finish(glue.value, actual, count, {256}); CHECK(same(actual, expected));
    }
    Glue glue(count); std::vector<LLGlueFrame> actual(count + LL_GLUE_LATENCY);
    CHECK(process(glue.value, input.data(), actual.data(), count));
    uint32_t written = 0;
    CHECK(drain(glue.value, actual.data() + count, 17, &written) && written == 17);
    std::array<LLGlueFrame, 2> rejected{marked(), marked()};
    auto *alias = reinterpret_cast<uint32_t *>(&rejected[1].duck);
    CHECK(!drain(glue.value, rejected.data(), 2, alias));
    CHECK(cleared(rejected[0]) && cleared(rejected[1])); // Do not dereference the aliased integer pointer.
    std::array<LLGlueFrame, 400> tail{};
    CHECK(drain(glue.value, tail.data(), 400, &written) && written == LL_GLUE_LATENCY - 17);
    std::copy_n(tail.begin(), written, actual.begin() + count + 17);
    CHECK(std::all_of(tail.begin() + written, tail.end(), cleared) && same(actual, expected));
    // Exactly adjacent, properly typed buffers do not overlap.
    struct Adjacent { LLBusFrame input[2]; LLGlueFrame output[2]; uint32_t written; } adjacent{};
    adjacent.input[0] = input[0]; adjacent.input[1] = input[1];
    Glue small(2);
    CHECK(process(small.value, adjacent.input, adjacent.output, 2));
    CHECK(drain(small.value, adjacent.output, 2, &adjacent.written) && adjacent.written == 2);
}

static void floatingState() {
    const auto original = floatingControl(), originalStatus = floatingStatus();
#if defined(__aarch64__) || defined(__arm64__)
    const uint64_t flushMask = uint64_t{1} << 24;
#elif defined(__x86_64__)
    const uint64_t flushMask = 0x8040;
#else
    const uint64_t flushMask = 0;
#endif
    for (const uint64_t mode : {original & ~flushMask, original | flushMask}) {
        setFloatingControl(mode);
        Glue glue(401); auto input = inputs(401);
        input[0].guitar[0] = std::numeric_limits<float>::denorm_min();
        const auto output = render(glue, input, {1, 400}, {1, 398});
        CHECK(output.size() == 800);
        glue.reset();
        input.back().guitar[0] = std::numeric_limits<float>::max();
        std::vector<LLGlueFrame> rejected(401);
        setFloatingStatus(0);
        CHECK(!process(glue.value, input.data(), rejected.data(), 401));
    }
    setFloatingControl(original);
    setFloatingStatus(originalStatus);
}

int main() {
    lifecycleAndDelay(); cappedLinkedGain(); reflectedBoundaryOracle();
    transactionalFailures(); boundsAndPointers(); overlappingBuffers(); floatingState();
    std::puts("Harmonic glue lifecycle, delay, linked gain, transactionality, FP and allocation audits passed");
}
