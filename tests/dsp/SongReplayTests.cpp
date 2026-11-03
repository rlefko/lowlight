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
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif
#pragma STDC FENV_ACCESS ON

static uint64_t allocations = 0, frees = 0;
static int allocationFailure = -1, allocationAttempt = 0;
void *operator new(std::size_t bytes) {
    void *pointer = std::malloc(bytes ? bytes : 1); if (!pointer) std::abort();
    ++allocations; return pointer;
}
void *operator new[](std::size_t bytes) { return ::operator new(bytes); }
void *operator new(std::size_t bytes, const std::nothrow_t &) noexcept {
    if (allocationFailure >= 0 && allocationAttempt++ == allocationFailure) return nullptr;
    return ::operator new(bytes);
}
void *operator new[](std::size_t bytes, const std::nothrow_t &tag) noexcept { return ::operator new(bytes, tag); }
void operator delete(void *pointer) noexcept { if (pointer) ++frees; std::free(pointer); }
void operator delete[](void *pointer) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
static void require(bool good, int line) {
    if (!good) { std::fprintf(stderr, "Song replay assertion failed at line %d\n", line); std::abort(); }
}
#define CHECK(value) require((value), __LINE__)
struct FP { uint64_t control, status; };
static FP state() {
#if defined(__aarch64__)
    FP value{}; asm volatile("mrs %0, fpcr" : "=r"(value.control) : : "memory");
    asm volatile("mrs %0, fpsr" : "=r"(value.status) : : "memory"); return value;
#else
    return {_mm_getcsr(), 0};
#endif
}
static void install(FP value) {
#if defined(__aarch64__)
    asm volatile("msr fpcr, %0" : : "r"(value.control) : "memory");
    asm volatile("msr fpsr, %0" : : "r"(value.status) : "memory");
#else
    _mm_setcsr(static_cast<unsigned>(value.control));
#endif
}
template<class Function> static auto checked(Function call, bool memory = true) {
    const FP before = state(); const auto news = allocations, deletes = frees;
    const auto result = call(); const FP after = state();
    CHECK(before.control == after.control && before.status == after.status);
    CHECK(!memory || (news == allocations && deletes == frees)); return result;
}
static bool synthetic = false;
static uint32_t fault = 0, sourceCalls = 0, peakCalls = 0;
static float control(uint32_t frame, uint32_t channel) {
    float left = (frame / 16) % 2 ? -1.f / 64 : 1.f / 64;
    if (frame == 0) left = 2;
    if (frame == 16016) left = 4;
    return channel ? -left / 2 : left;
}
// Only SongReplay.cpp's test object redirects these calls. The real source still
// advances/resets normally; optional PCM replacement comes from the frozen recipe.
extern "C" bool ll_test_source_render(LLSongSource *source, float *output, uint32_t capacity, uint32_t *written) {
    const uint32_t start = ll_song_source_position(source); ++sourceCalls;
    if (!ll_song_source_render(source, output, capacity, written)) return false;
    if (fault == 1 && sourceCalls == 2) return false;
    if (synthetic) for (uint32_t i = 0; i < *written; ++i)
        for (uint32_t ch = 0; ch < 2; ++ch) output[2 * i + ch] = control(start + i, ch);
    if (fault == 4 && sourceCalls == 2 && *written) output[2 * *written - 1] = std::numeric_limits<float>::quiet_NaN();
    return true;
}
extern "C" bool ll_test_peak_process(LLPeakProtector *peak, const float *input, float *output, uint32_t count) {
    if (++peakCalls == 2 && fault == 2) return false;
    return ll_peak_process(peak, input, output, count);
}
extern "C" bool ll_test_peak_drain(LLPeakProtector *peak, float *output, uint32_t capacity, uint32_t *written) {
    if (fault == 3) return false;
    if (fault == 5) { *written = capacity + 1; return true; }
    return ll_peak_drain(peak, output, capacity, written);
}
struct Source {
    LLMixer *mixer = ll_mixer_create(); LLSongSource *value = nullptr;
    explicit Source(uint32_t n, uint64_t origin = 0) {
        const LLSongSourceConfig c{origin, n, 1278560406, 0, .5, .75, .125,
            {0, 0, double(origin), double(origin + n), double(origin), double(origin + n)}};
        CHECK(mixer && ll_mixer_configure_origin(mixer, origin) && ll_mixer_configure_buses(mixer, .5));
        CHECK(ll_mixer_configure_fades(mixer, &c.rack_fades));
        std::array<float, 384> pcm{};
        for (uint32_t i = 0; i < pcm.size(); ++i) pcm[i] = float(int(i % 19) - 9) / 32;
        CHECK(ll_mixer_add_sample(mixer, pcm.data(), uint32_t(pcm.size()), 1) == 0);
        const LLEvent events[] = {{origin, 0, 257, 129, .75f, .25f, 0, 0, 0, 0},
                                  {origin + n - 1, 0, 1, 0, .5f, -.25f, 3, 0, 0, 0}};
        CHECK(ll_mixer_load_events(mixer, events, 2)); value = ll_song_source_create(mixer, &c); CHECK(value);
        CHECK(ll_song_source_frames(value) == n);
    }
    ~Source() { ll_song_source_destroy(value); ll_mixer_destroy(mixer); }
};
struct Replay {
    LLSongReplay *value;
    explicit Replay(Source &source, double loudness = -30) :
        value(checked([&] { return ll_song_replay_create(source.value, loudness); }, false)) { CHECK(value); }
    ~Replay() { ll_song_replay_destroy(value); }
    void reset() { checked([&] { ll_song_replay_reset(value); return true; }); }
    LLSongGainValues gain() {
        LLSongGainValues result{}; CHECK(checked([&] { return ll_song_replay_gain(value, &result); })); return result;
    }
};
static bool pull(LLSongReplay *replay, float *output, uint32_t capacity, uint32_t *written) {
    return checked([&] { return ll_song_replay_render(replay, output, capacity, written); });
}
static bool zero(float value) { return value == 0; }
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
static std::vector<float> reference(Source &source, double loudness = -30) {
    const uint32_t n = ll_song_source_frames(source.value); uint32_t written = 0;
    std::vector<float> dry(2 * n), gained(2 * n), physical(2 * (n + LL_PEAK_LATENCY));
    auto *gain = ll_song_gain_create(loudness); auto *peak = ll_peak_create(LL_PEAK_SONG); CHECK(gain && peak);
    CHECK(ll_test_source_render(source.value, dry.data(), n, &written) && written == n);
    CHECK(ll_song_gain_process(gain, dry.data(), gained.data(), n));
    CHECK(ll_peak_process(peak, gained.data(), physical.data(), n));
    CHECK(ll_peak_drain(peak, physical.data() + 2 * n, LL_PEAK_LATENCY, &written) && written == LL_PEAK_LATENCY);
    CHECK(std::all_of(physical.begin(), physical.begin() + 2 * LL_PEAK_LATENCY, zero));
    ll_peak_destroy(peak); ll_song_gain_destroy(gain); ll_song_source_reset(source.value);
    return {physical.begin() + 2 * LL_PEAK_LATENCY, physical.end()};
}
static std::vector<float> render(Replay &replay, uint32_t n, const std::vector<uint32_t> &blocks) {
    std::vector<float> result; result.reserve(2 * n);
    std::vector<float> output(2 * *std::max_element(blocks.begin(), blocks.end()) + 1, 7);
    uint32_t offset = 0, index = 0;
    while (offset < n) {
        const uint32_t capacity = blocks[index++ % blocks.size()]; uint32_t written = 99;
        std::fill(output.begin(), output.end(), 7);
        CHECK(pull(replay.value, output.data(), capacity, &written) && written == std::min(capacity, n - offset));
        CHECK(std::all_of(output.begin() + 2 * written, output.begin() + 2 * capacity, zero) && output[2 * capacity] == 7);
        result.insert(result.end(), output.begin(), output.begin() + 2 * written); offset += written;
        CHECK(ll_song_replay_position(replay.value) == offset && !ll_song_replay_faulted(replay.value));
    }
    return result;
}
static void lifecycle() {
    for (const uint32_t n : {1u, 2u, 159u, 160u, 161u, 257u, 399u, 400u, 1025u, 16017u}) {
        Source baseline(n); const auto expected = reference(baseline);
        for (const uint64_t origin : {uint64_t{0}, uint64_t{1} << 40}) {
            Source source(n, origin); Replay replay(source); const auto gain = replay.gain();
            CHECK(same(expected, render(replay, n, {n + 3})));
            CHECK(ll_song_source_position(source.value) == n && ll_mixer_position(source.mixer) == origin + n);
            float output[5]{7, 7, 7, 7, 7}; uint32_t written = 99;
            CHECK(pull(replay.value, output, 2, &written) && !written && output[4] == 7);
            CHECK(std::all_of(output, output + 4, zero) && pull(replay.value, nullptr, 0, &written));
            replay.reset(); CHECK(ll_song_source_position(source.value) == 0 && ll_song_replay_position(replay.value) == 0);
            CHECK(same(expected, render(replay, n, {1, 17, 159, 160, 161, 257})));
            replay.reset(); CHECK(pull(replay.value, output, 1, &written) && written == 1);
            replay.reset(); const auto again = replay.gain(); CHECK(std::memcmp(&gain, &again, sizeof(gain)) == 0);
            CHECK(same(expected, render(replay, n, {113})));
        }
    }
}
static void activeControl() {
    // Frozen from unchanged pyloudnorm + session_render gain + master_stream.protect,
    // before this native comparison; body[1024,13824) of the dyadic control recipe.
    constexpr double measured = -34.38005379367722; synthetic = true;
    Source source(16017); const auto expected = reference(source, measured); Replay replay(source, measured);
    const auto values = replay.gain();
    CHECK(values.gain_db == 13.88005379367722 && std::abs(values.linear_multiplier - 4.943137483740959) < 1e-14);
    const auto actual = render(replay, 16017, {1, 159, 160, 161, 257}); CHECK(same(actual, expected));
    struct Probe { uint32_t frame; float left; };
    const Probe probes[] = {{0, 8.723148345947266f}, {1, .06815226376056671f}, {15, .06818950176239014f},
        {16, -.06819216161966324f}, {159, -.06856434047222137f}, {160, .06856688857078552f},
        {161, .06856944411993027f}, {1023, -.07052406668663025f}, {1024, .07052607089281082f},
        {13823, -.07710801810026169f}, {13824, .07710805535316467f}, {15855, .07716839760541916f},
        {15856, -.06606227159500122f}, {15857, -.05693955719470978f}, {16015, .002202834701165557f},
        {16016, .5638565421104431f}};
    for (const auto &probe : probes) for (uint32_t ch = 0; ch < 2; ++ch)
        CHECK(std::abs(actual[2 * probe.frame + ch] - (ch ? -probe.left / 2 : probe.left)) <= 2e-6f);
    CHECK(actual[0] > 1 && actual.back() > -1); // Accepted startup overshoot; final spike is strongly reduced.
    replay.reset(); CHECK(same(actual, render(replay, 16017, {16020}))); synthetic = false;
}
static void failures() {
    constexpr uint32_t n = 1025; Source baseline(n); const auto expected = reference(baseline);
    for (uint32_t failure = 1; failure <= 5; ++failure) {
        Source source(n); Replay replay(source); uint32_t written = 99; std::vector<float> output(2 * (n + 1) + 1, 7);
        CHECK(pull(replay.value, output.data(), 17, &written)); const auto before = ll_song_source_position(source.value);
        CHECK(!pull(replay.value, nullptr, 1, &written) && !written);
        CHECK(!pull(replay.value, output.data(), 3, nullptr));
        CHECK(!pull(replay.value, output.data(), 3, reinterpret_cast<uint32_t *>(output.data() + 1)));
        CHECK(ll_song_replay_position(replay.value) == 17 && ll_song_source_position(source.value) == before);
        CHECK(!ll_song_replay_faulted(replay.value));
        fault = failure; sourceCalls = peakCalls = 0; std::fill(output.begin(), output.end(), 7);
        CHECK(!pull(replay.value, output.data(), n + 1, &written) && !written);
        CHECK(std::all_of(output.begin(), output.end() - 1, zero) && output.back() == 7);
        CHECK(ll_song_replay_faulted(replay.value) && ll_song_replay_position(replay.value) == 17);
        CHECK(ll_song_source_position(source.value) > before); // Deliberately not a whole-chain rollback.
        CHECK(!pull(replay.value, nullptr, 0, &written)); fault = 0;
        replay.reset(); CHECK(same(expected, render(replay, n, {257})));
    }
}
static void setupAndPointers() {
    Source source(1025);
    for (double level : {-70.001, std::numeric_limits<double>::signaling_NaN(),
                         std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(), 1e308})
        CHECK(!checked([&] { return ll_song_replay_create(source.value, level); }, false));
    CHECK(!ll_song_replay_create(nullptr, -30) && ll_song_source_frames(nullptr) == 0);
    for (int fail = 0; fail < 3; ++fail) {
        const auto live = allocations - frees; allocationAttempt = 0; allocationFailure = fail;
        CHECK(!ll_song_replay_create(source.value, -30)); allocationFailure = -1;
        CHECK(allocations - frees == live && ll_song_source_position(source.value) == 0);
    }
    Replay replay(source); float output[5]{7, 7, 7, 7, 7}; uint32_t written = 99;
    CHECK(pull(replay.value, nullptr, 0, &written) && !written);
    CHECK(pull(replay.value, output, 1, &written) && written == 1);
    const auto before = ll_song_source_position(source.value);
    CHECK(!ll_song_replay_create(source.value, -30) && ll_song_source_position(source.value) == before);
    CHECK(!pull(nullptr, output, 2, &written) && !written && output[4] == 7);
    CHECK(std::all_of(output, output + 4, zero));
    LLSongGainValues values{7, 7}; CHECK(!ll_song_replay_gain(nullptr, &values) && values.gain_db == 0 && values.linear_multiplier == 0);
    CHECK(!ll_song_replay_gain(replay.value, nullptr));
    CHECK(ll_song_replay_faulted(nullptr) && ll_song_replay_position(nullptr) == 0);
    ll_song_replay_reset(nullptr); ll_song_replay_destroy(nullptr);
}
static void floatingModes() {
    const auto original = state(); Source baseline(1025); const auto expected = reference(baseline);
#if defined(__aarch64__)
    constexpr uint64_t flushCount = 2;
#else
    constexpr uint64_t flushCount = 4;
#endif
    for (uint64_t rounding = 0; rounding < 4; ++rounding)
        for (uint64_t flush = 0; flush < flushCount; ++flush) for (bool flags : {false, true}) {
#if defined(__aarch64__)
        install({(original.control & ~((uint64_t{3} << 22) | (uint64_t{1} << 24))) |
                 (rounding << 22) | (flush << 24), flags ? 0x11u : 0u});
#else
        install({(original.control & ~uint64_t{0xe07f}) | (rounding << 13) |
                 ((flush & 1) ? 0x40u : 0u) | ((flush & 2) ? 0x8000u : 0u) | (flags ? 0x21u : 0u), 0});
#endif
        Source source(1025); Replay replay(source); CHECK(same(expected, render(replay, 1025, {1, 257})));
        replay.reset(); uint32_t written = 99; CHECK(!pull(replay.value, nullptr, 1, &written) && !written);
        CHECK(!checked([&] { return ll_song_replay_create(source.value, std::numeric_limits<double>::signaling_NaN()); }, false));
    }
    install(original);
}
int main() {
    lifecycle(); activeControl(); failures(); setupAndPointers(); floatingModes();
    std::puts("Song replay gain/peak alignment, active frozen probes, reset/faults, FP and allocation audits passed");
}
