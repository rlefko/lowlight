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

static uint64_t allocations = 0, deallocations = 0;
static std::size_t lastAllocation = 0;
static bool failAllocation = false;
void *operator new(std::size_t bytes) {
    if (failAllocation) { failAllocation = false; throw std::bad_alloc(); }
    void *pointer = std::malloc(bytes ? bytes : 1);
    if (!pointer) throw std::bad_alloc();
    ++allocations; lastAllocation = bytes; return pointer;
}
void *operator new[](std::size_t bytes) { return ::operator new(bytes); }
void *operator new(std::size_t bytes, const std::nothrow_t &) noexcept {
    try { return ::operator new(bytes); } catch (...) { return nullptr; }
}
void *operator new[](std::size_t bytes, const std::nothrow_t &tag) noexcept { return ::operator new(bytes, tag); }
void operator delete(void *pointer) noexcept { if (pointer) ++deallocations; std::free(pointer); }
void operator delete[](void *pointer) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
static void require(bool condition, int line) {
    if (!condition) { std::fprintf(stderr, "Loudness assertion failed at line %d\n", line); std::abort(); }
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
    return 0;
#endif
}
static void setFloatingStatus(uint64_t value) {
#if defined(__aarch64__) || defined(__arm64__)
    __asm__ volatile("msr fpsr, %0" : : "r"(value) : "memory");
#else
    (void)value;
#endif
}
struct Audit {
    uint64_t control = floatingControl(), status = floatingStatus(), news = allocations, frees = deallocations;
    void check(bool memory = true) const {
        CHECK(floatingControl() == control && floatingStatus() == status);
        CHECK(!memory || (allocations == news && deallocations == frees));
    }
};
static LLLoudness *create(uint32_t frames) {
    const Audit audit; auto *result = ll_loudness_create(frames); audit.check(false); return result;
}
static bool process(LLLoudness *meter, const float *input, uint32_t frames) {
    const Audit audit; const bool result = ll_loudness_process(meter, input, frames); audit.check(); return result;
}
static bool finish(LLLoudness *meter, LLLoudnessResult *output) {
    const Audit audit; const bool result = ll_loudness_finish(meter, output); audit.check(); return result;
}
struct Meter {
    LLLoudness *value;
    explicit Meter(uint32_t frames) : value(create(frames)) { CHECK(value); }
    ~Meter() { ll_loudness_destroy(value); }
    Meter(const Meter &) = delete; Meter &operator=(const Meter &) = delete;
    void reset() { const Audit audit; ll_loudness_reset(value); audit.check(); }
};
static bool same(const LLLoudnessResult &a, const LLLoudnessResult &b) {
    return a.measurable == b.measurable && a.total_blocks == b.total_blocks &&
        a.absolute_blocks == b.absolute_blocks && a.gated_blocks == b.gated_blocks &&
        std::memcmp(&a.integrated_lufs, &b.integrated_lufs, sizeof(double)) == 0;
}
enum class Signal { pattern, gates, silent, quiet, extreme };
static void fill(float *output, uint32_t offset, uint32_t count, Signal signal = Signal::pattern) {
    for (uint32_t i = 0; i < count; ++i) {
        const uint32_t frame = offset + i;
        float scale = signal == Signal::silent ? 0.f : (signal == Signal::quiet ? 1.f / 65536 : 1.f);
        if (signal == Signal::gates)
            scale = frame < 32000 ? 1.f : (frame < 64000 ? 1.f / 32 : (frame < 96000 ? .25f : 0.f));
        output[2 * i] = float(int(frame % 31) - 15) / 64 * scale;
        output[2 * i + 1] = float(int(frame % 17) - 8) / 32 * scale;
        if (signal == Signal::extreme) {
            output[2 * i] = (frame % 2 ? 1.f : -1.f) * LL_LOUDNESS_INPUT_LIMIT;
            output[2 * i + 1] = (frame % 53 ? -1.f : 1.f) * LL_LOUDNESS_INPUT_LIMIT;
        }
    }
}
static LLLoudnessResult render(Meter &meter, uint32_t frames, Signal signal = Signal::pattern,
                               const std::vector<uint32_t> &partitions = {256}) {
    std::vector<float> buffer(2 * *std::max_element(partitions.begin(), partitions.end()));
    uint32_t offset = 0; std::size_t block = 0;
    while (offset < frames) {
        const uint32_t count = std::min(frames - offset, partitions[block++ % partitions.size()]);
        fill(buffer.data(), offset, count, signal); CHECK(process(meter.value, buffer.data(), count)); offset += count;
    }
    CHECK(process(meter.value, nullptr, 0));
    LLLoudnessResult result{}; CHECK(finish(meter.value, &result)); return result;
}
static void originalProbes() {
    // Frozen before native comparison from unchanged pyloudnorm 0.1.1 / NumPy 2.3.5.
    // The recipes are dyadic Float32 inputs. Counts/status are exact; LUFS budget is 1e-5.
    struct Probe { uint32_t frames, blocks; double lufs; };
    const Probe probes[] = {
        {12800, 1, -11.563574816392745}, {14399, 1, -11.563574816392745},
        {14400, 1, -11.563574816392745}, {14401, 2, -11.843300961533807},
        {17599, 2, -11.562341184462602}, {17600, 3, -11.746957835414957},
        {17601, 3, -11.746922933177974}, {20799, 3, -11.56177478305314},
        {20800, 3, -11.56177478305314}, {20801, 4, -11.699385921173251},
        {23999, 4, -11.561536981067976}, {24000, 4, -11.561536981067976},
        {24001, 5, -11.670995798417772}, {65537, 17, -11.561321026692033},
    };
    for (const auto &probe : probes) {
        Meter meter(probe.frames); const auto expected = render(meter, probe.frames, Signal::pattern, {probe.frames});
        CHECK(expected.measurable && expected.total_blocks == probe.blocks);
        CHECK(expected.absolute_blocks == probe.blocks && expected.gated_blocks == probe.blocks);
        CHECK(std::abs(expected.integrated_lufs - probe.lufs) <= 1e-5);
        meter.reset(); CHECK(same(expected, render(meter, probe.frames, Signal::pattern, {1, 17, 255, 256, 3201})));
        meter.reset(); std::array<float, 514> prefix{}; fill(prefix.data(), 0, 257);
        CHECK(process(meter.value, prefix.data(), 257)); meter.reset(); CHECK(same(expected, render(meter, probe.frames)));
    }
    Meter gates(128000); const auto mixed = render(gates, 128000, Signal::gates, {257, 1023});
    CHECK(mixed.measurable && mixed.total_blocks == 37 && mixed.absolute_blocks == 30 && mixed.gated_blocks == 21);
    CHECK(std::abs(mixed.integrated_lufs - -15.194474251921896) <= 1e-5);
    for (const auto signal : {Signal::silent, Signal::quiet}) {
        Meter meter(12800); const auto result = render(meter, 12800, signal);
        CHECK(!result.measurable && result.integrated_lufs == 0 && result.total_blocks == 1);
        CHECK(result.absolute_blocks == 0 && result.gated_blocks == 0);
    }
    // Frozen original impulse: this tighter scalar gate rejects Double power
    // reduction (5.2e-10 LU difference) and unrounded reciprocal (1.4e-7 LU).
    Meter impulse(12800); std::vector<float> input(25600);
    input[0] = 1; input[1] = -.5f; input[25598] = -.25f; input[25599] = .125f;
    CHECK(process(impulse.value, input.data(), 12800)); LLLoudnessResult result{};
    CHECK(finish(impulse.value, &result) && result.measurable);
    CHECK(result.total_blocks == 1 && result.absolute_blocks == 1 && result.gated_blocks == 1);
    CHECK(std::abs(result.integrated_lufs - -36.86212106673564) <= 1e-12);
}
static void boundsAndLifecycle() {
    CHECK(LL_LOUDNESS_MIN_FRAMES == 12800 && LL_LOUDNESS_MAX_FRAMES == 5792000 && LL_LOUDNESS_INPUT_LIMIT == 1e6f);
    for (const uint32_t frames : {0u, 12799u, 5792001u, UINT32_MAX}) CHECK(!create(frames));
    failAllocation = true; CHECK(!create(12800) && !failAllocation);
    ll_loudness_destroy(nullptr); ll_loudness_reset(nullptr);
    CHECK(!process(nullptr, nullptr, 0));
    LLLoudnessResult cleared{};
    CHECK(!finish(nullptr, &cleared) && same(cleared, LLLoudnessResult{}));
    Meter meter(12800); std::vector<float> input(25602); fill(input.data(), 0, 12801);
    CHECK(process(meter.value, nullptr, 0)); CHECK(!process(meter.value, nullptr, 1));
    CHECK(!process(meter.value, input.data(), 12801));
    CHECK(!finish(meter.value, nullptr)); cleared = {7, 7, 7, 7, true};
    CHECK(!finish(meter.value, &cleared) && same(cleared, LLLoudnessResult{}));
    CHECK(process(meter.value, input.data(), 12799));
    cleared = {7, 7, 7, 7, true}; CHECK(!finish(meter.value, &cleared) && same(cleared, LLLoudnessResult{}));
    CHECK(process(meter.value, input.data() + 25598, 1));
    CHECK(!process(meter.value, input.data(), 1));
    CHECK(!finish(meter.value, nullptr) && process(meter.value, nullptr, 0));
    LLLoudnessResult result{}, repeated{}; CHECK(finish(meter.value, &result));
    CHECK(finish(meter.value, &repeated) && same(result, repeated));
    CHECK(!process(meter.value, nullptr, 0) && !process(meter.value, input.data(), 1));
    meter.reset(); CHECK(same(result, render(meter, 12800)));
}
static void invalidCallRollback() {
    constexpr uint32_t frames = 32769, prefix = 12345, batch = 1025;
    Meter original(frames); const auto expected = render(original, frames);
    std::vector<float> input(2 * frames); fill(input.data(), 0, frames); const auto pristine = input;
    for (uint32_t channel = 0; channel < 2; ++channel) {
        for (const float invalid : {std::numeric_limits<float>::quiet_NaN(), INFINITY, -INFINITY,
                 std::nextafter(LL_LOUDNESS_INPUT_LIMIT, INFINITY), -std::nextafter(LL_LOUDNESS_INPUT_LIMIT, INFINITY)}) {
            Meter meter(frames); CHECK(process(meter.value, input.data(), prefix));
            const auto index = 2 * (prefix + batch - 1) + channel; const float old = input[index]; input[index] = invalid;
            CHECK(!process(meter.value, input.data() + 2 * prefix, batch)); input[index] = old;
            CHECK(process(meter.value, input.data() + 2 * prefix, frames - prefix));
            LLLoudnessResult result{}; CHECK(finish(meter.value, &result) && same(result, expected));
        }
    }
    CHECK(std::memcmp(input.data(), pristine.data(), input.size() * sizeof(float)) == 0);
    Meter maximum(LL_LOUDNESS_MAX_FRAMES); const auto result = render(maximum, LL_LOUDNESS_MAX_FRAMES);
    CHECK(result.measurable && result.total_blocks == 1807 && result.absolute_blocks == 1807 && result.gated_blocks == 1807);
    CHECK(std::abs(result.integrated_lufs - -11.561240112537002) <= 1e-5);
    maximum.reset(); CHECK(same(result, render(maximum, LL_LOUDNESS_MAX_FRAMES, Signal::pattern, {1, 32769})));
    Meter extreme(65537); const auto bounded = render(extreme, 65537, Signal::extreme);
    CHECK(bounded.measurable && std::isfinite(bounded.integrated_lufs));
    extreme.reset(); CHECK(same(bounded, render(extreme, 65537, Signal::extreme, {1, 257, 12801})));
}
static void floatingModes() {
    const auto original = floatingControl(), originalStatus = floatingStatus(); const int rounding = std::fegetround();
#if defined(__aarch64__) || defined(__arm64__)
    const uint64_t flushMask = uint64_t{1} << 24, statusMask = 0;
#elif defined(__x86_64__)
    const uint64_t flushMask = 0x8040, statusMask = 0x3f;
#else
    const uint64_t flushMask = 0, statusMask = 0;
#endif
    Meter reference(24000); const auto expected = render(reference, 24000);
    for (const int mode : {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO}) {
        CHECK(std::fesetround(mode) == 0); const auto rounded = floatingControl();
        for (const uint64_t flush : {uint64_t{0}, flushMask}) for (const uint64_t flags : {uint64_t{0}, uint64_t{1}}) {
            setFloatingControl((rounded & ~(flushMask | statusMask)) | flush | (flags & statusMask)); setFloatingStatus(flags);
            Meter meter(24000); CHECK(same(expected, render(meter, 24000, Signal::pattern, {1, 255, 256, 1023})));
            meter.reset(); std::array<float, 4> bad{0, 0, 0, INFINITY}; CHECK(!process(meter.value, bad.data(), 2));
            CHECK(same(expected, render(meter, 24000))); CHECK(!create(12799)); CHECK(std::fegetround() == mode);
        }
    }
    CHECK(std::fesetround(rounding) == 0); setFloatingControl(original); setFloatingStatus(originalStatus);
    Meter subnormal(12800); std::vector<float> tiny(25600, std::numeric_limits<float>::denorm_min());
    CHECK(process(subnormal.value, tiny.data(), 12800)); LLLoudnessResult result{}; CHECK(finish(subnormal.value, &result));
    CHECK(!result.measurable && result.integrated_lufs == 0 && result.gated_blocks == 0);
}
int main() {
    const auto before = allocations; Meter memory(12800);
    CHECK(allocations == before + 1 && lastAllocation < 256 * 1024);
    const auto bytes = lastAllocation;
    originalProbes(); boundsAndLifecycle(); invalidCallRollback(); floatingModes();
    std::printf("Loudness reference gates/endpoints, partitions/reset, bounds/rollback, FP and allocation audits passed; state %zu bytes\n", bytes);
}
