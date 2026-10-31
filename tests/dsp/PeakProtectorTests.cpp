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
    if (!condition) { std::fprintf(stderr, "Peak protector assertion failed at line %d\n", line); std::abort(); }
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
static bool process(LLPeakProtector *peak, const float *input, float *output, uint32_t frames) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_peak_process(peak, input, output, frames);
    auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
static bool drain(LLPeakProtector *peak, float *output, uint32_t capacity, uint32_t *written) {
    const auto control = floatingControl(), status = floatingStatus(); auditing = true;
    const bool result = ll_peak_drain(peak, output, capacity, written);
    auditing = false;
    CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    return result;
}
struct Protector {
    LLPeakProtector *value;
    explicit Protector(uint8_t mode = LL_PEAK_SONG) : value(ll_peak_create(mode)) { CHECK(value); }
    ~Protector() { ll_peak_destroy(value); }
    Protector(const Protector &) = delete;
    Protector &operator=(const Protector &) = delete;
    void reset() {
        const auto control = floatingControl(), status = floatingStatus(); auditing = true;
        ll_peak_reset(value); auditing = false;
        CHECK(floatingControl() == control && floatingStatus() == status && allocations == 0 && deallocations == 0);
    }
};
static bool zero(float value) { return value == 0; }
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && (a.empty() || std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0);
}
static std::vector<float> inputs(uint32_t frames, bool loud = false) {
    std::vector<float> result(2 * frames);
    for (uint32_t i = 0; i < frames; ++i) {
        result[2 * i] = static_cast<float>(static_cast<int>(i % 31) - 15) / (loud ? 4 : 128);
        result[2 * i + 1] = static_cast<float>(static_cast<int>(i % 23) - 11) / (loud ? 8 : 256);
    }
    return result;
}
static void finish(LLPeakProtector *peak, std::vector<float> &output, uint32_t inputCount,
                   const std::vector<uint32_t> &blocks, bool zeroFinalizes = true) {
    const uint32_t total = inputCount ? LL_PEAK_LATENCY : 0;
    const uint32_t maximum = *std::max_element(blocks.begin(), blocks.end());
    std::vector<float> scratch(2 * (maximum + 1), 7);
    uint32_t offset = 0, written = 999; std::size_t block = 0;
    if (zeroFinalizes) CHECK(drain(peak, nullptr, 0, &written) && written == 0);
    while (offset < total) {
        const uint32_t capacity = blocks[block++ % blocks.size()];
        std::fill(scratch.begin(), scratch.end(), 7); written = 999;
        CHECK(drain(peak, scratch.data(), capacity, &written));
        CHECK(written == std::min(capacity, total - offset));
        CHECK(scratch[2 * capacity] == 7 && scratch[2 * capacity + 1] == 7);
        CHECK(std::all_of(scratch.begin() + 2 * written, scratch.begin() + 2 * capacity, zero));
        std::copy_n(scratch.begin(), 2 * written, output.begin() + 2 * (inputCount + offset)); offset += written;
    }
    std::fill(scratch.begin(), scratch.end(), 7); written = 999;
    CHECK(drain(peak, scratch.data(), maximum, &written) && written == 0);
    CHECK(std::all_of(scratch.begin(), scratch.begin() + 2 * maximum, zero));
    CHECK(scratch[2 * maximum] == 7 && scratch[2 * maximum + 1] == 7);
    CHECK(!process(peak, nullptr, nullptr, 0));
}
static std::vector<float> render(Protector &peak, const std::vector<float> &input,
                                 const std::vector<uint32_t> &blocks = {4096},
                                 const std::vector<uint32_t> &drainBlocks = {257}, bool zeroFinalizes = true) {
    const uint32_t frames = static_cast<uint32_t>(input.size() / 2);
    std::vector<float> output(frames ? 2 * (frames + LL_PEAK_LATENCY) : 0, 7);
    uint32_t offset = 0; std::size_t block = 0;
    CHECK(process(peak.value, nullptr, nullptr, 0));
    while (offset < frames) {
        const uint32_t count = std::min(frames - offset, blocks[block++ % blocks.size()]);
        CHECK(process(peak.value, input.data() + 2 * offset, output.data() + 2 * offset, count)); offset += count;
    }
    finish(peak.value, output, frames, drainBlocks, zeroFinalizes);
    CHECK(std::all_of(output.begin(), output.end(), [](float value) { return std::isfinite(value); }));
    return output;
}

