// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include "../../Packages/LowlightAudio/Sources/CLowlightDSP/SongAdvance.h"
#include "../../Packages/LowlightAudio/Sources/CLowlightDSP/LiveEffects.h"
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
         double texture = 0, uint32_t hitFrames = 1600, const std::vector<float> &extra = {},
         LLTonalCalibration *calibration = nullptr) {
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
        if (calibration)
            CHECK(ll_mixer_configure_tonal(mixer, calibration, 75));
        CHECK(ll_mixer_configure_buses(mixer, .5));
        CHECK(ll_mixer_configure_fades(mixer, &c.rack_fades));
        std::vector<float> pcm(oldFrames);
        for (uint32_t i = 0; i < pcm.size(); ++i)
            pcm[i] = float(int(i % 31) - 15) / 4;
        CHECK(ll_mixer_add_sample(mixer, pcm.data(), oldFrames, 1) == 0);
        CHECK(ll_mixer_add_sample(mixer, pcm.data(), hitFrames, 1) == 1);
        if (!extra.empty() && !calibration)
            CHECK(ll_mixer_add_sample(mixer, extra.data(), uint32_t(extra.size()), 1) == 2);
        for (auto &e : events) {
            if (calibration && e.instrument < 2) {
                // In live fixtures each guitar/piano event carries the production key,
                // including the independently assembled oracle's supplemental bridge.
                const auto &body = e.sample_index == 2 ? extra : pcm;
                const bool piano = e.instrument == 1;
                const auto key = piano ? 80 + e.midi - 50 : 4 * (e.midi - 50);
                std::vector<float> stereo;
                if (piano) {
                    stereo.reserve(2 * body.size());
                    for (auto sample : body) {
                        stereo.push_back(sample);
                        stereo.push_back(-.8f * sample);
                    }
                }
                const auto slot =
                    ll_mixer_add_tonal_sample(mixer, piano ? stereo.data() : body.data(),
                                              uint32_t(body.size()), piano ? 2 : 1, uint32_t(key));
                CHECK(slot >= 0);
                e.sample_index = uint32_t(slot);
            }
            e.start_frame += origin;
        }
        CHECK(ll_mixer_load_events(mixer, events.data(), uint32_t(events.size())));
        source = ll_song_source_create(mixer, &c);
        CHECK(source);
        replay = ll_song_replay_create(source, -35);
        CHECK(replay);
    }
    Song(uint64_t origin, LLTonalCalibration *calibration)
        : Song(origin, score(), false, 0, 1600, {}, calibration) {}
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
    LLTonalCalibration *calibration;
    std::unique_ptr<Song> first, second;
    LLSongPair *pair;
    LLSongRevision *intent = ll_song_revision_create();
    LLSongChange *change = nullptr;
    LLSongChangeOffer frozen{};
    std::vector<float> output;
    explicit ChangeFixture(LLTonalCalibration *table = nullptr)
        : calibration(table), first(new Song(100000, table)), second(new Song(900000, table)),
          pair(ll_song_pair_create_transport(first->replay, second->replay, oldOutro,
                                             table ? 0 : oldFrames, 50000)) {
        if (table)
            CHECK(ll_song_pair_seed_effects(pair, {.75, .5, 0}, 75));
        CHECK(pair && intent && ll_song_revision_set(intent, 1));
        request();
    }
    void request() {
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
        second.reset(new Song(900000, calibration));
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
static LLSongChange *prepare(ChangeFixture &fixture, bool liveSupplement = true) {
    auto *change = ll_song_pair_begin_change(&fixture.frozen);
    CHECK(change);
    LLSongChangeSample original{0, nullptr, 0, 0};
    CHECK(ll_song_change_add_sample(change, &original) == 0);
    auto pcm = newPCM();
    LLSongChangeSample supplemental{-1, pcm.data(), uint32_t(pcm.size()), 1};
    const int32_t added = fixture.calibration && liveSupplement
                              ? ll_song_change_add_tonal_sample(change, &supplemental, 68)
                              : ll_song_change_add_sample(change, &supplemental);
    CHECK(added == 1);
    // PCM is copied, never borrowed from the worker's scratch buffer.
    std::fill(pcm.begin(), pcm.end(), 0);
    auto future = futureEvents();
    for (auto &event : future)
        event.start_frame += 100000;
    auto score = configuration(future);
    CHECK(checked([&] { return ll_song_change_finish(change, &score); }, false));
    CHECK(ll_song_change_sample_bytes(change) ==
          ll_mixer_sample_bytes(fixture.first->mixer) + 6000 * sizeof(float));
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
// These two sends occur at identical returned frames for an edited pair and for an
// independently constructed pair whose incoming rack was present from frame zero.
static void effectsBeforeAdmission(LLSongPair *pair, std::vector<float> &output, bool shortened) {
    const uint32_t start = shortened ? 6100 : oldOutro - 4000;
    append(pair, output, start - uint32_t(output.size() / 2), {137, 257});
    CHECK(ll_song_pair_send_effects(pair, {.8, 0, 0}, 80, 2));
    append(pair, output, 73, {1, 32});
    CHECK(ll_song_pair_send_effects(pair, {.05, 1, 0}, 5, 3));
    append(pair, output, 64, {64});
    const auto progress = ll_song_pair_effect_progress(pair);
    CHECK(progress.adopted_revision == 3 && progress.settled_revision == 1);
}
static std::vector<float> effectsOracle(LLTonalCalibration *table, bool shortened, bool edit) {
    auto events = score();
    auto extra = std::vector<float>{};
    if (shortened) {
        events.resize(5);
        auto future = futureEvents();
        future[0].sample_index = 2;
        events.insert(events.end(), future.begin(), future.end());
        extra = newPCM();
    }
    // Inject the expected ramp directly into each borrowed replay. The oracle bypasses
    // pair effects publication and rack adoption, so skipping B in either path is visible.
    lowlight::EffectTimeline timeline;
    timeline.seed(lowlight::designEffects({.75, .5, 0}, 75, 1).shape);
    Song first(100000, events, shortened, 0, 1600, extra, table), second(900000, table);
    ll_song_replay_use_effects(first.replay, &timeline, 0);
    ll_song_replay_use_effects(second.replay, &timeline, shortened ? boundary : oldOutro);
    Pair pair(first, second, shortened, 0);
    std::vector<float> expected;
    if (edit) {
        const uint32_t start = shortened ? 6100 : oldOutro - 4000;
        constexpr uint32_t lead = LL_GLUE_LATENCY + 2 * LL_PEAK_LATENCY;
        append(pair.value, expected, start, {509});
        timeline.retarget(start + lead, lowlight::designEffects({.8, 0, 0}, 80, 2).shape);
        append(pair.value, expected, 73, {73});
        timeline.retarget(start + 73 + lead, lowlight::designEffects({.05, 1, 0}, 5, 3).shape);
    }
    const auto end = oldFrames - (shortened ? delta : 0) + 2000;
    append(pair.value, expected, end - uint32_t(expected.size() / 2), {509});
    return expected;
}
static std::vector<float> effectsAcrossOrdinaryAdmission(LLTonalCalibration *table, bool oracle) {
    constexpr uint32_t onset = 50000, edit = onset - 4000;
    constexpr uint32_t lead = LL_GLUE_LATENCY + 2 * LL_PEAK_LATENCY;
    lowlight::EffectTimeline timeline;
    timeline.seed(lowlight::designEffects({.75, .5, 0}, 75, 1).shape);
    auto first = std::make_unique<Song>(100000, table);
    Song second(900000, table);
    std::unique_ptr<Song> third;
    Pair pair(*first, second, false, 0);
    if (oracle) {
        ll_song_replay_use_effects(first->replay, &timeline, 0);
        ll_song_replay_use_effects(second.replay, &timeline, oldOutro);
    } else {
        CHECK(ll_song_pair_seed_effects(pair.value, {.75, .5, 0}, 75));
    }
    std::vector<float> output;
    append(pair.value, output, oldFrames + 32, {193});
    LLSongReplay *retired = nullptr;
    CHECK(ll_song_pair_claim_retired(pair.value, &retired) && retired == first->replay);
    first.reset();
    auto publish = [&] {
        third = std::make_unique<Song>(1900000, table);
        if (oracle)
            ll_song_replay_use_effects(third->replay, &timeline, onset);
        CHECK(ll_song_pair_publish_transport(pair.value, third->replay, onset, 76000));
    };
    if (oracle)
        publish();
    append(pair.value, output, edit - uint32_t(output.size() / 2), {431});
    if (oracle)
        timeline.retarget(edit + lead, lowlight::designEffects({.05, 1, 0}, 5, 2).shape);
    else
        CHECK(ll_song_pair_send_effects(pair.value, {.05, 1, 0}, 5, 2));
    append(pair.value, output, 128, {128});
    if (!oracle) {
        CHECK(ll_song_pair_effect_progress(pair.value).adopted_revision == 2);
        {
            Song incompatible(1900000);
            CHECK(!ll_song_pair_publish_transport(pair.value, incompatible.replay, onset, 76000));
        }
        publish(); // The worker publishes C after the new effects have already been adopted.
    }
    append(pair.value, output, onset + 512 - uint32_t(output.size() / 2), {811});
    if (!oracle)
        CHECK(ll_song_pair_effect_progress(pair.value).settled_revision == 1);
    append(pair.value, output, oldOutro + oldFrames + 2000 - uint32_t(output.size() / 2), {97});
    return output;
}
static void effectsAcrossReplacementAndRestoration() {
    std::array<float, 10100> gains{};
    gains.fill(1);
    std::unique_ptr<LLTonalCalibration, decltype(&ll_tonal_calibration_destroy)> table(
        ll_tonal_calibration_create(gains.data(), gains.size()), ll_tonal_calibration_destroy);
    CHECK(table.get());
    for (bool shortened : {true, false}) {
        const auto expected = effectsOracle(table.get(), shortened, true);
        const auto unchanged = effectsOracle(table.get(), shortened, false);
        ChangeFixture fixture(table.get());
        // A complete legacy bridge can pass score validation. Reject its uncalibrated
        // guitar while the original successor is still owned and playable.
        auto *incompatibleBridge = prepare(fixture, false);
        CHECK(!ll_song_pair_withdraw_change(fixture.pair, incompatibleBridge));
        CHECK(ll_song_pair_abandon_change(fixture.pair));
        ll_song_change_destroy(incompatibleBridge);
        fixture.request();
        fixture.change = prepare(fixture);
        fixture.withdraw();
        effectsBeforeAdmission(fixture.pair, fixture.output, shortened);
        {
            Song incompatible(900000);
            const bool admitted =
                shortened ? ll_song_pair_publish_change(fixture.pair, fixture.change,
                                                        incompatible.replay, 50000 - delta)
                          : ll_song_pair_restore_change(fixture.pair, incompatible.replay);
            CHECK(!admitted);
        }
        if (shortened) {
            fixture.second.reset(new Song(900000, table.get()));
            CHECK(ll_song_pair_publish_change(fixture.pair, fixture.change, fixture.second->replay,
                                              50000 - delta));
            append(fixture.pair, fixture.output, 1, {1});
            LLSongChangeResult result{};
            CHECK(ll_song_pair_change_result(fixture.pair, &result) && result.status == 1);
        } else {
            fixture.rollback();
        }
        const auto onset = shortened ? boundary : oldOutro;
        append(fixture.pair, fixture.output, onset + 512 - uint32_t(fixture.output.size() / 2),
               {256, 79});
        // B starts inside revision 3's ramp, even though it was absent for both sends.
        CHECK(ll_song_pair_effect_progress(fixture.pair).settled_revision == 1);
        append(fixture.pair, fixture.output, uint32_t(expected.size() - fixture.output.size()) / 2,
               {811, 1});
        CHECK(ll_song_pair_effect_progress(fixture.pair).settled_revision == 3);
        CHECK(same(expected, fixture.output));
        // The application of effects to the incoming rack is audible after A fully retires.
        CHECK(!std::equal(expected.end() - 2000, expected.end(), unchanged.end() - 2000));
    }
    CHECK(same(effectsAcrossOrdinaryAdmission(table.get(), true),
               effectsAcrossOrdinaryAdmission(table.get(), false)));
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
    effectsAcrossReplacementAndRestoration();
    revisionAndRollback();
    lateAndWaiting();
    capacityAndValidation();
    invalidScoresAndSamples();
    invalidFadesPreservePrefix();
    concurrentPreparation();
    std::puts("Song Controls bounded replacement tests passed");
}
