// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <thread>
#include <vector>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif
#pragma STDC FENV_ACCESS ON

static thread_local uint64_t allocations = 0, frees = 0;
static thread_local int allocationFailure = -1, allocationAttempt = 0;
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
template<class Condition> static void await(Condition condition) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!condition()) { CHECK(std::chrono::steady_clock::now() < deadline); std::this_thread::yield(); }
}
static thread_local uint32_t fault = 0, songCalls = 0, peakCalls = 0;
static thread_local bool synthetic = false;
static thread_local std::atomic<int> *faultGate = nullptr;
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
        output[2 * i + ch] = ll_song_replay_origin(song) == 80001
            ? (start + i == 0 ? (ch ? -2.f : 4.f) : start + i == 160 ? (ch ? 1.f : -2.f)
                : start + i == 19998 ? (ch ? -.0625f : .125f) : (ch ? .75f : -.25f))
            : control(start + i, ch, ll_song_replay_origin(song) != 0);
    if (fault == 1 && songCalls == 2) return false;
    if (fault == 2 && songCalls == 2) ++*written;
    if (fault == 6 && songCalls == 2 && *written) output[2 * *written - 1] = std::numeric_limits<float>::quiet_NaN();
    return true;
}
extern "C" bool ll_test_pair_peak_process(LLPeakProtector *peak, const float *input, float *output, uint32_t count) {
    if (faultGate) { faultGate->store(1); await([&] { return faultGate->load() == 2; }); return false; }
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
static std::vector<float> reference(std::initializer_list<Song *> songs, uint32_t frames) {
    std::vector<float> sum(2 * frames, 0), physical(2 * (frames + LL_PEAK_LATENCY)); uint32_t written = 0;
    for (auto *owner : songs) {
        auto *song = owner->value;
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
            const auto expected = reference({&first, &second}, frames); Pair pair(first, second, frames);
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
    Song first(513, 0), second(1025, 17); const auto expected = reference({&first, &second}, 1042);
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
    const auto expected = reference({&first, &second}, 100000); Pair pair(first, second, 100000);
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
    const auto original = state(); Song first(513, 0), second(513, 17); const auto expected = reference({&first, &second}, 530);
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
static std::vector<float> rollingRender(LLSongPair *pair, const std::vector<Song *> &songs,
                                        const std::vector<uint32_t> &blocks, bool streaming = false) {
    const auto n = ll_song_pair_frames(pair); std::vector<float> result; result.reserve(2 * n);
    std::vector<float> output(2 * *std::max_element(blocks.begin(), blocks.end()) + 1, 7);
    uint32_t index = 0, next = 2;
    while (ll_song_pair_position(pair) < n) {
        const auto capacity = blocks[index++ % blocks.size()]; uint32_t written = 99;
        std::fill(output.begin(), output.end(), 7);
        CHECK(pull(pair, output.data(), capacity, &written));
        CHECK(std::all_of(output.begin() + 2 * written, output.begin() + 2 * capacity, zero) && output[2 * capacity] == 7);
        result.insert(result.end(), output.begin(), output.begin() + 2 * written);
        CHECK(ll_song_pair_position(pair) == result.size() / 2);
        if (!ll_song_pair_needs_preparation(pair)) { CHECK(written); continue; }
        CHECK(next < songs.size());
        const auto position = ll_song_pair_position(pair);
        auto *old = songs[next - 2]->value;
        CHECK(ll_song_replay_position(old) == ll_song_replay_frames(old));
        CHECK(position == uint32_t(std::max<int64_t>(0, int64_t(ll_song_replay_origin(old) + ll_song_replay_frames(old)) - LL_PEAK_LATENCY)));
        CHECK(pull(pair, output.data(), capacity, &written) && !written);
        CHECK(std::all_of(output.begin(), output.begin() + 2 * capacity, zero));
        checked([&] { ll_song_pair_reset(pair); return true; }); // Single-pass: no rewind.
        CHECK(ll_song_pair_position(pair) == position && ll_song_pair_needs_preparation(pair));
        if (streaming) {
            LLSongReplay *retired = nullptr;
            CHECK(checked([&] { return ll_song_pair_claim_retired(pair, &retired); }) && retired == old);
            const auto following = next + 1 < songs.size() ? uint32_t(ll_song_replay_origin(songs[next + 1]->value)) : n;
            CHECK(checked([&] { return ll_song_pair_publish(pair, songs[next++]->value, following); }));
            continue;
        }
        CHECK(!checked([&] { return ll_song_pair_append(pair, songs[next]->value, n); }));
        CHECK(checked([&] { return ll_song_pair_retire_first(pair); }));
        CHECK(!checked([&] { return ll_song_pair_retire_first(pair); }));
        CHECK(pull(pair, output.data(), capacity, &written) && !written);
        CHECK(ll_song_pair_position(pair) == position && ll_song_pair_needs_preparation(pair));
        const auto following = next + 1 < songs.size() ? uint32_t(ll_song_replay_origin(songs[next + 1]->value)) : n;
        CHECK(checked([&] { return ll_song_pair_append(pair, songs[next++]->value, following); }));
    }
    CHECK(!ll_song_pair_needs_preparation(pair) && !ll_song_pair_faulted(pair));
    uint32_t written = 99; CHECK(pull(pair, output.data(), 1, &written) && !written && output[0] == 0);
    return result;
}
static void rollingBoundaries() {
    for (uint32_t end : {2u, 159u, 160u, 161u, 255u, 256u, 257u, 513u}) {
        Song first(end, 0), second(end + 37, 1), third(513, end), fourth(513, end + 38);
        const uint32_t n = end + 551;
        const auto expected = reference({&first, &second, &third, &fourth}, n);
        for (const auto &blocks : {std::vector<uint32_t>{n + 3}, {1, 17, 159, 160, 161, 257}}) {
            auto *pair = checked([&] { return ll_song_pair_create_rolling(first.value, second.value, n, end); }, false);
            CHECK(pair && same(expected, rollingRender(pair, {&first, &second, &third, &fourth}, blocks)));
            ll_song_pair_destroy(pair);
            for (auto *song : {&first, &second, &third, &fourth}) ll_song_replay_reset(song->value);
        }
    }
}
static void rollingFailures() {
    Song first(513, 0, 32), second(513, 17, 32), third(513, 513, 32), excess(513, 513, 33);
    for (uint32_t following : {0u, 17u, 512u, 530u, 531u, UINT32_MAX})
        CHECK(!checked([&] { return ll_song_pair_create_rolling(first.value, second.value, 1026, following); }, false));
    auto *pair = ll_song_pair_create_rolling(first.value, second.value, 1026, 513); CHECK(pair);
    CHECK(!ll_song_pair_retire_first(pair) && !ll_song_pair_append(pair, third.value, 1026));
    std::array<float, 2200> output{}; uint32_t written = 0;
    CHECK(pull(pair, output.data(), 1100, &written) && written == 353 && ll_song_pair_needs_preparation(pair));
    CHECK(ll_song_pair_retire_first(pair));
    const auto survivor = ll_song_replay_position(second.value);
    for (auto *bad : {static_cast<LLSongReplay *>(nullptr), second.value, first.value, excess.value})
        CHECK(!checked([&] { return ll_song_pair_append(pair, bad, 1026); }));
    for (uint32_t following : {513u, 529u, 1027u, UINT32_MAX})
        CHECK(!checked([&] { return ll_song_pair_append(pair, third.value, following); }));
    CHECK(ll_song_replay_render(third.value, output.data(), 1, &written) && written == 1);
    CHECK(!checked([&] { return ll_song_pair_append(pair, third.value, 1026); }));
    ll_song_replay_reset(third.value);
    CHECK(ll_song_replay_position(second.value) == survivor && !ll_song_replay_position(third.value));
    CHECK(ll_song_pair_needs_preparation(pair) && ll_song_pair_position(pair) == 353);
    CHECK(ll_song_pair_append(pair, third.value, 1026)); // Inclusive 64 slots, finite end at EOF.
    CHECK(pull(pair, output.data(), 1100, &written) && written == 673);
    ll_song_pair_destroy(pair);
    for (auto *song : {&first, &second, &third}) ll_song_replay_reset(song->value);
    // A future onset at the newest EOF would be impossible to append with overlap.
    pair = ll_song_pair_create_rolling(first.value, second.value, 1300, 513); CHECK(pair);
    CHECK(pull(pair, output.data(), 1100, &written) && ll_song_pair_retire_first(pair));
    CHECK(!ll_song_pair_append(pair, third.value, 1026));
    CHECK(ll_song_pair_append(pair, third.value, 1025)); ll_song_pair_destroy(pair);
    for (auto *song : {&first, &second, &third}) ll_song_replay_reset(song->value);
    pair = ll_song_pair_create_rolling(first.value, second.value, 1026, 513); CHECK(pair);
    fault = 1; songCalls = 0; CHECK(!pull(pair, output.data(), 1100, &written) && !written); fault = 0;
    CHECK(ll_song_pair_faulted(pair) && !ll_song_pair_needs_preparation(pair));
    ll_song_pair_reset(pair); CHECK(ll_song_pair_faulted(pair));
    CHECK(!ll_song_pair_retire_first(pair) && !ll_song_pair_append(pair, third.value, 1026)); ll_song_pair_destroy(pair);
    CHECK(!ll_song_pair_needs_preparation(nullptr) && !ll_song_pair_retire_first(nullptr));
    CHECK(!ll_song_pair_append(nullptr, third.value, 1026));
}
static void rollingActiveControl() {
    // Frozen original AST/master FLOAT probes: manifest SHA256 9cb57467...664907.
    synthetic = true; Song first(80001, 0), second(70000, 32017), third(19999, 80001);
    const auto expected = reference({&first, &second, &third}, 100000);
    auto *pair = ll_song_pair_create_rolling(first.value, second.value, 100000, 80001); CHECK(pair);
    const auto actual = rollingRender(pair, {&first, &second, &third}, {1, 159, 160, 161, 257});
    CHECK(same(actual, expected));
    const uint32_t probes[][3] = {{0, 0u, 2147483648u},
        {1, 952945869u, 3089356554u},
        {12799, 3209091552u, 1048875328u},
        {12800, 1051051005u, 3187973323u},
        {32016, 1056472127u, 3192310220u},
        {32017, 1061603407u, 3183921231u},
        {63839, 1049188055u, 1057576663u},
        {63999, 1050117052u, 3172434876u},
        {64000, 1061607922u, 3200082394u},
        {79839, 1054982133u, 3177299957u},
        {79840, 1054794359u, 3177112183u},
        {79841, 1054616982u, 3176934806u},
        {79999, 1061602265u, 3197269341u},
        {80000, 1041396551u, 1023086275u},
        {80001, 1061600819u, 3197268275u},
        {80002, 1034378964u, 1042767572u},
        {80160, 1034456860u, 1042845468u},
        {80161, 3193091370u, 1045607722u},
        {80162, 1034457794u, 1042846402u},
        {99839, 980115194u, 988503802u},
        {99998, 926622220u, 935010828u},
        {99999, 921299602u, 3060394642u}};
    for (const auto &probe : probes) for (uint32_t channel = 0; channel < 2; ++channel) {
        float wanted; std::memcpy(&wanted, &probe[channel + 1], sizeof(wanted));
        CHECK(std::abs(actual[2 * probe[0] + channel] - wanted) <= 2e-6f);
    }
    CHECK(actual[2 * 80001] < 1); // Hot third onset retains the already active global envelope.
    ll_song_pair_destroy(pair);
    for (auto *song : {&first, &second, &third}) ll_song_replay_reset(song->value);
    pair = ll_song_pair_create_streaming(first.value, second.value, 100000, 80001); CHECK(pair);
    CHECK(same(actual, rollingRender(pair, {&first, &second, &third}, {1, 159, 160, 161, 257}, true)));
    ll_song_pair_destroy(pair); synthetic = false;
}
static void rollingModes() {
    const auto original = state(); Song first(513, 0), second(513, 17), third(513, 513);
    const auto expected = reference({&first, &second, &third}, 1026);
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
        for (bool streaming : {false, true}) {
            auto *pair = checked([&] { return streaming
                ? ll_song_pair_create_streaming(first.value, second.value, 1026, 513)
                : ll_song_pair_create_rolling(first.value, second.value, 1026, 513); }, false);
            CHECK(pair && same(expected, rollingRender(pair, {&first, &second, &third}, {1, 257}, streaming)));
            ll_song_pair_destroy(pair);
            for (auto *song : {&first, &second, &third}) checked([&] { ll_song_replay_reset(song->value); return true; });
        }
    }
    install(original);
}
static void streamingThreads(bool late, bool tie, bool freeRun = false) {
    const uint32_t onset = tie ? 513 : 2048, n = 9000;
    std::array<std::unique_ptr<Song>, 2> owners{std::make_unique<Song>(513, 0), std::make_unique<Song>(5000, 17)};
    std::vector<float> expected;
    { Song third(5000, onset), fourth(5000, 5017); expected = reference({owners[0].get(), owners[1].get(), &third, &fourth}, n); }
    auto *pair = checked([&] { return ll_song_pair_create_streaming(owners[0]->value, owners[1]->value, n, onset); }, false);
    CHECK(pair); std::vector<float> actual(2 * n); std::atomic<uint32_t> stalls{0}, published{0};
    std::thread consumer([&] {
        const auto prior = state();
#if defined(__aarch64__)
        install({prior.control | (uint64_t{3} << 22) | (uint64_t{1} << 24), 0x11});
#else
        install({prior.control | 0xe061, 0});
#endif
        std::array<float, 2 * 353 + 1> out{}; uint32_t offset = 0, turn = 0;
        while (offset < n) {
            const uint32_t capacity = turn++ == 0 ? 353 : (turn % 2 ? 257 : 1);
            uint32_t written = 99; out[2 * capacity] = 7;
            CHECK(pull(pair, out.data(), capacity, &written) && written <= capacity && out[2 * capacity] == 7);
            CHECK(std::all_of(out.begin() + 2 * written, out.begin() + 2 * capacity, zero));
            std::copy_n(out.data(), 2 * written, actual.data() + 2 * offset); offset += written;
            CHECK(ll_song_pair_position(pair) == offset && !ll_song_pair_faulted(pair));
            if (turn == 1 && !late && !freeRun) await([&] { return published.load() != 0; });
            if (!written) { ++stalls; std::this_thread::yield(); }
        }
        uint32_t written = 99; CHECK(pull(pair, out.data(), 1, &written) && !written);
        install(prior);
    });
    for (uint32_t generation = 0; generation < 2; ++generation) {
        await([&] { return ll_song_pair_needs_preparation(pair); });
        LLSongReplay *retired = nullptr;
        CHECK(checked([&] { return ll_song_pair_claim_retired(pair, &retired); }) && retired == owners[0]->value);
        CHECK(ll_song_replay_position(retired) == ll_song_replay_frames(retired));
        CHECK(!checked([&] { return ll_song_pair_claim_retired(pair, &retired); }) && !retired);
        CHECK(!checked([&] { return ll_song_pair_publish(pair, owners[1]->value, n); }));
        const auto before = frees; owners[0].reset(); CHECK(frees > before); // Reclamation is worker-only.
        owners[0] = std::move(owners[1]);
        const uint32_t origin = generation ? 5017 : onset, following = generation ? n : 5017;
        if (!freeRun && (late || generation))
            await([&] { return ll_song_pair_position(pair) == origin - LL_PEAK_LATENCY && stalls.load(); });
        owners[1] = std::make_unique<Song>(5000, origin);
        CHECK(!checked([&] { return ll_song_pair_publish(pair, owners[1]->value, origin); }));
        CHECK(checked([&] { return ll_song_pair_publish(pair, owners[1]->value, following); }));
        // Free-run uses only the native protocol, including rapid mailbox reuse
        // before the worker finishes its prior generation's post-publication work.
        if (freeRun && !generation) await([&] { return ll_song_pair_needs_preparation(pair); });
        ++published;
    }
    consumer.join(); CHECK(same(actual, expected) && !ll_song_pair_needs_preparation(pair));
    ll_song_pair_destroy(pair); // Both roles quiescent before owners are released.
}
static void streamingFailures() {
    Song first(513, 0, 32), second(5000, 17, 32), third(5000, 2048, 32), excess(5000, 2048, 33);
    for (uint32_t stage = 0; stage < 4; ++stage) { // Active, requested, preparing, and ready teardown.
        auto *pair = ll_song_pair_create_streaming(first.value, second.value, 7048, 2048); CHECK(pair);
        LLSongReplay *retired = first.value; uint32_t written = 0; std::array<float, 2 * 353> out{};
        CHECK(!ll_song_pair_claim_retired(pair, &retired) && !retired && !ll_song_pair_publish(pair, third.value, 7048));
        if (stage) CHECK(pull(pair, out.data(), 353, &written) && written == 353 && ll_song_pair_needs_preparation(pair));
        if (stage >= 2) {
            CHECK(ll_song_pair_claim_retired(pair, &retired) && retired == first.value);
            CHECK(!ll_song_pair_retire_first(pair) && !ll_song_pair_append(pair, third.value, 7048));
            for (auto *bad : {static_cast<LLSongReplay *>(nullptr), second.value, first.value, excess.value})
                CHECK(!checked([&] { return ll_song_pair_publish(pair, bad, 7048); }));
            CHECK(ll_song_replay_render(third.value, out.data(), 1, &written));
            CHECK(!ll_song_pair_publish(pair, third.value, 7048)); ll_song_replay_reset(third.value);
            CHECK(ll_song_pair_needs_preparation(pair));
        }
        if (stage == 3) CHECK(ll_song_pair_publish(pair, third.value, 7048) && !ll_song_pair_needs_preparation(pair));
        ll_song_pair_destroy(pair); CHECK(!ll_song_replay_position(third.value)); // Ready candidate never consumed/deleted.
        for (auto *song : {&first, &second}) ll_song_replay_reset(song->value);
    }
    for (bool publishFirst : {false, true}) {
        auto *pair = ll_song_pair_create_streaming(first.value, second.value, 7048, 2048); CHECK(pair);
        std::array<float, 2 * 353> out{}; uint32_t written = 0; LLSongReplay *retired = nullptr;
        CHECK(pull(pair, out.data(), 353, &written) && ll_song_pair_claim_retired(pair, &retired));
        std::atomic<int> gate{0};
        std::thread consumer([&] {
            faultGate = &gate;
            CHECK(!pull(pair, out.data(), 353, &written) && !written && std::all_of(out.begin(), out.end(), zero));
            faultGate = nullptr;
        });
        await([&] { return gate.load() == 1; });
        if (publishFirst) CHECK(ll_song_pair_publish(pair, third.value, 7048));
        gate.store(2); consumer.join();
        CHECK(ll_song_pair_faulted(pair) && ll_song_pair_position(pair) == 353 && !ll_song_pair_needs_preparation(pair));
        CHECK(!ll_song_pair_publish(pair, third.value, 7048) && !ll_song_replay_position(third.value));
        ll_song_pair_destroy(pair); // Successful racing publication is retained but unconsumed.
        for (auto *song : {&first, &second}) ll_song_replay_reset(song->value);
    }
    LLSongReplay *retired = first.value;
    CHECK(!ll_song_pair_claim_retired(nullptr, &retired) && !retired);
    CHECK(!ll_song_pair_publish(nullptr, third.value, 7048));
}
int main() {
    lifecycle(); activeControl(); failures(); setup(); floatingModes();
    rollingBoundaries(); rollingFailures(); rollingActiveControl(); rollingModes();
    streamingThreads(false, false); streamingThreads(true, false); streamingThreads(true, true); streamingFailures();
    for (uint32_t trial = 0; trial < 8; ++trial) streamingThreads(false, false, true);
    std::puts("Song pair placement/fades/session-peak alignment, reset/faults, FP and allocation audits passed");
    std::puts("Rolling song pause/retire/append, global peak continuity and bounded-service audits passed");
    std::puts("Streaming song handoff, two-thread deadlines/retry, reclamation, fault and FP audits passed");
}