static void lifecycleAndDelay() {
    CHECK(LL_PEAK_LATENCY == 160 && LL_PEAK_SONG == 0 && LL_PEAK_SESSION == 1);
    for (const uint8_t mode : {LL_PEAK_SONG, LL_PEAK_SESSION}) {
        Protector peak(mode);
        for (const uint32_t frames : {0u, 1u, 2u, 159u, 160u, 161u, 319u, 320u, 321u,
                                      4097u, 63999u, 64000u, 64001u, 64161u, 128003u}) {
            const auto input = inputs(frames); peak.reset();
            const auto whole = render(peak, input, {std::max(1u, frames)}, {257}, false);
            CHECK(whole.size() == (frames ? 2 * (frames + LL_PEAK_LATENCY) : 0));
            if (frames) {
                CHECK(std::all_of(whole.begin(), whole.begin() + 2 * LL_PEAK_LATENCY, zero));
                CHECK(std::equal(input.begin(), input.end(), whole.begin() + 2 * LL_PEAK_LATENCY));
            }
            peak.reset(); CHECK(same(whole, render(peak, input, {1, 17, 159, 160, 161, 257, 64000}, {1, 17, 159})));
        }
    }
}

static void linkedAttackAndRelease() {
    const double attack = std::exp(-1.0 / (.0007 * 32000)), release = std::exp(-1.0 / (.100 * 32000));
    for (const uint8_t mode : {LL_PEAK_SONG, LL_PEAK_SESSION}) {
        const double ceilingDB = mode == LL_PEAK_SONG ? -5 : -2.2;
        for (const uint32_t count : {1u, 2u, 159u, 160u, 161u, 2049u}) {
            std::vector<float> input(2 * count);
            for (uint32_t i = 0; i < count; ++i) { input[2 * i] = 1; input[2 * i + 1] = -.25f; }
            Protector peak(mode); const auto output = render(peak, input, {count}, {1, 161});
            for (uint32_t i = 0; i < count; ++i) {
                const double expected = std::pow(10., ceilingDB * (1 - std::pow(attack, i + 1)) / 20);
                CHECK(std::abs(output[2 * (i + LL_PEAK_LATENCY)] - expected) < 2e-6);
                CHECK(output[2 * (i + LL_PEAK_LATENCY) + 1] == -.25f * output[2 * (i + LL_PEAK_LATENCY)]);
            }
            // The accepted smoothed protector is not an instantaneous hard clipper.
            CHECK(output[2 * LL_PEAK_LATENCY] > std::pow(10., ceilingDB / 20));
        }
        constexpr uint32_t count = 16000, pulse = 777, begins = pulse - LL_PEAK_LATENCY;
        std::vector<float> input(2 * count);
        for (uint32_t i = 0; i < count; ++i) { input[2 * i] = .125f; input[2 * i + 1] = -.03125f; }
        input[2 * pulse] = 1; input[2 * pulse + 1] = -.25f;
        Protector peak(mode); const auto output = render(peak, input, {count});
        for (uint32_t i = 0; i < count; ++i) {
            // One impulse makes the forward maximum a known 161-frame rectangle.
            // Closed-form smoothing checks its entrance/expiration without copying a deque.
            double gainDB = 0;
            if (i >= begins && i <= pulse) gainDB = ceilingDB * (1 - std::pow(attack, i - begins + 1));
            else if (i > pulse) gainDB = ceilingDB * (1 - std::pow(attack, 161)) * std::pow(release, i - pulse);
            const double gain = std::pow(10., gainDB / 20);
            for (uint32_t ch = 0; ch < 2; ++ch)
                CHECK(std::abs(output[2 * (i + LL_PEAK_LATENCY) + ch] - input[2 * i + ch] * gain) < 2e-6);
        }
        peak.reset(); CHECK(same(output, render(peak, input, {1, 160, 257, 1023}, {17, 128})));
        for (uint32_t i = 0; i < count; ++i) std::swap(input[2 * i], input[2 * i + 1]);
        peak.reset(); const auto swapped = render(peak, input);
        for (uint32_t i = 0; i < count + LL_PEAK_LATENCY; ++i) {
            CHECK(swapped[2 * i] == output[2 * i + 1] && swapped[2 * i + 1] == output[2 * i]);
        }
    }
}

