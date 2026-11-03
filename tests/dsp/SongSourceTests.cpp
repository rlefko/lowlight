// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <array>
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
    if (!good) { std::fprintf(stderr, "Song source assertion failed at line %d\n", line); std::abort(); }
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
static uint32_t roomCalls = 0, roomFailure = 0;
// SongSource.cpp alone is compiled with this symbol substitution, never production.
extern "C" bool ll_test_room_process(LLRoom *room, const LLGlueFrame *input, LLGlueFrame *output, uint32_t count) {
    if (++roomCalls == roomFailure) return false;
    return ll_room_process(room, input, output, count);
}
static LLSongSourceConfig config(uint32_t frames, uint64_t origin = 0) {
    return {origin, frames, 1278560406, 0, .5, .75, .125,
        {0, 0, double(origin), double(origin + frames), double(origin), double(origin + frames)}};
}
struct Mixer {
    LLMixer *value = ll_mixer_create();
    explicit Mixer(const LLSongSourceConfig &c, bool notes = true) {
        CHECK(value && ll_mixer_configure_origin(value, c.frame_origin));
        CHECK(ll_mixer_configure_buses(value, .5) && ll_mixer_configure_fades(value, &c.rack_fades));
        std::array<float, 384> pcm{};
        for (uint32_t i = 0; i < pcm.size(); ++i) pcm[i] = float(int(i % 19) - 9) / 32;
        CHECK(ll_mixer_add_sample(value, pcm.data(), uint32_t(pcm.size()), 1) == 0);
        std::vector<LLEvent> events;
        if (notes) for (uint8_t kind = 0; kind < 7; ++kind)
            events.push_back({c.frame_origin + std::min(uint32_t(kind) * 13, c.input_frames - 1), 0,
                              257, 129, .75f, kind & 1 ? .25f : -.25f, kind, 0, 0,
                              uint8_t(kind == 2 ? 40 : (kind == 4 ? 1 : 0))});
        if (notes) events.push_back({c.frame_origin + c.input_frames - 1, 0, 1, 0, .5f, 0, 3, 0, 0, 0});
        CHECK(ll_mixer_load_events(value, events.data(), uint32_t(events.size())));
    }
    ~Mixer() { ll_mixer_destroy(value); }
};
struct Source {
    LLSongSource *value;
    Source(Mixer &m, const LLSongSourceConfig &c) : value(checked([&] { return ll_song_source_create(m.value, &c); }, false)) {
        CHECK(value);
    }
    ~Source() { ll_song_source_destroy(value); }
    void reset() { checked([&] { ll_song_source_reset(value); return true; }); }
};
static bool pull(LLSongSource *source, float *output, uint32_t capacity, uint32_t *written) {
    return checked([&] { return ll_song_source_render(source, output, capacity, written); });
}
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
static bool zero(float sample) { return sample == 0; }
static std::vector<float> reference(Mixer &m, const LLSongSourceConfig &c) {
    // Independent existing-stage assembly materializes physical glue output, then
    // removes exactly its documented latency before room/air see any song frames.
    auto *glue = ll_glue_create(c.input_frames, c.focus); auto *room = ll_room_create(c.space, c.warmth);
    auto *mix = ll_song_mix_create(c.take_seed, c.input_frames, c.frame_origin, c.texture, &c.rack_fades);
    CHECK(glue && room && mix);
    std::vector<LLBusFrame> buses(c.input_frames);
    std::vector<LLGlueFrame> delayed(c.input_frames + LL_GLUE_LATENCY), wet(c.input_frames);
    std::vector<float> result(2 * c.input_frames); uint32_t written = 0;
    CHECK(ll_mixer_render_buses(m.value, buses.data(), c.input_frames));
    CHECK(ll_glue_process(glue, buses.data(), delayed.data(), c.input_frames));
    CHECK(ll_glue_drain(glue, delayed.data() + c.input_frames, LL_GLUE_LATENCY, &written) && written == LL_GLUE_LATENCY);
    CHECK(ll_room_process(room, delayed.data() + LL_GLUE_LATENCY, wet.data(), c.input_frames));
    CHECK(ll_song_mix_process(mix, wet.data(), result.data(), c.input_frames));
    ll_song_mix_destroy(mix); ll_room_destroy(room); ll_glue_destroy(glue); return result;
}
static std::vector<float> render(Source &source, uint32_t frames, const std::vector<uint32_t> &blocks) {
    std::vector<float> result; result.reserve(2 * frames);
    std::vector<float> output(2 * *std::max_element(blocks.begin(), blocks.end()) + 1, 7);
    uint32_t offset = 0, index = 0;
    while (offset < frames) {
        const uint32_t capacity = blocks[index++ % blocks.size()]; uint32_t written = 99;
        std::fill(output.begin(), output.end(), 7);
        CHECK(pull(source.value, output.data(), capacity, &written) && written == std::min(capacity, frames - offset));
        CHECK(std::all_of(output.begin() + 2 * written, output.begin() + 2 * capacity, zero));
        CHECK(output[2 * capacity] == 7);
        result.insert(result.end(), output.begin(), output.begin() + 2 * written); offset += written;
        CHECK(ll_song_source_position(source.value) == offset && !ll_song_source_faulted(source.value));
    }
    return result;
}
static void alignmentAndReset() {
    for (const uint32_t n : {1u, 2u, 257u, 398u, 399u, 400u, 401u, 8193u, 32769u}) {
        auto c = config(n); Mixer baseline(c); const auto expected = reference(baseline, c);
        for (const uint64_t origin : {uint64_t{0}, uint64_t{1} << 40}) {
            c = config(n, origin); Mixer mixer(c); Source source(mixer, c);
            CHECK(same(expected, render(source, n, {n + 7})));
            CHECK(ll_mixer_position(mixer.value) == origin + n);
            uint32_t written = 7; float tail[7]{7, 7, 7, 7, 7, 7, 7};
            CHECK(pull(source.value, tail, 3, &written) && !written && tail[6] == 7);
            CHECK(std::all_of(tail, tail + 6, zero) && pull(source.value, nullptr, 0, &written));
            source.reset(); CHECK(ll_mixer_position(mixer.value) == origin && ll_song_source_position(source.value) == 0);
            CHECK(same(expected, render(source, n, {1, 17, 256, 257, 1023})));
            source.reset(); CHECK(pull(source.value, tail, 1, &written) && written == 1);
            source.reset(); CHECK(same(expected, render(source, n, {113})));
        }
    }
}
static void invalidCallsAndFault() {
    const auto c = config(4097); Mixer baseline(c); const auto expected = reference(baseline, c);
    Mixer mixer(c); Source source(mixer, c); uint32_t written = 99; std::array<float, 1601> output{};
    CHECK(pull(source.value, output.data(), 17, &written) && written == 17);
    const auto clock = ll_mixer_position(mixer.value);
    CHECK(!pull(source.value, nullptr, 1, &written) && !written);
    output.fill(7); CHECK(!pull(source.value, output.data(), 3, nullptr));
    CHECK(std::all_of(output.begin(), output.begin() + 6, zero) && output[6] == 7);
    output.fill(7); CHECK(!pull(source.value, output.data(), 3, reinterpret_cast<uint32_t *>(output.data() + 1)));
    CHECK(std::all_of(output.begin(), output.begin() + 6, zero));
    CHECK(ll_song_source_position(source.value) == 17 && ll_mixer_position(mixer.value) == clock);
    CHECK(!ll_song_source_faulted(source.value));
    roomCalls = 0; roomFailure = 2;
    output.fill(7); CHECK(!pull(source.value, output.data(), 800, &written) && !written);
    CHECK(roomCalls == 2 && std::all_of(output.begin(), output.end() - 1, zero) && output.back() == 7);
    CHECK(ll_song_source_position(source.value) == 17 && ll_song_source_faulted(source.value));
    CHECK(ll_mixer_position(mixer.value) > clock); // Failure is terminal, not whole-chain rollback.
    CHECK(!pull(source.value, nullptr, 0, &written)); roomFailure = 0;
    source.reset(); CHECK(same(expected, render(source, c.input_frames, {257})));
    CHECK(!pull(nullptr, output.data(), 1, &written) && !written && output[0] == 0 && output[1] == 0);
    CHECK(ll_song_source_faulted(nullptr) && ll_song_source_position(nullptr) == 0 && ll_mixer_origin(nullptr) == 0);
    ll_song_source_destroy(nullptr); ll_song_source_reset(nullptr);
}
static void setupValidation() {
    const auto c = config(1025, 64); Mixer mixer(c);
    auto reject = [&](const LLSongSourceConfig &bad) {
        CHECK(!checked([&] { return ll_song_source_create(mixer.value, &bad); }, false));
        CHECK(ll_mixer_position(mixer.value) == 64 && ll_mixer_origin(mixer.value) == 64);
    };
    CHECK(!ll_song_source_create(nullptr, &c) && !ll_song_source_create(mixer.value, nullptr));
    for (uint32_t count : {0u, uint32_t(LL_AIR_MAX_FRAMES) + 1, UINT32_MAX}) { auto bad = c; bad.input_frames = count; reject(bad); }
    auto bad = c; bad.focus = 2; reject(bad); bad = c; bad.take_seed = uint32_t{1} << 31; reject(bad);
    for (uint64_t origin : {uint64_t{0}, uint64_t{1} << 52, UINT64_MAX}) { bad = c; bad.frame_origin = origin; reject(bad); }
    for (double value : {-std::numeric_limits<double>::denorm_min(), 1.01, std::numeric_limits<double>::signaling_NaN()}) {
        bad = c; bad.space = value; reject(bad); bad = c; bad.warmth = value; reject(bad); bad = c; bad.texture = value; reject(bad);
    }
    bad = c; bad.rack_fades.tonal_out_end_frame = bad.rack_fades.tonal_out_start_frame; reject(bad);
    for (int fail = 0; fail < 5; ++fail) {
        const auto live = allocations - frees; allocationAttempt = 0; allocationFailure = fail;
        CHECK(!ll_song_source_create(mixer.value, &c)); allocationFailure = -1;
        CHECK(allocations - frees == live && ll_mixer_position(mixer.value) == 64);
    }
    auto *unready = ll_mixer_create(); bad = config(1025);
    CHECK(!ll_song_source_create(unready, &bad)); CHECK(ll_mixer_load_events(unready, nullptr, 0));
    CHECK(!ll_song_source_create(unready, &bad)); ll_mixer_destroy(unready);
    Mixer advanced(config(1025)); std::array<LLBusFrame, 64> buses{};
    CHECK(ll_mixer_render_buses(advanced.value, buses.data(), 64));
    CHECK(!ll_song_source_create(advanced.value, &c)); // Position matches; configured reset origin does not.
    CHECK(!ll_song_source_create(advanced.value, &bad)); // Correct origin but advanced state also fails.
    const auto edge = config(1, (uint64_t{1} << 52) - 1); Mixer empty(edge, false); Source final(empty, edge);
    CHECK(render(final, 1, {3}).size() == 2 && ll_mixer_position(empty.value) == (uint64_t{1} << 52));
}
static void floatingModes() {
    const auto original = state(); const auto c = config(1025); Mixer baseline(c);
    const auto expected = reference(baseline, c);
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
        Mixer mixer(c); Source source(mixer, c); CHECK(same(expected, render(source, c.input_frames, {1, 257})));
        source.reset(); uint32_t written = 99; CHECK(!pull(source.value, nullptr, 1, &written) && !written);
        auto bad = c; bad.texture = -std::numeric_limits<double>::denorm_min();
        CHECK(!checked([&] { return ll_song_source_create(mixer.value, &bad); }, false));
    }
    install(original);
}
int main() {
    alignmentAndReset(); invalidCallsAndFault(); setupValidation(); floatingModes();
    std::puts("Song source alignment, finite pulls, reset/origin, terminal faults, bounds, FP and allocation audits passed");
}
