// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include "../../Packages/LowlightAudio/Sources/CLowlightDSP/SongAdvance.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <thread>
#include <vector>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif
#pragma STDC FENV_ACCESS ON

// This isolated pair test uses deterministic children and the real session protector.
// Existing SongPair/Swift suites retain complete prepared-song integration coverage.
struct LLSongReplay {
    uint64_t origin;
    uint32_t frames, position = 0, voices = 1, calls = 0;
    int identity;
    uint32_t failOnCall = 0;
    bool faulted = false;
    LLSongReplay(uint64_t canonical, uint32_t length, int id)
        : origin(canonical), frames(length), identity(id) {}
};
static std::atomic<uint32_t> *progressGate = nullptr;
static float sample(int identity, uint32_t frame, uint32_t channel) {
    const int value = int((frame + uint32_t(identity) * 7) % (channel ? 19 : 31)) - 9;
    return float(value) * (channel ? -.125f : .25f);
}
extern "C" bool ll_song_replay_render(LLSongReplay *song, float *output, uint32_t capacity,
                                      uint32_t *written) {
    if (!song || !written || (capacity && !output) || song->faulted)
        return false;
    if (progressGate && song->identity == 2 && song->position == 400) {
        progressGate->store(1, std::memory_order_release);
        const auto stop = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (progressGate->load(std::memory_order_acquire) != 2) {
            if (std::chrono::steady_clock::now() >= stop)
                std::abort();
            std::this_thread::yield();
        }
    }
    *written = std::min(capacity, song->frames - song->position);
    for (uint32_t i = 0; i < *written; ++i)
        for (uint32_t channel = 0; channel < 2; ++channel)
            output[2 * i + channel] = sample(song->identity, song->position + i, channel);
    song->position += *written;
    return ++song->calls != song->failOnCall;
}
extern "C" void ll_song_replay_reset(LLSongReplay *song) {
    if (song)
        song->position = song->calls = 0;
}
extern "C" uint32_t ll_song_replay_position(const LLSongReplay *song) {
    return song ? song->position : 0;
}
extern "C" uint32_t ll_song_replay_frames(const LLSongReplay *song) {
    return song ? song->frames : 0;
}
extern "C" uint64_t ll_song_replay_origin(const LLSongReplay *song) {
    return song ? song->origin : 0;
}
extern "C" uint32_t ll_song_replay_required_voice_slots(const LLSongReplay *song) {
    return song ? song->voices : 0;
}
extern "C" bool ll_song_replay_faulted(const LLSongReplay *song) {
    return !song || song->faulted;
}

LLMixerChangeSamples *ll_song_replay_begin_change(LLSongReplay *) {
    std::abort();
}
void ll_mixer_destroy_change_samples(LLMixerChangeSamples *) {
    std::abort();
}
int32_t ll_mixer_change_add_sample(LLMixerChangeSamples *, const LLSongChangeSample &, uint32_t) {
    std::abort();
}
LLSongAdvance *ll_song_replay_prepare_change(LLSongReplay *, const LLSongChangeScore &,
                                             const LLMixerChangeSamples *) {
    std::abort();
}

// Next is exercised with real racks in SongNextTests, never these synthetic children.
LLSongAdvance *ll_song_replay_prepare_advance(LLSongReplay *, uint32_t, uint16_t) {
    std::abort();
}
bool ll_song_replay_can_advance(const LLSongReplay *, const LLSongAdvance *) {
    std::abort();
}
void ll_song_replay_apply_advance(LLSongReplay *, const LLSongAdvance *) {
    std::abort();
}
uint32_t ll_song_replay_physical_position(const LLSongReplay *) {
    std::abort();
}
uint32_t ll_song_replay_outro_start(const LLSongReplay *) {
    std::abort();
}
bool ll_song_replay_advanced(const LLSongReplay *) {
    std::abort();
}
void ll_song_destroy_advance(LLSongAdvance *) {
    std::abort();
}