static void independentReferenceProbes() {
    // Captured from the unchanged v9 session_render.py/master_stream.py protectors.
    // Logical source frames here follow 160 silent physical output frames.
    const auto check = [](const std::vector<float> &output, uint32_t frame, float left, float right) {
        CHECK(std::abs(output[2 * (frame + LL_PEAK_LATENCY)] - left) < 2e-6f);
        CHECK(std::abs(output[2 * (frame + LL_PEAK_LATENCY) + 1] - right) < 2e-6f);
    };
    const uint32_t sizes[] = {1, 2, 159, 160, 161, 162};
    const float tiny[][2] = {
        {1.892219305f, 1.892219305f}, {0.9595199227f, 1.844682217f},
        {0.9461096525f, 0.562931478f}, {0.9595199227f, 0.7768280506f},
        {0.9461096525f, 0.5628809929f}, {0.9890022874f, 0.7767961621f},
    };
    for (uint32_t index = 0; index < 6; ++index) {
        const uint32_t count = sizes[index]; std::vector<float> input(2 * count);
        input[0] = 1; input[1] = -.5f;
        input[2 * (count / 2)] = -.25f; input[2 * (count / 2) + 1] = .75f;
        input[2 * (count - 1)] = 2; input[2 * (count - 1) + 1] = -1;
        Protector peak(index % 2); const auto output = render(peak, input, {1, 17, 160}, {1, 17, 160});
        check(output, 0, tiny[index][0], -.5f * tiny[index][0]);
        check(output, count - 1, tiny[index][1], -.5f * tiny[index][1]);
    }
    const uint32_t rampFrames[] = {0, 1, 159, 160, 161, 320, 321, 322, 482, 483, 484, 1023};
    const float rampValues[2][12] = {
        {
            0.007542675827f, 0.01458670851f, 0.5592042804f, 0.5626837015f,
            0.5626686811f, 0.007059582975f, 0.0035300327f, 0.4518750906f,
            0.4567207098f, 0.4567503929f, 0.f, 0.0644813329f,
        },
        {
            0.007649587002f, 0.01499393117f, 0.7717201114f, 0.776530385f,
            0.7765180469f, 0.009742776863f, 0.004871721845f, 0.6236230731f,
            0.6303172112f, 0.6303582191f, 0.f, 0.08464815468f,
        },
    };
    const uint32_t popFrames[] = {0, 1, 2, 3, 159, 160, 161, 162, 163, 1023};
    const float popValues[2][10] = {
        {
            2.370335102f, 2.212881565f, 2.029933691f, 1.868558526f,
            0.006600392051f, 0.004399956204f, 0.002199832583f, 0.5631214976f,
            0.f, 0.02794569358f,
        },
        {
            2.403932571f, 2.274659395f, 2.113637686f, 1.969707251f,
            0.009108752944f, 0.006072149612f, 0.003035906004f, 0.7771507502f,
            0.f, 0.0357449092f,
        },
    };
    const uint32_t chunkFrames[] = {0, 160, 63840, 63999, 64000, 64159, 64160, 64162};
    const float chunkValues[2][8][2] = {
        {
            {0.4730548263f, -0.2365274131f}, {0.5628809929f, -0.2814404964f},
            {0.5557342768f, -0.2778671384f}, {0.1364255697f, -0.2728511393f},
            {-0.5301296115f, 0.1325324029f}, {0.01758238301f, 0.5626362562f},
            {-0.14071998f, 0.07035999f}, {0.03522311896f, -0.01761155948f},
        },
        {
            {0.4797599614f, -0.2398799807f}, {0.776802659f, -0.3884013295f},
            {0.7669398785f, -0.3834699392f}, {0.1883196533f, -0.3766393065f},
            {-0.7317823172f, 0.1829455793f}, {0.02427044138f, 0.7766541243f},
            {-0.1942476183f, 0.09712380916f}, {0.04861165211f, -0.02430582605f},
        },
    };
    for (const uint8_t mode : {LL_PEAK_SONG, LL_PEAK_SESSION}) {
        std::vector<float> ramp(2048), pop(2048);
        for (uint32_t i = 0; i < 484; ++i) {
            ramp[2 * i] = i < 161 ? (i + 1) / 128.f : i < 322 ? (322 - i) / 128.f : 1.f;
            ramp[2 * i + 1] = -.5f * ramp[2 * i];
        }
        // Fill all 161 deque slots, expire the oldest, then replace the full tail.
        for (uint32_t i = 0; i < 162; ++i) { pop[2 * i] = (162 - i) / 64.f; pop[2 * i + 1] = -.5f * pop[2 * i]; }
        pop[324] = 4; pop[325] = -2;
        ramp[2046] = pop[2046] = .125f; ramp[2047] = pop[2047] = -.0625f;
        Protector peak(mode); const auto output = render(peak, ramp, {1024});
        for (uint32_t i = 0; i < 12; ++i) check(output, rampFrames[i], rampValues[mode][i], -.5f * rampValues[mode][i]);
        peak.reset(); CHECK(same(output, render(peak, ramp, {1, 160, 161, 17}, {1, 17})));
        peak.reset(); const auto popped = render(peak, pop, {1024});
        for (uint32_t i = 0; i < 10; ++i) check(popped, popFrames[i], popValues[mode][i], -.5f * popValues[mode][i]);
        peak.reset(); CHECK(same(popped, render(peak, pop, {161, 1, 17}, {1, 159})));
        std::vector<float> chunks(2 * 64163);
        const float events[][3] = {{0, .5f, -.25f}, {160, 2, -1}, {32768, .125f, .25f},
            {63840, 1.5f, -.75f}, {63999, .5f, -1}, {64000, -2, .5f},
            {64159, .125f, 4}, {64160, -1, .5f}, {64162, .25f, -.125f}};
        for (const auto &event : events) {
            const auto frame = static_cast<uint32_t>(event[0]);
            chunks[2 * frame] = event[1]; chunks[2 * frame + 1] = event[2];
        }
        peak.reset(); const auto chunked = render(peak, chunks, {64000});
        for (uint32_t i = 0; i < 8; ++i) check(chunked, chunkFrames[i], chunkValues[mode][i][0], chunkValues[mode][i][1]);
        peak.reset(); CHECK(same(chunked, render(peak, chunks, {1, 257, 1024, 159}, {17, 256})));
    }
}

