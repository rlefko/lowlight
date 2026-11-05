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
#include <memory>
#include <limits>
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
        std::fprintf(stderr, "Song Controls assertion failed at line %d\n", line);
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
         double texture = 0, uint32_t hitFrames = 1600, const std::vector<float> &extra = {}) {
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
        if (!extra.empty())
            CHECK(ll_mixer_add_sample(mixer, extra.data(), uint32_t(extra.size()), 1) == 2);
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
struct ChangeFixture {
    std::unique_ptr<Song> first{new Song(100000)}, second{new Song(900000)};
    LLSongPair *pair =
        ll_song_pair_create_transport(first->replay, second->replay, oldOutro, oldFrames, 50000);
    LLSongRevision *intent = ll_song_revision_create();
    LLSongChange *change = nullptr;
    LLSongChangeOffer frozen{};
    std::vector<float> output;
    ChangeFixture() {
        CHECK(pair && intent && ll_song_revision_set(intent, 1));
        CHECK(ll_song_pair_request_change(pair, 0, 1, intent));
        CHECK(!ll_song_pair_request_next(pair, 0));
        append(pair, output, 1, {1});
        CHECK(ll_song_pair_claim_change(pair, &frozen));
        CHECK(frozen.original_origin == oldOutro && frozen.original_frames == oldFrames);
    }
    ~ChangeFixture() {
        ll_song_pair_destroy(pair);
        first.reset();
        second.reset();
        ll_song_change_destroy(change);
        ll_song_revision_destroy(intent);
    }
    void withdraw() {
        CHECK(ll_song_pair_withdraw_change(pair, change));
        append(pair, output, 1, {1});
        LLSongReplay *old = nullptr;
        CHECK(ll_song_pair_claim_withdrawn_change(pair, &old) && old == second->replay);
        second.reset();
    }
    void rollback() {
        second.reset(new Song(900000));
        CHECK(ll_song_pair_restore_change(pair, second->replay));
        append(pair, output, 1, {1});
        LLSongChangeResult result{};
        CHECK(ll_song_pair_change_result(pair, &result) && result.status == 4);
        CHECK(ll_song_replay_frames(first->replay) == oldFrames);
    }
};
static std::vector<float> newPCM() {
    std::vector<float> result(6000);
    for (uint32_t i = 0; i < result.size(); ++i)
        result[i] = float(int(i % 17) - 8) * .2f;
    return result;
}
static std::vector<LLEvent> futureEvents() {
    auto first = event(boundary + 100, 0, 67, 4000);
    first.sample_index = 1;
    auto second = event(boundary + 200, 2, 40, 3000);
    second.sample_index = 0;
    return {first, second};
}
static LLSongChangeScore configuration(const std::vector<LLEvent> &events) {
    return {events.data(),
            nullptr,
            uint32_t(events.size()),
            0,
            boundary,
            oldFrames - delta,
            0x91,
            {0, 0, 100000 + boundary, 100000 + boundary + 4000, 100000, 100000 + boundary + 2000}};
}
static LLSongChange *prepare(ChangeFixture &fixture) {
    auto *change = ll_song_pair_begin_change(&fixture.frozen);
    CHECK(change);
    LLSongChangeSample original{0, nullptr, 0, 0};
    CHECK(ll_song_change_add_sample(change, &original) == 0);
    auto pcm = newPCM();
    LLSongChangeSample supplemental{-1, pcm.data(), uint32_t(pcm.size()), 1};
    CHECK(ll_song_change_add_sample(change, &supplemental) == 1);
    // PCM is copied, never borrowed from the worker's scratch buffer.
    std::fill(pcm.begin(), pcm.end(), 0);
    auto future = futureEvents();
    for (auto &event : future)
        event.start_frame += 100000;
    auto score = configuration(future);
    CHECK(checked([&] { return ll_song_change_finish(change, &score); }, false));
    CHECK(ll_song_change_sample_bytes(change) == (32000 + 1600 + 6000) * sizeof(float));
    CHECK(ll_song_change_required_voice_slots(change) > 0);
    CHECK(ll_song_change_add_sample(change, &original) == -1);
    return change;
}
static std::vector<float> changed(const std::vector<uint32_t> &parts) {
    ChangeFixture fixture;
    fixture.change = prepare(fixture);
    fixture.withdraw();
    fixture.second.reset(new Song(900000));
    CHECK(ll_song_pair_publish_change(fixture.pair, fixture.change, fixture.second->replay,
                                      50000 - delta));
    append(fixture.pair, fixture.output, 1, {1});
    LLSongChangeResult result{};
    CHECK(ll_song_pair_change_result(fixture.pair, &result));
    CHECK(result.status == 1 && result.revision == 1 && result.boundary_frames == boundary);
    CHECK(ll_song_replay_frames(fixture.first->replay) == oldFrames - delta);
    CHECK(ll_mixer_sample_bytes(fixture.first->mixer) ==
          ll_song_change_sample_bytes(fixture.change));
    append(fixture.pair, fixture.output, oldFrames - uint32_t(fixture.output.size() / 2), parts);
    CHECK(ll_song_pair_finished(fixture.pair));
    return fixture.output;
}
static void completeChain() {
    auto events = score();
    events.resize(5); // Independently retain the prefix before the damping deadline.
    auto future = futureEvents();
    future[0].sample_index = 2; // Fresh oracle uses an ordinary third registered sample.
    events.insert(events.end(), future.begin(), future.end());
    std::vector<float> expected;
    {
        Song first(100000, events, true, 0, 1600, newPCM()), second(900000);
        Pair pair(first, second, true);
        append(pair.value, expected, oldFrames, {257, 1, 1023, 17});
    }
    CHECK(same(expected, changed({1, 17, 256, 1023})));
    CHECK(same(expected, changed({4093})));
}
static void revisionAndRollback() {
    for (int phase = 0; phase < 3; ++phase) {
        ChangeFixture fixture;
        fixture.change = prepare(fixture);
        CHECK(!ll_song_revision_set(fixture.intent, 0));
        if (phase == 0) {
            CHECK(ll_song_revision_set(fixture.intent, 2));
            CHECK(!ll_song_pair_withdraw_change(fixture.pair, fixture.change));
            CHECK(ll_song_pair_abandon_change(fixture.pair));
        } else {
            fixture.withdraw();
            if (phase == 1) {
                fixture.second.reset(new Song(900000));
                CHECK(ll_song_pair_publish_change(fixture.pair, fixture.change,
                                                  fixture.second->replay, 50000 - delta));
                CHECK(ll_song_revision_set(fixture.intent, 2));
                append(fixture.pair, fixture.output, 1, {1});
                LLSongChangeResult result{};
                CHECK(ll_song_pair_change_result(fixture.pair, &result));
                CHECK(result.status == 2 && result.withdrawn);
                fixture.second.reset();
            }
            fixture.rollback(); // Includes pre-publication preparation failure.
        }
        append(fixture.pair, fixture.output, oldFrames - uint32_t(fixture.output.size() / 2),
               {37, 1024});
        std::vector<float> expected;
        {
            Song first(100000), second(900000);
            Pair original(first, second);
            append(original.value, expected, oldFrames, {257});
        }
        CHECK(same(expected, fixture.output));
    }
}
static void lateAndWaiting() {
    ChangeFixture fixture;
    fixture.change = prepare(fixture);
    fixture.withdraw();
    append(fixture.pair, fixture.output,
           oldOutro - LL_PEAK_LATENCY - uint32_t(fixture.output.size() / 2), {1023});
    std::array<float, 512> silence;
    silence.fill(1);
    uint32_t written = 99;
    CHECK(
        checked([&] { return ll_song_pair_render(fixture.pair, silence.data(), 256, &written); }));
    CHECK(written == 0 &&
          std::all_of(silence.begin(), silence.end(), [](float x) { return x == 0; }));
    fixture.second.reset(new Song(900000));
    CHECK(ll_song_pair_publish_change(fixture.pair, fixture.change, fixture.second->replay,
                                      50000 - delta));
    CHECK(
        checked([&] { return ll_song_pair_render(fixture.pair, silence.data(), 256, &written); }));
    LLSongChangeResult result{};
    CHECK(ll_song_pair_change_result(fixture.pair, &result) && result.status == 2 &&
          result.withdrawn);
    fixture.second.reset();
    fixture.rollback();
    append(fixture.pair, fixture.output, oldFrames - uint32_t(fixture.output.size() / 2),
           {17, 513});
    CHECK(ll_song_pair_finished(fixture.pair));
}
static void capacityAndValidation() {
    ChangeFixture fixture;
    auto *change = ll_song_pair_begin_change(&fixture.frozen);
    CHECK(change);
    std::vector<float> pcm(2 * 215513, .125f);
    uint32_t remaining = LL_SAMPLE_BYTES / sizeof(float) - 33600;
    while (remaining) {
        const auto frames = std::min(remaining, 215513u);
        LLSongChangeSample sample{-1, pcm.data(), frames, 1};
        CHECK(ll_song_change_add_sample(change, &sample) >= 0);
        remaining -= frames;
    }
    LLSongChangeSample excess{-1, pcm.data(), 1, 1};
    CHECK(ll_song_change_add_sample(change, &excess) == -1);
    std::vector<LLEvent> none;
    auto score = configuration(none);
    auto invalid = score;
    invalid.input_frames = oldFrames + 1;
    CHECK(!ll_song_change_finish(change, &invalid));
    CHECK(ll_song_change_finish(change, &score));
    CHECK(ll_song_change_sample_bytes(change) == LL_SAMPLE_BYTES);
    ll_song_change_destroy(change);
    CHECK(ll_song_pair_abandon_change(fixture.pair));
    CHECK(ll_mixer_sample_bytes(fixture.first->mixer) == 33600 * sizeof(float));
}
static void invalidScoresAndSamples() {
    ChangeFixture fixture;
    auto *change = ll_song_pair_begin_change(&fixture.frozen);
    CHECK(change);
    LLSongChangeSample original{0, nullptr, 0, 0};
    CHECK(ll_song_change_add_sample(change, &original) == 0);
    float invalidPCM[] = {0, std::numeric_limits<float>::quiet_NaN()};
    LLSongChangeSample sample{-1, invalidPCM, 2, 1};
    CHECK(ll_song_change_add_sample(change, &sample) == -1);
    sample = {-2, nullptr, 0, 0};
    CHECK(ll_song_change_add_sample(change, &sample) == -1);
    std::vector<LLEvent> events(LL_EVENT_LIMIT + 1, event(100000 + boundary, 0, 60, 4000));
    auto score = configuration(events);
    CHECK(!ll_song_change_finish(change, &score));
    events.resize(64); // More than64 combined readers once the unchanged live prefix is included.
    score = configuration(events);
    CHECK(!ll_song_change_finish(change, &score));
    events.resize(1);
    events[0].midi = 61; // Not in the declared pivot.
    score = configuration(events);
    CHECK(!ll_song_change_finish(change, &score));
    ll_song_change_destroy(change);
    CHECK(ll_song_pair_abandon_change(fixture.pair));
    append(fixture.pair, fixture.output, oldOutro + 1 - uint32_t(fixture.output.size() / 2), {257});
    CHECK(ll_song_pair_request_change(fixture.pair, 0, 1, fixture.intent));
    append(fixture.pair, fixture.output, 1, {1});
    LLSongChangeResult result{};
    CHECK(ll_song_pair_change_result(fixture.pair, &result) && result.status == 3);
}
static void invalidFadesPreservePrefix() {
    ChangeFixture fixture;
    auto *change = ll_song_pair_begin_change(&fixture.frozen);
    CHECK(change);
    const std::vector<LLEvent> none;
    auto score = configuration(none);
    const double invalidEnds[] = {100000, 100000 + deadline, 100000 + boundary - 1,
                                  std::numeric_limits<double>::quiet_NaN()};
    for (const double end : invalidEnds) {
        score.fades.rhythm_out_frame = end;
        CHECK(!ll_song_change_finish(change, &score));
    }
    // Rejected metadata leaves the builder reusable and the source entirely unchanged.
    CHECK(ll_song_replay_frames(fixture.first->replay) == oldFrames);
    CHECK(ll_mixer_sample_bytes(fixture.first->mixer) == 33600 * sizeof(float));
    score.fades.rhythm_out_frame = 100000 + boundary;
    CHECK(ll_song_change_finish(change, &score));
    ll_song_change_destroy(change);
    CHECK(ll_song_pair_abandon_change(fixture.pair));
}
static void concurrentPreparation() {
    ChangeFixture fixture;
    std::atomic<int> progress{0};
    std::thread consumer([&] {
        std::vector<float> scratch;
        append(fixture.pair, scratch, 4000, {17, 511});
        progress.store(1, std::memory_order_release);
        while (progress.load(std::memory_order_acquire) != 2)
            std::this_thread::yield();
        append(fixture.pair, scratch, 1, {1});
        progress.store(3, std::memory_order_release);
    });
    fixture.change =
        prepare(fixture); // Writes only the unused arena while render reads its prefix.
    while (progress.load(std::memory_order_acquire) != 1)
        std::this_thread::yield();
    CHECK(ll_song_pair_withdraw_change(fixture.pair, fixture.change));
    progress.store(2, std::memory_order_release);
    consumer.join();
    LLSongReplay *retired = nullptr;
    CHECK(ll_song_pair_claim_withdrawn_change(fixture.pair, &retired));
    CHECK(retired == fixture.second->replay);
    fixture.second.reset();
    fixture.rollback();
}
int main() {
    const auto saved = state();
    install(saved);
    completeChain();
    revisionAndRollback();
    lateAndWaiting();
    capacityAndValidation();
    invalidScoresAndSamples();
    invalidFadesPreservePrefix();
    concurrentPreparation();
    std::puts("Song Controls bounded replacement tests passed");
}
