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
#include <new>
#include <thread>
#include <vector>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif
#pragma STDC FENV_ACCESS ON

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
        std::fprintf(stderr, "Song Next assertion failed at line %d\n", line);
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

constexpr uint32_t oldFrames = 32000, oldOutro = 24000, boundary = 12000;
constexpr uint32_t delta = oldOutro - boundary, deadline = boundary - 3520;
static LLEvent event(uint32_t onset, uint8_t kind, uint8_t midi, uint32_t hold = 18000) {
    return {onset, kind >= 3 ? 1u : 0u, hold, 2000, .875f, -.25f, kind, 0, 0, midi};
}
static std::vector<LLEvent> score() {
    return {event(0, 0, 60),
            event(100, 3, 0),
            event(1000, 2, 40),
            event(2000, 1, 64, 9000),
            event(3000, 4, 1),
            event(deadline, 3, 0),
            event(10000, 0, 67),
            event(oldOutro, 1, 64, 5000),
            event(oldOutro + 900, 0, 60, 5000),
            event(26000, 2, 40, 3000)};
}
struct Song {
    LLMixer *mixer = ll_mixer_create();
    LLSongSource *source = nullptr;
    LLSongReplay *replay = nullptr;
    Song(uint64_t origin, std::vector<LLEvent> events = score(), bool shortened = false,
         double texture = 0, uint32_t hitFrames = 1600) {
        const uint32_t frames = oldFrames - (shortened ? delta : 0);
        const uint32_t outro = shortened ? boundary : oldOutro;
        LLSongSourceConfig c{origin,
                             frames,
                             1278560406,
                             0,
                             .5,
                             .75,
                             texture,
                             {0, 0, double(origin + outro), double(origin + outro + 4000),
                              double(origin), double(origin + outro + 2000)}};
        CHECK(mixer && ll_mixer_configure_origin(mixer, origin));
        CHECK(ll_mixer_configure_buses(mixer, .5));
        CHECK(ll_mixer_configure_fades(mixer, &c.rack_fades));
        std::vector<float> pcm(oldFrames);
        for (uint32_t i = 0; i < pcm.size(); ++i)
            pcm[i] = float(int(i % 31) - 15) / 4;
        CHECK(ll_mixer_add_sample(mixer, pcm.data(), oldFrames, 1) == 0);
        CHECK(ll_mixer_add_sample(mixer, pcm.data(), hitFrames, 1) == 1);
        for (auto &e : events)
            e.start_frame += origin;
        CHECK(ll_mixer_load_events(mixer, events.data(), uint32_t(events.size())));
        source = ll_song_source_create(mixer, &c);
        CHECK(source);
        replay = ll_song_replay_create(source, -35);
        CHECK(replay);
    }
    ~Song() {
        ll_song_replay_destroy(replay);
        ll_song_source_destroy(source);
        ll_mixer_destroy(mixer);
    }
};
struct Pair {
    LLSongPair *value;
    Pair(Song &first, Song &second, bool shortened = false, uint64_t end = oldFrames)
        : value(ll_song_pair_create_transport(first.replay, second.replay,
                                              shortened ? boundary : oldOutro, end,
                                              shortened ? 50000 - delta : 50000)) {
        CHECK(value);
    }
    ~Pair() {
        ll_song_pair_destroy(value);
    }
};
static void append(LLSongPair *pair, std::vector<float> &output, uint32_t frames,
                   const std::vector<uint32_t> &parts) {
    std::vector<float> scratch(2 * *std::max_element(parts.begin(), parts.end()));
    uint32_t done = 0, part = 0;
    while (done < frames) {
        uint32_t written = 0;
        const auto count = std::min(frames - done, parts[part++ % parts.size()]);
        CHECK(checked([&] { return ll_song_pair_render(pair, scratch.data(), count, &written); }));
        CHECK(written > 0 && written <= count);
        output.insert(output.end(), scratch.begin(), scratch.begin() + 2 * written);
        done += written;
    }
}
static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}
static LLSongNextOffer offer(LLSongPair *pair, std::vector<float> &output) {
    CHECK(checked([&] { return ll_song_pair_request_next(pair, 0); }));
    CHECK(!ll_song_pair_request_next(pair, 0));
    append(pair, output, 1, {1});
    LLSongNextOffer value{};
    CHECK(checked([&] { return ll_song_pair_claim_next(pair, &value); }));
    CHECK(value.target_origin == 0 && value.outro_start_frames == oldOutro);
    CHECK(value.source_input_frames <= deadline);
    return value;
}
static std::vector<float> edited(const std::vector<uint32_t> &parts, double texture,
                                 uint32_t prefix = 1024) {
    LLSongNext *patch = nullptr;
    std::vector<float> output;
    {
        Song first(100000, score(), false, texture), second(900000, score(), false, texture);
        Pair pair(first, second);
        append(pair.value, output, prefix, parts);
        auto frozen = offer(pair.value, output);
        patch = checked([&] { return ll_song_pair_prepare_next(&frozen, boundary, 0x11); }, false);
        CHECK(patch && ll_song_next_required_voice_slots(patch) > 0);
        CHECK(checked([&] { return ll_song_pair_publish_next(pair.value, patch); }));
        append(pair.value, output, 1, {1});
        LLSongNextResult result{};
        CHECK(ll_song_pair_next_result(pair.value, &result));
        CHECK(result.status == 1 && result.boundary_frames == boundary &&
              result.advanced_frames == delta && result.following_origin == 50000 - delta);
        CHECK(ll_song_replay_frames(first.replay) == oldFrames - delta);
        CHECK(ll_mixer_steals(first.mixer) == 0 && ll_mixer_dropped_events(first.mixer) == 0);
        // An already advanced song satisfies duplicate Next without editing a second time.
        CHECK(ll_song_pair_request_next(pair.value, 0));
        append(pair.value, output, 1, {1});
        CHECK(ll_song_pair_next_result(pair.value, &result) && result.status == 3);
        append(pair.value, output, oldFrames - uint32_t(output.size() / 2), parts);
        CHECK(ll_song_pair_finished(pair.value));
        std::array<float, 8> tail{1, 1, 1, 1, 1, 1, 1, 1};
        uint32_t written = 99;
        CHECK(checked([&] { return ll_song_pair_render(pair.value, tail.data(), 4, &written); }));
        CHECK(written == 0 &&
              std::all_of(tail.begin(), tail.end(), [](float f) { return f == 0; }));
    } // Both borrowed children die before their accepted immutable score descriptor.
    ll_song_next_destroy(patch);
    return output;
}
static void completeChain() {
    // Independent score construction spells out the retained prefix and moved outro.
    // No Next helper participates in the expected chain. Non-pivot dropped notes occur
    // at/after the damping deadline; held C/E notes retain sample age and release gates.
    auto events = score();
    events.erase(events.begin() + 5, events.begin() + 7);
    for (auto &e : events)
        if (e.start_frame >= oldOutro)
            e.start_frame -= delta;
    std::vector<float> expected;
    {
        Song first(100000, events, true), second(900000);
        Pair pair(first, second, true);
        append(pair.value, expected, oldFrames, {257, 1, 1023, 17});
    }
    CHECK(same(expected, edited({1, 17, 256, 1023}, 0)));
    CHECK(same(expected, edited({4093}, 0, 4096)));
    // Air normalization belongs to original prepared length; preserve its RNG/effect
    // history across the edit. Compare actual in-flight edits across adoption/chunks.
    CHECK(same(edited({17, 257}, .25), edited({4093, 1}, .25, 4096)));
}
static void dampingAndImmutableTable() {
    // Independent analytic oracle frozen before native comparison, manifest SHA256
    // 13a6f6a294f43f5cb14cc7c790dae23b50a2651973eed309744149f63439a025.
    constexpr uint32_t probes[] = {8480, 8481, 9359, 10239, 10240, 11119, 11998, 11999};
    constexpr double expected[2][8] = {
        {1, .9999998211860657, .8537900447845459, .5002231597900391, .49977681040763855,
         .1465255320072174, 1.9925131766740378e-7, 0},
        {.818690836429596, .8186150193214417, .6384522914886475, .3348620533943176,
         .33451706171035767, .08586663007736206, 9.965500424868878e-8, 0}};
    for (uint32_t releasing = 0; releasing < 2; ++releasing) {
        auto note = event(0, 0, 61, releasing ? 4000 : 18000);
        note.release_frames = releasing ? 16000 : 2000;
        Song first(123456, {note}), control(123456, {note});
        std::vector<float> before(2 * 1024), output(2 * 22000), baseline(2 * 22000);
        CHECK(ll_mixer_render(first.mixer, before.data(), 1024));
        CHECK(ll_mixer_render(control.mixer, baseline.data(), 22000));
        CHECK(std::memcmp(before.data(), baseline.data(), before.size() * sizeof(float)) == 0);
        std::copy(before.begin(), before.end(), output.begin());
        LLSongAdvance info{};
        auto *patch = checked(
            [&] { return ll_mixer_prepare_advance(first.mixer, boundary, 1, info); }, false);
        CHECK(patch && info.deadline == deadline && info.delta == delta && info.voiceSlots == 1);
        CHECK(ll_mixer_can_advance(first.mixer, patch));
        checked([&] {
            ll_mixer_apply_advance(first.mixer, patch);
            return true;
        });
        CHECK(checked(
            [&] { return ll_mixer_render(first.mixer, output.data() + 2048, 22000 - 1024); }));
        CHECK(std::memcmp(output.data(), baseline.data(), 2 * (deadline + 1) * sizeof(float)) == 0);
        for (uint32_t frame = deadline; frame < boundary; ++frame) {
            const auto t = frame - deadline;
            const double c = std::cos((3.14159265358979323846 / 2) * t / 3519);
            const float damping = t == 3519 ? 0.f : float(c * c);
            for (uint32_t ch = 0; ch < 2; ++ch) {
                const auto i = 2 * frame + ch;
                CHECK(std::abs(output[i]) <= std::abs(baseline[i]));
                CHECK(std::abs(double(output[i]) - double(baseline[i]) * damping) < 2e-7);
            }
        }
        const double gain = float(.235 * std::pow(.875, 1.05));
        const float pan = float(std::cos(.75 * 3.14159265358979323846 / 4)) * float(std::sqrt(2.0));
        for (uint32_t i = 0; i < 8; ++i) {
            const float pcm = float(int(probes[i] % 31) - 15) / 4;
            CHECK(pcm != 0);
            CHECK(std::abs(double(output[2 * probes[i]]) / (pcm * gain * pan) -
                           expected[releasing][i]) < 2e-7);
        }
        CHECK(std::all_of(output.begin() + 2 * (boundary - 1), output.end(),
                          [](float f) { return f == 0; }));
        CHECK(ll_mixer_active_voices(first.mixer) == 0);
        ll_song_replay_destroy(first.replay);
        first.replay = nullptr;
        ll_song_source_destroy(first.source);
        first.source = nullptr;
        ll_mixer_destroy(first.mixer);
        first.mixer = nullptr;
        ll_mixer_destroy_advance(patch);
    }
    // Independent half-open reader intervals: [0,12000), [8000,20000),
    // [8300,18300), [12000,15000), plus the loaded rack's reserved bass slot.
    auto old = event(0, 0, 61);
    auto held = event(8000, 0, 60, 10000);
    auto hit = event(8300, 3, 0);
    auto removedBass = event(10000, 2, 40);
    auto outro = event(oldOutro, 0, 60, 1000);
    Song intervals(0, {old, held, hit, removedBass, outro}, false, 0, 10000);
    LLSongAdvance info{};
    auto *patch = ll_mixer_prepare_advance(intervals.mixer, boundary, 1, info);
    CHECK(patch && info.voiceSlots == 4);
    ll_mixer_destroy_advance(patch);
}
static void rejectionAndAllocation() {
    Song first(0), second(900000);
    Pair pair(first, second);
    std::vector<float> output;
    auto frozen = offer(pair.value, output);
    CHECK(!ll_song_pair_prepare_next(&frozen, 3519, 1));
    CHECK(!ll_song_pair_prepare_next(&frozen, oldOutro, 1));
    CHECK(!ll_song_pair_prepare_next(&frozen, boundary, 0));
    CHECK(!ll_song_pair_prepare_next(&frozen, boundary, 0x1000));
    const auto oldPosition = ll_song_replay_position(first.replay);
    for (int allocation = 0; allocation < 3; ++allocation) {
        const auto live = allocations - releases;
        allocationIndex = 0;
        failAllocation = allocation;
        auto *failed = ll_song_pair_prepare_next(&frozen, boundary, 0x11);
        failAllocation = -1;
        CHECK(!failed && allocations - releases == live);
    }
    CHECK(ll_song_replay_position(first.replay) == oldPosition);
    auto *patch = ll_song_pair_prepare_next(&frozen, boundary, 0x11);
    CHECK(patch);
    append(pair.value, output, deadline, {257});
    CHECK(ll_song_pair_publish_next(pair.value, patch));
    append(pair.value, output, 1, {1});
    LLSongNextResult result{};
    CHECK(ll_song_pair_next_result(pair.value, &result) && result.status == 2);
    CHECK(ll_song_replay_frames(first.replay) == oldFrames);
    ll_song_next_destroy(patch);
    // Rejection preserves all existing signal state, not a rewind of the original rack.
    append(pair.value, output, oldFrames - uint32_t(output.size() / 2), {4093});
    Song controlFirst(0), controlSecond(900000);
    Pair control(controlFirst, controlSecond);
    std::vector<float> expected;
    append(control.value, expected, oldFrames, {17, 257});
    CHECK(same(output, expected));
}
static void capacityAndBassReservation() {
    std::vector<LLEvent> crowded;
    for (uint32_t i = 0; i < 30; ++i)
        crowded.push_back(event(0, 0, 60));
    for (uint32_t i = 0; i < 30; ++i)
        crowded.push_back(event(oldOutro, 0, 60, 5000));
    Song first(0, crowded), second(900000, std::vector<LLEvent>(5, event(0, 0, 60)));
    Pair pair(first, second);
    std::vector<float> output;
    auto frozen = offer(pair.value, output);
    CHECK(ll_song_replay_required_voice_slots(first.replay) == 30);
    CHECK(!ll_song_pair_prepare_next(&frozen, boundary, 1)); // 60 + 5 exceeds global64.
    CHECK(ll_song_pair_abandon_next(pair.value));
    CHECK(!ll_song_pair_abandon_next(pair.value));
    auto silent = event(0, 0, 60);
    silent.velocity = 0;
    crowded.insert(crowded.begin(), silent);
    Song exactFirst(0, crowded), exactSecond(900000, std::vector<LLEvent>(4, event(0, 0, 60)));
    Pair exact(exactFirst, exactSecond);
    std::vector<float> exactOutput;
    auto exactOffer = offer(exact.value, exactOutput);
    auto *accepted = ll_song_pair_prepare_next(&exactOffer, boundary, 1);
    CHECK(accepted && ll_song_next_required_voice_slots(accepted) == 60);
    CHECK(ll_song_pair_abandon_next(exact.value));
    ll_song_next_destroy(accepted);

    Song bass(0, {event(0, 0, 60), event(10000, 2, 40)});
    LLSongAdvance info{};
    auto *patch = ll_mixer_prepare_advance(bass.mixer, boundary, 1, info);
    CHECK(patch && info.voiceSlots == 2); // Removed future bass still reserves its slot.
    ll_mixer_destroy_advance(patch);
}
static void retirementPins() {
    for (uint32_t state = 0; state < 3; ++state) {
        LLSongNext *patch = nullptr;
        {
            Song first(0), second(900000);
            Pair pair(first, second, false, 0);
            std::vector<float> output;
            CHECK(ll_song_pair_request_next(pair.value, 0));
            append(pair.value, output, 1, {1});
            if (state) {
                LLSongNextOffer frozen{};
                CHECK(ll_song_pair_claim_next(pair.value, &frozen));
                if (state == 2) {
                    patch = ll_song_pair_prepare_next(&frozen, boundary, 0x11);
                    CHECK(patch && ll_song_pair_publish_next(pair.value, patch));
                }
            }
            append(pair.value, output, oldFrames, {257});
            LLSongReplay *retired = nullptr;
            if (state)
                CHECK(!ll_song_pair_claim_retired(pair.value, &retired) && !retired);
            if (state == 1)
                CHECK(ll_song_pair_abandon_next(pair.value));
            if (state == 2) {
                LLSongNextResult result{};
                CHECK(ll_song_pair_next_result(pair.value, &result) && result.status == 1);
            }
            CHECK(ll_song_pair_claim_retired(pair.value, &retired) && retired == first.replay);
            if (!state) {
                LLSongNextOffer invalid{};
                LLSongNextResult result{};
                CHECK(!ll_song_pair_claim_next(pair.value, &invalid));
                CHECK(ll_song_pair_next_result(pair.value, &result) && result.status == 2);
            }
        }
        ll_song_next_destroy(patch);
    }
}
static void concurrentPreparation() {
    uint32_t accepted = 0;
    for (uint32_t trial = 0; trial < 8; ++trial) {
        LLSongNext *patch = nullptr;
        LLSongNextResult result{};
        std::vector<float> output;
        {
            Song first(100000, score(), false, 0), second(900000, score(), false, 0);
            Pair pair(first, second, false, 0);
            auto frozen = offer(pair.value, output);
            std::atomic<bool> acknowledged{false};
            std::thread worker([&] {
                // The offer alone precedes both threads. No worker-to-consumer edge
                // outside the native mailbox may publish the descriptor before adoption.
                patch = ll_song_pair_prepare_next(&frozen, boundary, 0x11);
                CHECK(patch &&
                      checked([&] { return ll_song_pair_publish_next(pair.value, patch); }));
                const auto stop = std::chrono::steady_clock::now() + std::chrono::seconds(10);
                while (!ll_song_pair_next_result(pair.value, &result)) {
                    CHECK(std::chrono::steady_clock::now() < stop);
                    std::this_thread::yield();
                }
                // This only ends the harness, after native adoption AND acknowledgment.
                acknowledged.store(true, std::memory_order_relaxed);
            });
            std::array<float, 514> block{};
            const auto stop = std::chrono::steady_clock::now() + std::chrono::seconds(10);
            while (!acknowledged.load(std::memory_order_relaxed)) {
                CHECK(std::chrono::steady_clock::now() < stop);
                uint32_t written = 0;
                CHECK(checked(
                    [&] { return ll_song_pair_render(pair.value, block.data(), 257, &written); }));
                output.insert(output.end(), block.begin(), block.begin() + 2 * written);
                std::this_thread::yield();
            }
            worker.join(); // Only after all tested ready/adopt/result communication.
            CHECK(result.status == 1 || result.status == 2);
            accepted += result.status == 1;
        }
        // An arbitrarily late worker may be rejected. Either result must preserve
        // the complete corresponding signal history, with no rewind or partial edit.
        auto events = score();
        if (result.status == 1) {
            events.erase(events.begin() + 5, events.begin() + 7);
            for (auto &e : events)
                if (e.start_frame >= oldOutro)
                    e.start_frame -= delta;
        }
        std::vector<float> expected;
        {
            Song first(100000, events, result.status == 1), second(900000);
            Pair control(first, second, result.status == 1, 0);
            append(control.value, expected, uint32_t(output.size() / 2), {17, 257});
        }
        CHECK(same(output, expected));
        ll_song_next_destroy(patch);
    }
    CHECK(accepted > 0); // Ensure the payload publication path actually ran under TSan.
}
static void floatingModes() {
    const auto saved = state();
    Song first(0), second(900000);
    Pair pair(first, second);
    std::vector<float> output;
    for (uint32_t rounding = 0; rounding < 4; ++rounding)
        for (uint32_t flags = 0; flags < 2; ++flags) {
            FP value = saved;
#if defined(__aarch64__)
            value.control = (saved.control & ~(uint64_t{3} << 22)) | (uint64_t{rounding} << 22);
            value.control ^= uint64_t{1} << 24;
            value.status = flags ? 0x9f : 0;
#else
            value.control = (saved.control & ~uint64_t{0x603f}) | (uint64_t{rounding} << 13) |
                            (flags ? 0x3f : 0);
            value.control ^= 0x8040;
#endif
            install(value);
            CHECK(checked([&] { return ll_song_pair_request_next(pair.value, 0); }));
            std::array<float, 2> buffer{};
            uint32_t written = 0;
            CHECK(checked(
                [&] { return ll_song_pair_render(pair.value, buffer.data(), 1, &written); }));
            LLSongNextOffer frozen{};
            CHECK(checked([&] { return ll_song_pair_claim_next(pair.value, &frozen); }));
            auto *patch =
                checked([&] { return ll_song_pair_prepare_next(&frozen, boundary, 0x11); }, false);
            CHECK(patch);
            checked(
                [&] {
                    ll_song_next_destroy(patch);
                    return true;
                },
                false);
            CHECK(checked([&] { return ll_song_pair_abandon_next(pair.value); }));
            install(saved);
        }
}
int main() {
    completeChain();
    dampingAndImmutableTable();
    rejectionAndAllocation();
    capacityAndBassReservation();
    floatingModes();
    retirementPins();
    concurrentPreparation();
    std::puts("Song Next real-chain edit tests passed");
}