static thread_local uint64_t allocations = 0, releases = 0;
static thread_local int failAllocation = -1, allocationIndex = 0;
void *operator new(std::size_t bytes) {
    auto *value = std::malloc(bytes ? bytes : 1);
    if (!value)
        std::abort();
    ++allocations;
    return value;
}
void *operator new[](std::size_t bytes) {
    return ::operator new(bytes);
}
void *operator new(std::size_t bytes, const std::nothrow_t &) noexcept {
    if (failAllocation >= 0 && allocationIndex++ == failAllocation)
        return nullptr;
    return ::operator new(bytes);
}
void *operator new[](std::size_t bytes, const std::nothrow_t &tag) noexcept {
    return ::operator new(bytes, tag);
}
void operator delete(void *value) noexcept {
    if (value)
        ++releases;
    std::free(value);
}
void operator delete[](void *value) noexcept {
    ::operator delete(value);
}
void operator delete(void *value, std::size_t) noexcept {
    ::operator delete(value);
}
void operator delete[](void *value, std::size_t) noexcept {
    ::operator delete(value);
}
void operator delete(void *value, const std::nothrow_t &) noexcept {
    ::operator delete(value);
}
void operator delete[](void *value, const std::nothrow_t &) noexcept {
    ::operator delete(value);
}
static void require(bool value, int line) {
    if (!value) {
        std::fprintf(stderr, "Song transport assertion failed at line %d\n", line);
        std::abort();
    }
}
#define CHECK(value) require((value), __LINE__)
struct FP {
    uint64_t control, status;
};
static FP state() {
#if defined(__aarch64__)
    FP value{};
    asm volatile("mrs %0, fpcr" : "=r"(value.control) : : "memory");
    asm volatile("mrs %0, fpsr" : "=r"(value.status) : : "memory");
    return value;
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
template <class Function> static auto checked(Function function, bool memory = true) {
    const auto before = state();
    const auto news = allocations, frees = releases;
    const auto result = function();
    const auto after = state();
    CHECK(before.control == after.control && before.status == after.status);
    CHECK(!memory || (news == allocations && frees == releases));
    return result;
}
struct Placement {
    uint64_t origin;
    uint32_t frames;
    int identity;
};
static std::vector<float> reference(uint64_t start, uint64_t end, uint32_t count,
                                    const std::vector<Placement> &songs) {
    const uint32_t inputCount = count + (end ? 0 : LL_PEAK_LATENCY);
    std::vector<float> input(2 * inputCount, 0), delayed(2 * (inputCount + LL_PEAK_LATENCY), 0);
    for (uint32_t i = 0; i < inputCount; ++i) {
        const uint64_t frame = start + i;
        for (const auto &song : songs)
            if (frame >= song.origin && frame - song.origin < song.frames)
                for (uint32_t channel = 0; channel < 2; ++channel)
                    input[2 * i + channel] +=
                        sample(song.identity, uint32_t(frame - song.origin), channel);
        const double entry = std::min(1.0, double(frame - start) / 12800.0);
        const double exit = end ? std::clamp(double(end - frame) / 89600.0, 0.0, 1.0) : 1.0;
        for (uint32_t channel = 0; channel < 2; ++channel) {
            input[2 * i + channel] = float(double(input[2 * i + channel]) * entry);
            input[2 * i + channel] = float(double(input[2 * i + channel]) * exit);
        }
    }
    auto *peak = ll_peak_create(LL_PEAK_SESSION);
    CHECK(peak && ll_peak_process(peak, input.data(), delayed.data(), inputCount));
    if (end) {
        uint32_t written = 0;
        CHECK(ll_peak_drain(peak, delayed.data() + 2 * inputCount, LL_PEAK_LATENCY, &written));
        CHECK(written == LL_PEAK_LATENCY);
    }
    ll_peak_destroy(peak);
    return {delayed.begin() + 2 * LL_PEAK_LATENCY, delayed.begin() + 2 * (LL_PEAK_LATENCY + count)};
}
static bool identical(const std::vector<float> &left, const std::vector<float> &right) {
    return left.size() == right.size() &&
           std::memcmp(left.data(), right.data(), left.size() * sizeof(float)) == 0;
}
static std::vector<float> pull(LLSongPair *pair, uint32_t count,
                               const std::vector<uint32_t> &chunks) {
    std::vector<float> output(2 * count),
        scratch(2 * *std::max_element(chunks.begin(), chunks.end()));
    uint32_t position = 0, chunk = 0;
    while (position < count) {
        const auto capacity = std::min(chunks[chunk++ % chunks.size()], count - position);
        uint32_t written = 0;
        CHECK(
            checked([&] { return ll_song_pair_render(pair, scratch.data(), capacity, &written); }));
        CHECK(written > 0 && written <= capacity);
        std::copy_n(scratch.data(), 2 * written, output.data() + 2 * position);
        position += written;
    }
    return output;
}
static void finitePlacement(uint64_t start, uint32_t count) {
    const uint32_t secondOffset = std::min(80u, count - 1);
    LLSongReplay first(1234567, count, 1), second(987654321, count, 2);
    const auto expected = reference(start, start + count, count,
                                    {{start, count, 1}, {start + secondOffset, count, 2}});
    auto *pair = checked(
        [&] {
            return ll_song_pair_create_transport_at(&first, &second, start, start + secondOffset,
                                                    start + count, start + count);
        },
        false);
    CHECK(pair && ll_song_pair_position64(pair) == start);
    CHECK(ll_song_pair_frames64(pair) == start + count && !ll_song_pair_finished(pair));
    const auto output = pull(pair, count, {1, 17, 257, 400});
    CHECK(identical(output, expected));
    CHECK(ll_song_pair_position64(pair) == start + count && ll_song_pair_finished(pair));
    std::array<float, 32> tail;
    tail.fill(7);
    uint32_t written = 9;
    CHECK(checked([&] { return ll_song_pair_render(pair, tail.data(), 16, &written); }));
    CHECK(written == 0 && std::all_of(tail.begin(), tail.end(), [](float x) { return x == 0; }));
    ll_song_pair_destroy(pair);
}
static void legacyEquivalence() {
    LLSongReplay a(0, 12000, 1), b(9000, 12000, 2);
    auto *legacy = ll_song_pair_create(&a, &b, 20000);
    CHECK(legacy);
    const auto original = pull(legacy, 20000, {256});
    ll_song_pair_destroy(legacy);
    a.position = b.position = 0;
    auto *transport = ll_song_pair_create_transport(&a, &b, 9000, 20000, 20000);
    CHECK(transport);
    CHECK(identical(original, pull(transport, 20000, {1, 17, 1023})));
    CHECK(identical(original, reference(0, 20000, 20000, {{0, 12000, 1}, {9000, 12000, 2}})));
    ll_song_pair_destroy(transport);
}
static void continuousAndPublication() {
    constexpr uint64_t start = (uint64_t{1} << 32) - 200;
    LLSongReplay a(17, 1200, 1), b(700000, 1400, 2), c(9000000, 1500, 3);
    auto *pair = ll_song_pair_create_transport_at(&a, &b, start, start + 800, 0, start + 1600);
    CHECK(pair && ll_song_pair_frames64(pair) == 0);
    std::vector<float> output(2 * 2600), scratch(2 * 2048, 7);
    uint32_t written = 0;
    CHECK(checked([&] { return ll_song_pair_render(pair, scratch.data(), 2048, &written); }));
    CHECK(written == 1440 && ll_song_pair_position64(pair) == start + 1440);
    std::copy_n(scratch.data(), 2 * written, output.data());
    CHECK(
        std::all_of(scratch.begin() + 2 * written, scratch.end(), [](float x) { return x == 0; }));
    const auto firstCount = written;
    CHECK(ll_song_pair_needs_preparation(pair) && !ll_song_pair_finished(pair));
    CHECK(checked([&] { return ll_song_pair_render(pair, scratch.data(), 23, &written); }));
    CHECK(written == 0 && ll_song_pair_position64(pair) == start + 1440);
    LLSongReplay *retired = nullptr;
    CHECK(checked([&] { return ll_song_pair_claim_retired(pair, &retired); }) && retired == &a);
    CHECK(!checked([&] { return ll_song_pair_claim_retired(pair, &retired); }) &&
          retired == nullptr);
    CHECK(!checked(
        [&] { return ll_song_pair_publish_transport(pair, &c, start + 1599, start + 3000); }));
    CHECK(!checked(
        [&] { return ll_song_pair_publish_transport(pair, &c, start + 1600, start + 3100); }));
    c.voices = 64;
    CHECK(!checked(
        [&] { return ll_song_pair_publish_transport(pair, &c, start + 1600, start + 3000); }));
    c.voices = 63;
    CHECK(checked(
        [&] { return ll_song_pair_publish_transport(pair, &c, start + 1600, start + 3000); }));
    CHECK(!ll_song_pair_needs_preparation(pair));
    const auto rest = pull(pair, 2600 - firstCount, {257, 19, 1});
    std::copy(rest.begin(), rest.end(), output.begin() + 2 * firstCount);
    CHECK(identical(
        output, reference(start, 0, 2600,
                          {{start, 1200, 1}, {start + 800, 1400, 2}, {start + 1600, 1500, 3}})));
    CHECK(ll_song_pair_position64(pair) == start + 2600 && !ll_song_pair_finished(pair));
    ll_song_pair_destroy(pair);
}
static void midCallListeningProgress() {
    constexpr uint64_t start = uint64_t{1} << 40;
    LLSongReplay a(17, 1200, 1), b(700000, 1400, 2), c(9000000, 1500, 3);
    auto *pair = ll_song_pair_create_transport_at(&a, &b, start, start + 800, 0, start + 1600);
    CHECK(pair && ll_song_pair_listening_position64(pair) == start);
    std::atomic<uint32_t> gate{0};
    progressGate = &gate;
    std::vector<float> output(4096);
    uint32_t written = 0;
    std::thread consumer([&] {
        CHECK(checked([&] { return ll_song_pair_render(pair, output.data(), 2048, &written); }));
    });
    const auto stop = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (gate.load(std::memory_order_acquire) != 1) {
        CHECK(std::chrono::steady_clock::now() < stop);
        std::this_thread::yield();
    }
    // The child has retired during this still-active call. Its current musical
    // selection must use generated progress, not the prior completed call's cursor.
    CHECK(ll_song_pair_position64(pair) == start);
    CHECK(ll_song_pair_listening_position64(pair) == start + 1040);
    LLSongReplay *retired = nullptr;
    CHECK(ll_song_pair_claim_retired(pair, &retired) && retired == &a);
    CHECK(ll_song_pair_publish_transport(pair, &c, start + 1600, start + 3000));
    gate.store(2, std::memory_order_release);
    consumer.join();
    progressGate = nullptr;
    CHECK(written == 2048 && ll_song_pair_position64(pair) == start + written);
    CHECK(ll_song_pair_listening_position64(pair) == start + written);
    CHECK(identical(
        output, reference(start, 0, 2048,
                          {{start, 1200, 1}, {start + 800, 1400, 2}, {start + 1600, 1500, 3}})));
    ll_song_pair_destroy(pair);
}
static void rejectionAndFaults() {
    constexpr uint64_t limit = uint64_t{1} << 52;
    LLSongReplay a(100, 400, 1), b(200, 400, 2);
    CHECK(!ll_song_pair_create_transport_at(&a, &b, limit, limit + 1, 0, limit + 2));
    CHECK(!ll_song_pair_create_transport_at(&a, &b, 1000, 1200, 999, 1500));
    CHECK(!ll_song_pair_create_transport_at(&a, &b, 1000, 1200, 1000, 1500));
    CHECK(!ll_song_pair_create_transport_at(&a, &b, 1000, 1200, 1200, 1500));
    CHECK(!ll_song_pair_create_transport(&a, &b, 0, 500, 500));
    CHECK(!ll_song_pair_create_transport(&a, &b, 400, 500, 500));
    CHECK(!ll_song_pair_create_transport(&a, &b, 200, 0, 399));
    CHECK(!ll_song_pair_create_transport(&a, &b, 200, 0, 600));
    a.voices = 64;
    CHECK(!ll_song_pair_create_transport(&a, &b, 200, 500, 500));
    a.voices = 63;
    a.position = 1;
    CHECK(!ll_song_pair_create_transport(&a, &b, 200, 500, 500));
    a.position = 0;
    for (int index = 0; index < 2; ++index) {
        failAllocation = index;
        allocationIndex = 0;
        const auto news = allocations, frees = releases;
        CHECK(!ll_song_pair_create_transport(&a, &b, 200, 500, 500));
        CHECK(allocations - news == releases - frees);
        CHECK(a.position == 0 && b.position == 0);
    }
    failAllocation = -1;
    auto *pair = ll_song_pair_create_transport(&a, &b, 200, 500, 500);
    CHECK(pair);
    std::array<float, 1024> output{};
    uint32_t written = 8;
    CHECK(!checked([&] { return ll_song_pair_render(pair, nullptr, 1, &written); }));
    CHECK(written == 0 && ll_song_pair_position64(pair) == 0 && !ll_song_pair_faulted(pair));
    CHECK(!checked([&] { return ll_song_pair_render(pair, output.data(), 512, nullptr); }));
    CHECK(!checked([&] {
        return ll_song_pair_render(pair, output.data(), 512,
                                   reinterpret_cast<uint32_t *>(output.data() + 1));
    }));
    CHECK(ll_song_pair_position64(pair) == 0 && a.position == 0 && b.position == 0);
    CHECK(checked([&] { return ll_song_pair_render(pair, nullptr, 0, &written); }) && !written);
    a.failOnCall = 2;
    CHECK(!checked([&] { return ll_song_pair_render(pair, output.data(), 512, &written); }));
    CHECK(written == 0 && ll_song_pair_faulted(pair) && ll_song_pair_position64(pair) == 0);
    CHECK(a.position > 0 &&
          std::all_of(output.begin(), output.end(), [](float x) { return x == 0; }));
    ll_song_pair_destroy(pair);
    CHECK(!ll_song_pair_finished(nullptr) && !ll_song_pair_frames64(nullptr) &&
          !ll_song_pair_position64(nullptr));
}
static void floatingModes() {
    const auto expected = reference(0, 500, 500, {{0, 400, 1}, {200, 400, 2}});
    const auto saved = state();
#if defined(__aarch64__)
    constexpr uint32_t flushCount = 2;
#else
    constexpr uint32_t flushCount = 4;
#endif
    for (uint32_t rounding = 0; rounding < 4; ++rounding)
        for (uint32_t flush = 0; flush < flushCount; ++flush)
            for (uint32_t seeded = 0; seeded < 2; ++seeded) {
                FP mode = saved;
#if defined(__aarch64__)
                mode.control = (mode.control & ~((uint64_t{3} << 22) | (uint64_t{1} << 24))) |
                               (uint64_t{rounding} << 22) | (uint64_t{flush} << 24);
                mode.status = seeded ? 0x11 : 0;
#else
                mode.control = (mode.control & ~uint64_t{0xe07f}) | (uint64_t{rounding} << 13) |
                               ((flush & 1) ? 0x8000 : 0) | ((flush & 2) ? 0x40 : 0) |
                               (seeded ? 0x21 : 0);
#endif
                install(mode);
                LLSongReplay a(700, 400, 1), b(900, 400, 2);
                auto *pair = checked(
                    [&] { return ll_song_pair_create_transport(&a, &b, 200, 500, 500); }, false);
                CHECK(pair);
                std::array<float, 1024> output{};
                uint32_t written = 0;
                CHECK(checked(
                    [&] { return ll_song_pair_render(pair, output.data(), 512, &written); }));
                CHECK(written == 500);
                CHECK(std::memcmp(output.data(), expected.data(),
                                  expected.size() * sizeof(float)) == 0);
                ll_song_pair_destroy(pair);
            }
    install(saved);
}
int main() {
    legacyEquivalence();
    for (const uint64_t start : {uint64_t{0}, (uint64_t{1} << 32) - 100, uint64_t{1} << 40})
        for (const uint32_t frames : {2u, 159u, 160u, 161u, 257u, 400u})
            finitePlacement(start, frames);
    finitePlacement((uint64_t{1} << 52) - 800, 400);
    continuousAndPublication();
    rejectionAndFaults();
    midCallListeningProgress();
    floatingModes();
    std::puts("Song transport clock and placement tests passed");
}