static void transactionalFailures() {
    constexpr uint32_t frames = 4097, prefix = 513, batch = 257;
    const auto input = inputs(frames, true); Protector reference; const auto expected = render(reference, input);
    const float above = std::nextafter(LL_PEAK_INPUT_LIMIT, std::numeric_limits<float>::infinity());
    for (const float invalid : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                                -std::numeric_limits<float>::infinity(), above, -above, std::numeric_limits<float>::max()}) {
        for (uint32_t channel = 0; channel < 2; ++channel) {
            Protector peak; std::vector<float> actual(2 * (frames + LL_PEAK_LATENCY), 7);
            CHECK(process(peak.value, input.data(), actual.data(), prefix));
            std::vector<float> attempt(input.begin() + 2 * prefix, input.begin() + 2 * (prefix + batch));
            attempt[2 * (batch - 1) + channel] = invalid;
            CHECK(!process(peak.value, attempt.data(), actual.data() + 2 * prefix, batch));
            CHECK(std::all_of(actual.begin() + 2 * prefix, actual.begin() + 2 * (prefix + batch), zero));
            uint32_t written = 99;
            CHECK(!drain(peak.value, nullptr, 1, &written) && written == 0);
            CHECK(!drain(peak.value, actual.data() + 2 * prefix, batch, nullptr));
            CHECK(std::all_of(actual.begin() + 2 * prefix, actual.begin() + 2 * (prefix + batch), zero));
            CHECK(process(peak.value, input.data() + 2 * prefix, actual.data() + 2 * prefix, frames - prefix));
            finish(peak.value, actual, frames, {17, 256}); CHECK(same(actual, expected));
        }
    }
    Protector peak; std::vector<float> partial(2 * frames);
    CHECK(process(peak.value, input.data(), partial.data(), 17)); peak.reset();
    CHECK(same(render(peak, input), expected)); peak.reset();
    std::vector<float> actual(expected.size());
    CHECK(process(peak.value, input.data(), actual.data(), frames));
    uint32_t written = 99; CHECK(drain(peak.value, actual.data() + 2 * frames, 17, &written) && written == 17);
    std::array<float, 4> rejected{7, 7, 7, 7};
    CHECK(!process(peak.value, input.data(), rejected.data(), 1) && rejected[0] == 0 && rejected[1] == 0);
    CHECK(!drain(peak.value, rejected.data(), 2, reinterpret_cast<uint32_t *>(&rejected[1])));
    CHECK(std::all_of(rejected.begin(), rejected.end(), zero));
    std::array<float, 512> tail{};
    CHECK(drain(peak.value, tail.data(), 256, &written) && written == LL_PEAK_LATENCY - 17);
    std::copy_n(tail.begin(), 2 * written, actual.begin() + 2 * (frames + 17));
    CHECK(std::all_of(tail.begin() + 2 * written, tail.end(), zero) && same(actual, expected));
    peak.reset(); CHECK(same(render(peak, input), expected));
}

