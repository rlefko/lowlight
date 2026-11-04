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
    if (!good) { std::fprintf(stderr, "Song pair assertion failed at line %d\n", line); std::abort(); }
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
static uint32_t fault = 0, songCalls = 0, peakCalls = 0;
static bool synthetic = false;
static float control(uint32_t frame, uint32_t channel, bool second) {
    if (!second) {
        if (frame == 12799) return channel ? 1.f : -3.f;
        if (frame == 79999) return channel ? -2.f : 4.f;
        if (frame == 80000) return channel ? -.0625f : .125f;
        return channel ? -.5f : 1.25f;
    }
    if (frame == 31822) return channel ? 2.f : -.5f;
    if (frame == 31983) return channel ? -2.f : 4.f;
    if (frame == 67982) return channel ? -.25f : .5f;
    return channel ? .25f : .75f;
}
// Only the pair test object redirects calls; real child state still advances.
extern "C" bool ll_test_replay_render(LLSongReplay *song, float *output, uint32_t capacity, uint32_t *written) {
    ++songCalls; const auto start = ll_song_replay_position(song);
    if (!ll_song_replay_render(song, output, capacity, written)) return false;
    if (synthetic) for (uint32_t i = 0; i < *written; ++i) for (uint32_t ch = 0; ch < 2; ++ch)
        output[2 * i + ch] = control(start + i, ch, ll_song_replay_origin(song) != 0);
    if (fault == 1 && songCalls == 2) return false;
    if (fault == 2 && songCalls == 2) ++*written;
    if (fault == 6 && songCalls == 2 && *written) output[2 * *written - 1] = std::numeric_limits<float>::quiet_NaN();
    return true;
}
extern "C" bool ll_test_pair_peak_process(LLPeakProtector *peak, const float *input, float *output, uint32_t count) {
    if (++peakCalls == 2 && fault == 3) return false;
    return ll_peak_process(peak, input, output, count);
}
extern "C" bool ll_test_pair_peak_drain(LLPeakProtector *peak, float *output, uint32_t capacity, uint32_t *written) {
    if (fault == 4) return false;
    if (fault == 5) { *written = capacity + 1; return true; }
    if (fault == 7) { *written = 0; return true; }
    return ll_peak_drain(peak, output, capacity, written);
}
struct Song {
    LLMixer *mixer = ll_mixer_create(); LLSongSource *source = nullptr; LLSongReplay *value = nullptr;
    Song(uint32_t frames, uint64_t origin, uint32_t voices = 1) {
        const LLSongSourceConfig c{origin, frames, 1278560406, 0, .5, .75, 0,
            {0, 0, double(origin), double(origin + frames), double(origin), double(origin + frames)}};
        CHECK(mixer && ll_mixer_configure_origin(mixer, origin) && ll_mixer_configure_buses(mixer, .5));
        CHECK(ll_mixer_configure_fades(mixer, &c.rack_fades));
        std::array<float, 257> pcm{};
        for (uint32_t i = 0; i < pcm.size(); ++i) pcm[i] = float(int(i % 19) - 9) / 32;
        CHECK(ll_mixer_add_sample(mixer, pcm.data(), uint32_t(pcm.size()), 1) == 0);
        std::vector<LLEvent> events(voices, {origin, 0, 257, 0, .75f, -.25f, 0, 0, 0, 0});
        CHECK(ll_mixer_load_events(mixer, events.data(), voices));
        source = ll_song_source_create(mixer, &c); CHECK(source);
        value = checked([&] { return ll_song_replay_create(source, -30); }, false); CHECK(value);
        CHECK(ll_song_source_origin(source) == origin && ll_song_replay_origin(value) == origin);
        CHECK(ll_song_replay_frames(value) == frames && ll_song_source_required_voice_slots(source) == voices);
        CHECK(ll_song_replay_required_voice_slots(value) == voices);
    }
    ~Song() { ll_song_replay_destroy(value); ll_song_source_destroy(source); ll_mixer_destroy(mixer); }
};
struct Pair {
    LLSongPair *value;
    Pair(Song &first, Song &second, uint32_t frames) : value(checked([&] {
        return ll_song_pair_create(first.value, second.value, frames);
    }, false)) { CHECK(value && ll_song_pair_frames(value) == frames); }
    ~Pair() { ll_song_pair_destroy(value); }
    void reset() { checked([&] { ll_song_pair_reset(value); return true; }); }
};
static bool pull(LLSongPair *pair, float *output, uint32_t count, uint32_t *written) {
    return checked([&] { return ll_song_pair_render(pair, output, count, written); });
}
static bool zero(float value) { return value == 0; }
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
// Whole-song arrays exist only in this independent old-primitive test assembly.
static std::vector<float> reference(Song &first, Song &second, uint32_t frames) {
    std::vector<float> sum(2 * frames, 0), physical(2 * (frames + LL_PEAK_LATENCY)); uint32_t written = 0;
    for (auto *song : {first.value, second.value}) {
        const uint32_t n = ll_song_replay_frames(song); const uint64_t origin = ll_song_replay_origin(song);
        std::vector<float> pcm(2 * n);
        CHECK(ll_test_replay_render(song, pcm.data(), n, &written) && written == n);
        for (uint32_t i = 0; i < n && origin + i < frames; ++i)
            for (uint32_t ch = 0; ch < 2; ++ch) sum[2 * (origin + i) + ch] += pcm[2 * i + ch];
        ll_song_replay_reset(song);
    }
    for (uint32_t i = 0; i < frames; ++i) for (uint32_t ch = 0; ch < 2; ++ch) {
        sum[2 * i + ch] = float(double(sum[2 * i + ch]) * std::min(1.0, double(i) / (.4 * 32000)));
        sum[2 * i + ch] = float(double(sum[2 * i + ch]) * std::clamp(double(frames - i) / (2.8 * 32000), 0.0, 1.0));
    }
    auto *peak = ll_peak_create(LL_PEAK_SESSION); CHECK(peak);
    CHECK(ll_peak_process(peak, sum.data(), physical.data(), frames));
    CHECK(ll_peak_drain(peak, physical.data() + 2 * frames, LL_PEAK_LATENCY, &written) && written == LL_PEAK_LATENCY);
    ll_peak_destroy(peak);
    return {physical.begin() + 2 * LL_PEAK_LATENCY, physical.end()};
}
static std::vector<float> render(Pair &pair, const std::vector<uint32_t> &blocks) {
    const auto n = ll_song_pair_frames(pair.value); std::vector<float> result; result.reserve(2 * n);
    std::vector<float> output(2 * *std::max_element(blocks.begin(), blocks.end()) + 1, 7);
    uint32_t index = 0, offset = 0;
    while (offset < n) {
        const auto capacity = blocks[index++ % blocks.size()]; uint32_t written = 99;
        std::fill(output.begin(), output.end(), 7);
        CHECK(pull(pair.value, output.data(), capacity, &written) && written == std::min(capacity, n - offset));
        CHECK(std::all_of(output.begin() + 2 * written, output.begin() + 2 * capacity, zero) && output[2 * capacity] == 7);
        result.insert(result.end(), output.begin(), output.begin() + 2 * written); offset += written;
        CHECK(ll_song_pair_position(pair.value) == offset && !ll_song_pair_faulted(pair.value));
    }
    uint32_t written = 99; CHECK(pull(pair.value, output.data(), 1, &written) && !written && output[0] == 0);
    return result;
}
static void lifecycle() {
    for (uint32_t origin : {1u, 159u, 160u, 161u, 255u, 256u, 257u}) {
        Song first(origin + 171, 0), second(513, origin);
        for (uint32_t frames : {origin + 1, origin + 513}) {
            const auto expected = reference(first, second, frames); Pair pair(first, second, frames);
            CHECK(same(expected, render(pair, {frames + 3})));
            CHECK(ll_song_replay_position(first.value) == std::min(frames, origin + 171));
            CHECK(ll_song_replay_position(second.value) == frames - origin);
            pair.reset(); CHECK(same(expected, render(pair, {1, 17, 159, 160, 161, 257})));
            pair.reset(); float out[2]; uint32_t written = 0; CHECK(pull(pair.value, out, 1, &written));
            pair.reset(); CHECK(same(expected, render(pair, {113}))); pair.reset();
        }
    }
}
static void failures() {
    Song first(513, 0), second(1025, 17); const auto expected = reference(first, second, 1042);
    Pair pair(first, second, 1042); std::vector<float> out(2 * 1100 + 1, 7); uint32_t written = 99;
    for (uint32_t fail = 1; fail <= 7; ++fail) {
        CHECK(pull(pair.value, out.data(), 17, &written)); const auto before = ll_song_replay_position(first.value);
        CHECK(!pull(pair.value, nullptr, 1, &written) && !written);
        CHECK(!pull(pair.value, out.data(), 3, nullptr));
        CHECK(!pull(pair.value, out.data(), 3, reinterpret_cast<uint32_t *>(out.data() + 1)));
        CHECK(ll_song_pair_position(pair.value) == 17 && ll_song_replay_position(first.value) == before);
        CHECK(!ll_song_pair_faulted(pair.value));
        fault = fail; songCalls = peakCalls = 0; std::fill(out.begin(), out.end(), 7);
        CHECK(!pull(pair.value, out.data(), 1100, &written) && !written);
        CHECK(std::all_of(out.begin(), out.end() - 1, zero) && out.back() == 7);
        CHECK(ll_song_pair_faulted(pair.value) && ll_song_pair_position(pair.value) == 17);
        CHECK(ll_song_replay_position(first.value) > before); // Later failure cannot roll back an advanced child.
        CHECK(!pull(pair.value, nullptr, 0, &written)); fault = 0;
        pair.reset(); CHECK(same(expected, render(pair, {257}))); pair.reset();
    }
}
static void activeControl() {
    // Frozen from original session AST sum/fades + unchanged master protector,
    // before native comparison; inputs/outputs are FLOAT, before PCM24 storage.
    synthetic = true; Song first(80001, 0), second(70000, 32017);
    const auto expected = reference(first, second, 100000); Pair pair(first, second, 100000);
    const auto actual = render(pair, {1, 159, 160, 161, 257}); CHECK(same(actual, expected));
    struct Probe { uint32_t frame; float left, right; };
    const Probe probes[] = {{0, 0, 0}, {1, .00009765625145519152f, -.000039062499126885086f},
        {12798, .32363903522491455f, -.12945561110973358f}, {12799, -.7767620086669922f, .25892066955566406f},
        {12800, .32376089692115784f, -.12950436770915985f}, {31856, .7405298352241516f, -.29621192812919617f},
        {32016, .4853229224681854f, -.19412916898727417f}, {32017, .7764939665794373f, -.09706174582242966f},
        {63839, .26824066042900085f, .5364813208580017f}, {63999, .29592692852020264f, -.03699086606502533f},
        {64000, .7767630815505981f, -.36988717317581177f}, {79999, .7764258980751038f, -.2860516607761383f},
        {80000, .14303261041641235f, .03064984641969204f}, {80001, .12260518223047256f, .04086839407682419f},
        {99839, .0013468042016029358f, .0004489347629714757f},
        {99998, .00001673099905019626f, .000005577000138146104f},
        {99999, .000005577001047640806f, -.000002788500523820403f}};
    for (const auto &probe : probes) {
        CHECK(std::abs(actual[2 * probe.frame] - probe.left) <= 2e-6f);
        CHECK(std::abs(actual[2 * probe.frame + 1] - probe.right) <= 2e-6f);
    }
    CHECK(actual[2 * 12799] > -1 && actual[2 * 64000] < 1); // Hot inputs -2.9194/2.1094 are actively reduced.
    pair.reset(); CHECK(same(actual, render(pair, {100003}))); synthetic = false;
}
static void setup() {
    Song first(513, 0, 32), second(513, 17, 32), excess(513, 17, 33);
    CHECK(!ll_song_pair_create(first.value, excess.value, 530));
    CHECK(!ll_song_pair_create(first.value, first.value, 513));
    CHECK(!ll_song_pair_create(nullptr, second.value, 530));
    for (uint32_t frames : {0u, 17u, 531u, UINT32_MAX}) CHECK(!ll_song_pair_create(first.value, second.value, frames));
    for (uint64_t origin : {uint64_t{0}, uint64_t{513}, uint64_t{1} << 40}) {
        Song invalid(513, origin); CHECK(!ll_song_pair_create(first.value, invalid.value, 530));
    }
    CHECK(!ll_song_pair_create(second.value, first.value, 530));
    for (int fail = 0; fail < 2; ++fail) {
        const auto live = allocations - frees; allocationAttempt = 0; allocationFailure = fail;
        CHECK(!ll_song_pair_create(first.value, second.value, 530)); allocationFailure = -1;
        CHECK(allocations - frees == live && !ll_song_replay_position(first.value) && !ll_song_replay_position(second.value));
    }
    { Pair pair(first, second, 530); float out[3]{7,7,7}; uint32_t written = 99;
      CHECK(pull(pair.value, nullptr, 0, &written) && !written);
      CHECK(pull(pair.value, out, 1, &written) && written == 1 && out[2] == 7);
      CHECK(!ll_song_pair_create(first.value, second.value, 530)); pair.reset(); }
    CHECK(!ll_song_replay_position(first.value) && !ll_song_replay_position(second.value)); // Destroy borrows only.
    float out[3]{7,7,7}; uint32_t written = 99;
    CHECK(!pull(nullptr, out, 1, &written) && !written && out[0] == 0 && out[2] == 7);
    CHECK(ll_song_pair_faulted(nullptr) && !ll_song_pair_position(nullptr) && !ll_song_pair_frames(nullptr));
    CHECK(!ll_song_source_origin(nullptr) && !ll_song_source_required_voice_slots(nullptr));
    CHECK(!ll_song_replay_origin(nullptr) && !ll_song_replay_frames(nullptr) && !ll_song_replay_required_voice_slots(nullptr));
    ll_song_pair_destroy(nullptr); ll_song_pair_reset(nullptr);
}
static void floatingModes() {
    const auto original = state(); Song first(513, 0), second(513, 17); const auto expected = reference(first, second, 530);
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
        Pair pair(first, second, 530); CHECK(same(expected, render(pair, {1, 257})));
        pair.reset(); uint32_t written = 99; CHECK(!pull(pair.value, nullptr, 1, &written) && !written);
        CHECK(!checked([&] { return ll_song_pair_create(first.value, second.value, 17); }, false));
    }
    install(original);
}
int main() {
    lifecycle(); activeControl(); failures(); setup(); floatingModes();
    std::puts("Song pair placement/fades/session-peak alignment, reset/faults, FP and allocation audits passed");
}
