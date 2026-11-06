// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include "../../Packages/LowlightAudio/Sources/CLowlightDSP/FloatingPointMode.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cmath>
#include <limits>
#include <thread>
#include <vector>

namespace {
constexpr uint32_t rackLength = 22000, secondOnset = 12000, nextOnset = 26000;
constexpr LLEffectValues initial{.78, .44, 0};
constexpr LLEffectValues changed{.05, 1, 1};
struct Calibration {
    LLTonalCalibration *value;
    Calibration() {
        std::array<float, 10100> gains{};
        gains.fill(1);
        value = ll_tonal_calibration_create(gains.data(), gains.size());
        assert(value);
    }
    ~Calibration() {
        ll_tonal_calibration_destroy(value);
    }
};
struct Rack {
    LLMixer *mixer = ll_mixer_create();
    LLSongSource *source;
    LLSongReplay *replay;
    Rack(LLTonalCalibration *table, uint64_t origin, unsigned seed, bool baked = false) {
        LLSongSourceConfig config{origin,
                                  rackLength,
                                  seed,
                                  0,
                                  initial.space,
                                  initial.warmth,
                                  initial.texture,
                                  {0, 0, double(origin + rackLength - 100),
                                   double(origin + rackLength), double(origin),
                                   double(origin + rackLength)}};
        assert(mixer && ll_mixer_configure_origin(mixer, origin));
        assert(ll_mixer_configure_buses(mixer, .4));
        assert(ll_mixer_configure_fades(mixer, &config.rack_fades));
        assert(ll_mixer_configure_tonal(mixer, table, 78));
        std::vector<float> pcm(rackLength);
        for (unsigned i = 0; i < pcm.size(); ++i)
            pcm[i] = float(.2 * std::sin(.18 * i) + .15 * std::sin(.31 * i));
        if (baked)
            assert(ll_mixer_add_sample(mixer, pcm.data(), rackLength, 1) == 0);
        else
            assert(ll_mixer_add_tonal_sample(mixer, pcm.data(), rackLength, 1, 40) == 0);
        const LLEvent event{origin, 0, 19000, 800, .8f, .2f, 0, 0, 1, 60};
        assert(ll_mixer_load_events(mixer, &event, 1));
        source = ll_song_source_create(mixer, &config);
        replay = ll_song_replay_create(source, -20.5);
        assert(source && replay);
    }
    ~Rack() {
        ll_song_replay_destroy(replay);
        ll_song_source_destroy(source);
        ll_mixer_destroy(mixer);
    }
};
struct Session {
    Calibration calibration;
    Rack a{calibration.value, 90000, 11}, b{calibration.value, 200000, 32};
    LLSongPair *pair = ll_song_pair_create_transport(a.replay, b.replay, secondOnset, 0, nextOnset);
    std::vector<float> pcm;
    Session() {
        assert(pair);
    }
    ~Session() {
        ll_song_pair_destroy(pair);
    }
    void seed(LLEffectValues v) {
        assert(ll_song_pair_seed_effects(pair, v, uint32_t(std::round(v.warmth * 100))));
        assert(!ll_song_pair_seed_effects(pair, v, 78));
    }
    void send(LLEffectValues v, uint64_t revision) {
        assert(ll_song_pair_send_effects(pair, v, uint32_t(std::round(v.warmth * 100)), revision));
    }
    void renderTo(uint32_t end, uint32_t partition) {
        while (pcm.size() / 2 < end) {
            const auto start = pcm.size();
            const auto frames = std::min(partition, end - uint32_t(start / 2));
            pcm.resize(start + 2 * frames);
            uint32_t written = 0;
            assert(ll_song_pair_render(pair, pcm.data() + start, frames, &written) &&
                   written == frames);
        }
    }
};

std::vector<float> reversals(uint32_t partition) {
    Session s;
    s.seed(initial);
    {
        lowlight::FloatingPointMode flush;
        const double tiny = std::numeric_limits<double>::denorm_min();
        assert(!ll_song_pair_send_effects(s.pair, {initial.warmth, initial.space, tiny}, 78, 1));
        assert(ll_song_pair_send_effects(s.pair, {initial.warmth, initial.space, -0.0}, 78, 1));
    }
    assert(!ll_song_pair_send_effects(s.pair, {NAN, 0, .5}, 10, 2));
    assert(!ll_song_pair_send_effects(s.pair, {0, 0, 2}, 10, 2));
    assert(!ll_song_pair_send_effects(s.pair, initial, 101, 2));
    uint64_t revision = 1;
    for (uint32_t f : {1100u, 1101u, 1300u, 10000u, 10010u, 10120u, 14200u}) {
        s.renderTo(f, partition);
        const auto target = revision % 2 ? changed : initial;
        s.send(target, ++revision);
        s.send(target, revision);
        assert(!ll_song_pair_send_effects(s.pair, target, 0, revision - 1));
    }
    s.renderTo(24300, partition);
    const auto progress = ll_song_pair_effect_progress(s.pair);
    assert(progress.adopted_revision == revision && progress.settled_revision == revision);
    assert(progress.settled_values.texture == 1);
    for (auto v : s.pcm)
        assert(std::isfinite(v) && std::abs(v) < 1);
    return s.pcm;
}

void synchronizedStages() {
    assert(reversals(1) == reversals(883));
    Session reference, noEdit;
    reference.renderTo(24000, 531);
    noEdit.seed(initial);
    noEdit.renderTo(24000, 207);
    assert(reference.pcm == noEdit.pcm);

    for (const auto target :
         {LLEffectValues{.05, initial.space, 0}, LLEffectValues{initial.warmth, 1, 0},
          LLEffectValues{initial.warmth, initial.space, 1}}) {
        Session live, fixed;
        live.seed(initial);
        fixed.seed(target);
        live.renderTo(1800, 173);
        live.send(target, 2);
        // Prefix already admitted to the two lookaheads and centered detector is immutable.
        constexpr auto start = 1800 + 2 * LL_PEAK_LATENCY + LL_GLUE_LATENCY;
        live.renderTo(start + 1, 91);
        assert(live.pcm ==
               std::vector<float>(reference.pcm.begin(), reference.pcm.begin() + live.pcm.size()));
        live.renderTo(start + 6399, 61);
        assert(ll_song_pair_effect_progress(live.pair).settled_revision == 1);
        live.renderTo(start + 6400, 1);
        assert(ll_song_pair_effect_progress(live.pair).settled_revision == 2);
        live.renderTo(24000, 389);
        assert(live.pcm != reference.pcm);
        fixed.renderTo(24000, 107);
        // B starts after the ramp. Its active filters/room/air have identical histories
        // to a session initialized at that target, even after A has retired.
        assert(std::equal(live.pcm.begin() + 2 * rackLength, live.pcm.end(),
                          fixed.pcm.begin() + 2 * rackLength));
    }
}
void rejectBakedTonalRack() {
    Calibration calibration;
    Rack first(calibration.value, 0, 11), baked(calibration.value, 100000, 32, true);
    auto *pair =
        ll_song_pair_create_transport(first.replay, baked.replay, secondOnset, 0, nextOnset);
    assert(pair && !ll_song_pair_seed_effects(pair, initial, 78));
    assert(!ll_song_pair_send_effects(pair, changed, 5, 2));
    std::array<float, 16> stereo{};
    uint32_t written = 0;
    assert(ll_song_pair_render(pair, stereo.data(), 8, &written) && written == 8);
    ll_song_pair_destroy(pair);
}
void resetBorrowedRack() {
    Session session, reference;
    session.seed(initial);
    session.renderTo(1000, 71);
    session.send(changed, 2);
    session.renderTo(12000, 381);
    ll_song_pair_destroy(session.pair);
    session.pair = nullptr;
    ll_song_pair_destroy(reference.pair);
    reference.pair = nullptr;
    ll_song_replay_reset(session.a.replay);
    std::vector<float> a(2 * rackLength), b(a.size());
    uint32_t first = 0, second = 0;
    assert(ll_song_replay_render(session.a.replay, a.data(), rackLength, &first));
    assert(ll_song_replay_render(reference.a.replay, b.data(), rackLength, &second));
    assert(first == rackLength && second == first && a == b);
}

void concurrentPublication() {
    Session s;
    s.seed(initial);
    std::atomic<bool> go{false};
    std::thread producer([&] {
        while (!go.load(std::memory_order_acquire))
            std::this_thread::yield();
        for (unsigned r = 2; r <= 1500; ++r)
            s.send(r % 2 ? initial : changed, r);
    });
    go.store(true, std::memory_order_release);
    s.renderTo(10000, 31);
    producer.join();
    s.renderTo(20000, 79);
    const auto p = ll_song_pair_effect_progress(s.pair);
    assert(p.adopted_revision == 1500 && p.settled_revision == 1500 &&
           p.settled_values.warmth == changed.warmth);
}
}
int main() {
    synchronizedStages();
    rejectBakedTonalRack();
    resetBorrowedRack();
    concurrentPublication();
}