static void pointersAndOverlap() {
    CHECK(!ll_peak_create(2) && !ll_peak_create(255)); ll_peak_reset(nullptr); ll_peak_destroy(nullptr);
    const auto input = inputs(801, true); Protector reference; const auto expected = render(reference, input);
    for (const auto offsets : {std::array<uint32_t, 2>{0, 0}, {0, 2}, {2, 0}}) {
        Protector peak; std::vector<float> actual(expected.size());
        CHECK(process(peak.value, input.data(), actual.data(), 513));
        std::array<float, 6> shared{1, -.25f, .5f, -.125f, .25f, -.0625f};
        CHECK(!process(peak.value, shared.data() + offsets[0], shared.data() + offsets[1], 2));
        CHECK(std::all_of(shared.begin() + offsets[1], shared.begin() + offsets[1] + 4, zero));
        std::array<float, 4> rejected{7, 7, 7, 7};
        CHECK(!drain(peak.value, rejected.data(), 2, reinterpret_cast<uint32_t *>(&rejected[1])));
        CHECK(std::all_of(rejected.begin(), rejected.end(), zero)); // Do not dereference the aliased integer pointer.
        CHECK(process(peak.value, input.data() + 1026, actual.data() + 1026, 288));
        finish(peak.value, actual, 801, {160}); CHECK(same(actual, expected));
    }
    Protector peak; std::array<float, 4> output{7, 7, 7, 7}; uint32_t written = 99;
    CHECK(process(peak.value, input.data(), output.data(), 0) && output[0] == 7);
    CHECK(!process(nullptr, input.data(), output.data(), 2)); CHECK(std::all_of(output.begin(), output.end(), zero));
    CHECK(!process(peak.value, nullptr, output.data(), 2) && !process(peak.value, input.data(), nullptr, 2));
    CHECK(!drain(peak.value, nullptr, 0, nullptr));
    CHECK(!drain(nullptr, output.data(), 2, &written) && written == 0);
    CHECK(same(render(peak, input), expected));
    peak.reset(); CHECK(drain(peak.value, nullptr, 0, &written) && written == 0);
    CHECK(!process(peak.value, nullptr, nullptr, 0));
    CHECK(!process(peak.value, input.data(), output.data(), 2)); CHECK(std::all_of(output.begin(), output.end(), zero));
    peak.reset();
    struct Adjacent { float input[4], output[4]; uint32_t written; } adjacent{{1, -.25f, .5f, -.125f}, {}, 99};
    CHECK(process(peak.value, adjacent.input, adjacent.output, 2));
    CHECK(drain(peak.value, adjacent.output, 2, &adjacent.written) && adjacent.written == 2);
}

static void boundsAndFloatingState() {
    for (const uint8_t mode : {LL_PEAK_SONG, LL_PEAK_SESSION}) {
        auto input = inputs(131073);
        for (uint32_t i = 0; i < input.size() / 2; ++i) {
            input[2 * i] = i % 2 ? LL_PEAK_INPUT_LIMIT : -LL_PEAK_INPUT_LIMIT;
            input[2 * i + 1] = -.25f * input[2 * i];
        }
        Protector peak(mode); const auto whole = render(peak, input, {131073});
        peak.reset(); CHECK(same(whole, render(peak, input, {1, 17, 256, 1023}, {1, 159})));
    }
    const auto original = floatingControl(), originalStatus = floatingStatus();
#if defined(__aarch64__) || defined(__arm64__)
    const uint64_t flushMask = uint64_t{1} << 24;
#elif defined(__x86_64__)
    const uint64_t flushMask = 0x8040;
#else
    const uint64_t flushMask = 0;
#endif
    for (const uint64_t mode : {original & ~flushMask, original | flushMask}) {
        setFloatingControl(mode); Protector peak; auto input = inputs(2049, true);
        input[0] = std::numeric_limits<float>::denorm_min();
        render(peak, input, {1, 256}, {1, 17, 160}); peak.reset();
        // Exercise both callbacks with clear and preexisting sticky exception flags.
        std::array<float, 322> active{}, processed{}, tail{};
        for (uint32_t i = 0; i < 161; ++i) { active[2 * i] = 1; active[2 * i + 1] = -.25f; }
        for (const uint64_t flags : {0u, 1u}) {
#if defined(__aarch64__) || defined(__arm64__)
            setFloatingStatus(flags);
#elif defined(__x86_64__)
            setFloatingControl((floatingControl() & ~uint64_t{0x3f}) | flags);
#endif
            CHECK(process(peak.value, active.data(), processed.data(), 161));
            uint32_t written = 99;
            CHECK(drain(peak.value, tail.data(), 161, &written) && written == 160);
            peak.reset();
        }
        input.back() = std::numeric_limits<float>::max();
        std::vector<float> rejected(input.size()); setFloatingStatus(0);
        CHECK(!process(peak.value, input.data(), rejected.data(), 2049));
        uint32_t written = 99; CHECK(drain(peak.value, rejected.data(), 160, &written) && written == 0);
    }
    setFloatingControl(original); setFloatingStatus(originalStatus);
}

int main() {
    lifecycleAndDelay(); linkedAttackAndRelease(); independentReferenceProbes();
    transactionalFailures(); pointersAndOverlap(); boundsAndFloatingState();
    std::puts("Peak protector reference/deque, delay/EOF, linked gain, rollback/alias, FP and allocation audits passed");
}
