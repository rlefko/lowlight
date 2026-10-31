// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
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

static bool auditing = false;
static unsigned allocations = 0, deallocations = 0;
void *operator new(std::size_t bytes) {
    if (auditing) ++allocations;
    void *pointer = std::malloc(bytes ? bytes : 1);
    if (!pointer) std::abort();
    return pointer;
}
void *operator new[](std::size_t bytes) { return ::operator new(bytes); }
void *operator new(std::size_t bytes, const std::nothrow_t &) noexcept { return ::operator new(bytes); }
void *operator new[](std::size_t bytes, const std::nothrow_t &) noexcept { return ::operator new(bytes); }
void operator delete(void *pointer) noexcept { if (auditing) ++deallocations; std::free(pointer); }
void operator delete[](void *pointer) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }

static void require(bool condition, int line) {
    if (!condition) { std::fprintf(stderr, "Voice mixer assertion failed at line %d\n", line); std::abort(); }
}
#define CHECK(condition) require((condition), __LINE__)
static bool near(float actual, double expected) { return std::abs(actual - expected) <= 1e-6; }
static uint64_t floatingControl() {
#if defined(__aarch64__) || defined(__arm64__)
    uint64_t value; __asm__ volatile("mrs %0, fpcr" : "=r"(value)); return value;
#elif defined(__x86_64__)
    return _mm_getcsr();
#else
    return 0;
#endif
}
struct Mixer {
    LLMixer *value = ll_mixer_create();
    Mixer() { CHECK(value); }
    ~Mixer() { ll_mixer_destroy(value); }
    Mixer(const Mixer &) = delete;
    Mixer &operator=(const Mixer &) = delete;
    int sample(float amplitude, uint32_t frames = 4096, uint32_t channels = 1) {
        std::vector<float> pcm(frames * channels, amplitude);
        return ll_mixer_add_sample(value, pcm.data(), frames, channels);
    }
    void load(const std::vector<LLEvent> &events) {
        CHECK(ll_mixer_load_events(value, events.data(), static_cast<uint32_t>(events.size())));
    }
    std::vector<float> render(uint32_t frames, const std::vector<uint32_t> &blocks = {256}) {
        std::vector<float> output(2 * frames, std::numeric_limits<float>::quiet_NaN());
        uint32_t offset = 0;
        std::size_t block = 0;
        while (offset < frames) {
            const uint32_t count = std::min(frames - offset, blocks[block++ % blocks.size()]);
            const auto control = floatingControl();
            auditing = true;
            const bool result = ll_mixer_render(value, output.data() + 2 * offset, count);
            auditing = false;
            CHECK(floatingControl() == control);
            CHECK(result && allocations == 0 && deallocations == 0);
            CHECK(ll_mixer_active_voices(value) <= LL_VOICE_LIMIT);
            offset += count;
        }
        CHECK(std::all_of(output.begin(), output.end(), [](float value) { return std::isfinite(value); }));
        return output;
    }
    void reset() {
        auditing = true;
        ll_mixer_reset(value);
        auditing = false;
        CHECK(allocations == 0 && deallocations == 0);
    }
};
static LLEvent event(uint32_t sample = 0, uint64_t start = 0, uint32_t hold = 1000, uint32_t release = 800) {
    LLEvent value{};
    value.sample_index = sample; value.start_frame = start;
    value.hold_frames = hold; value.release_frames = release; value.velocity = 1;
    return value;
}

static void timingAndPartitioning() {
    Mixer mixer;
    CHECK(mixer.sample(0.2f) == 0);
    auto delayed = event(0, 17);
    auto second = event(0, 513, 400, 100); second.pan = 0.3f; second.connected = 1;
    mixer.load({delayed, second});
    const auto whole = mixer.render(4097, {4097});
    CHECK(ll_mixer_position(mixer.value) == 4097 && ll_mixer_active_voices(mixer.value) == 0);
    CHECK(std::all_of(whole.begin(), whole.begin() + 36, [](float sample) { return sample == 0; }));
    CHECK(std::all_of(whole.begin() + 2 * 1817, whole.end(), [](float sample) { return sample == 0; }));
    mixer.reset();
    CHECK(ll_mixer_position(mixer.value) == 0);
    CHECK(whole == mixer.render(4097, {1, 17, 255, 256, 257, 503}));
    mixer.load({});
    const auto silent = mixer.render(515);
    CHECK(std::all_of(silent.begin(), silent.end(), [](float sample) { return sample == 0; }));
    float unchanged[] = {7, 7};
    CHECK(ll_mixer_render(mixer.value, unchanged, 0) && unchanged[0] == 7 && unchanged[1] == 7);
    CHECK(!ll_mixer_render(mixer.value, nullptr, 1));
    CHECK(!ll_mixer_render(nullptr, unchanged, 1) && unchanged[0] == 0 && unchanged[1] == 0);
}

static void envelopesAndStereo() {
    Mixer mixer; CHECK(mixer.sample(0.2f) == 0);
    auto note = event(); mixer.load({note});
    const auto normal = mixer.render(1801);
    CHECK(normal[0] == 0 && near(normal[2 * 447], 0.047));
    CHECK(near(normal[2 * 1000], 0.047) && std::abs(normal[2 * 1799]) < 1e-12);
    CHECK(normal[3600] == 0);
    for (std::size_t index = 0; index < normal.size(); index += 2) CHECK(normal[index] == normal[index + 1]);
    note.connected = 1; mixer.load({note}); const auto connected = mixer.render(1801);
    CHECK(near(connected[1000], normal[1000] * 0.9));
    note.connected = 0; note.pan = -1; mixer.load({note}); const auto left = mixer.render(600);
    CHECK(near(left[1000], 0.047 * std::sqrt(2.0)) && left[1001] == 0);
    note.pan = 1; mixer.load({note}); const auto right = mixer.render(600);
    CHECK(std::abs(right[1000]) < 1e-8 && near(right[1001], 0.047 * std::sqrt(2.0)));
    note = event(0, 0, 1, 0); mixer.load({note}); CHECK(mixer.render(2) == std::vector<float>(4, 0));
    note = event(0, 0, 800, 1); mixer.load({note});
    const auto singleRelease = mixer.render(802);
    CHECK(near(singleRelease[1600], 0.047) && singleRelease[1602] == 0);
    Mixer truncated; CHECK(truncated.sample(0.2f, 850) == 0);
    truncated.load({event(0, 0, 800, 200)}); const auto tail = truncated.render(851);
    const double phase = 25.0 / 49 * std::acos(-1.0) / 2;
    CHECK(near(tail[2 * 825], 0.047 * std::cos(phase) * std::cos(phase)) && tail[1700] == 0);
    Mixer stereo; std::vector<float> pcm(4096 * 2);
    for (std::size_t index = 0; index < pcm.size(); index += 2) { pcm[index] = 0.2f; pcm[index + 1] = 0.1f; }
    CHECK(ll_mixer_add_sample(stereo.value, pcm.data(), 4096, 2) == 0);
    note = event(); note.instrument = 1; stereo.load({note}); const auto piano = stereo.render(600);
    CHECK(near(piano[1000], 0.1875 * 0.23) && near(piano[1001], 0.1125 * 0.23));
}

static void stealing() {
    Mixer mixer; CHECK(mixer.sample(0.1f) == 0); CHECK(mixer.sample(0.2f) == 1); CHECK(mixer.sample(0.8f) == 2);
    std::vector<LLEvent> score(64, event(0, 0, 4000, 0));
    auto silent = event(0, 100); silent.velocity = 0;
    score.insert(score.end(), 64, silent); // Silent arrivals consume no voice or pending slot.
    auto incoming = event(1, 100, 3000, 0); incoming.priority = 2;
    score.insert(score.end(), 64, incoming);
    incoming.sample_index = 2; score.push_back(incoming); // Every slot already has a pending note.
    incoming.start_frame = 120; incoming.priority = 0; score.push_back(incoming);
    incoming.start_frame = 500; score.push_back(incoming); // Melody voices are protected after the fade too.
    mixer.load(score); const auto first = mixer.render(1000, {1});
    CHECK(ll_mixer_steals(mixer.value) == 64 && ll_mixer_dropped_events(mixer.value) == 3);
    CHECK(ll_mixer_active_voices(mixer.value) == 64);
    CHECK(std::abs(first[2 * 259]) < 1e-8 && first[2 * 260] == 0); // Fade ends, then the pending attack begins.
    CHECK(near(first[2 * 900], 64 * 0.047));
    mixer.reset(); CHECK(ll_mixer_steals(mixer.value) == 0 && ll_mixer_dropped_events(mixer.value) == 0);
    CHECK(first == mixer.render(1000, {257, 511, 19}));
    Mixer release; CHECK(release.sample(0.2f) == 0); CHECK(release.sample(0.4f) == 1); CHECK(release.sample(0) == 2);
    score.assign(64, event(2, 0, 3000, 0));
    for (auto &value : score) value.priority = 2;
    score[0] = event(0, 0, 2000, 0); score[1] = event(1, 0, 100, 1000);
    score.push_back(event(2, 500, 2000, 0));
    release.load(score); const auto preferred = release.render(1200);
    CHECK(ll_mixer_steals(release.value) == 1 && near(preferred[2 * 1000], 0.047));
    // Equal priorities/releases choose the oldest voice, then stable slot order.
    for (const uint64_t laterStart : {uint64_t{0}, uint64_t{20}}) {
        score.assign(63, event(2, 0, 3000, 0));
        for (auto &value : score) value.priority = 2;
        score[0] = event(0, 0, 3000, 0);
        score.push_back(event(1, laterStart, 3000, 0));
        score.push_back(event(2, 1000, 2000, 0));
        release.load(score); const auto oldest = release.render(1700);
        CHECK(ll_mixer_steals(release.value) == 1 && near(oldest[2 * 1600], 0.094));
    }
}

static LLEvent bass(uint64_t start = 0, uint32_t hold = 900, uint32_t release = 300) {
    auto note = event(0, start, hold, release);
    note.instrument = 2; note.midi = 40; note.priority = 2;
    return note;
}
static float bassReference(uint32_t age, const LLEvent &note, float touch = 0) {
    if (age >= note.hold_frames + note.release_frames) return 0;
    const double t = age / 32000.0, phase = 2 * std::acos(-1.0) * 440 * std::pow(2.0, (note.midi - 69) / 12.0) * t;
    const double tone = .21 * std::sin(phase) + .105 * std::sin(2 * phase) + .037 * std::sin(3 * phase);
    double value = (tone * (1 - std::exp(-t / .016)) * std::exp(-t / 2.6) + touch) * .24 * std::pow(note.velocity, 1.10);
    if (age >= note.hold_frames && note.release_frames > 1)
        value *= std::pow(std::cos(std::acos(-1.0) / 2 * (age - note.hold_frames) / (note.release_frames - 1)), 2);
    return static_cast<float>(value) * 0.99999994f;
}
static void bassSoundAndBounds() {
    Mixer mixer; CHECK(mixer.sample(.125f, 8) == 0); CHECK(mixer.sample(.125f, 8, 2) == 1);
    auto note = bass(); std::vector<float> expected;
    for (const uint8_t midi : {31, 40, 57}) {
        note.midi = midi; mixer.load({note}); expected = mixer.render(1201);
        for (uint32_t frame = 0; frame < 1201; ++frame) {
            CHECK(near(expected[2 * frame], bassReference(frame, note, frame < 8 ? .125f : 0)));
            CHECK(expected[2 * frame] == expected[2 * frame + 1]);
        }
        CHECK(expected[0] > 0 && expected[2 * 500] != 0 && expected[2400] == 0);
        CHECK(ll_mixer_active_voices(mixer.value) == 0);
        mixer.reset(); CHECK(expected == mixer.render(1201, {1, 17, 255, 256, 513}));
    }
    note.pan = 1; note.connected = 1; mixer.load({note}); CHECK(expected == mixer.render(1201));
    note.velocity = .5f; mixer.load({note}); const auto quiet = mixer.render(1201);
    CHECK(near(quiet[1000], expected[1000] * std::pow(.5, 1.10)));
    note.velocity = 0; mixer.load({note}); CHECK(mixer.render(1201) == std::vector<float>(2402, 0));
    CHECK(ll_mixer_active_voices(mixer.value) == 0);
    for (const uint32_t release : {0u, 1u, 2u}) {
        note = bass(0, 1, release); mixer.load({note}); const auto tiny = mixer.render(4);
        for (uint32_t frame = 0; frame < 4; ++frame) CHECK(near(tiny[2 * frame], bassReference(frame, note, .125f)));
        CHECK(ll_mixer_active_voices(mixer.value) == 0);
    }
    note = bass(0, 512000, 160000); mixer.load({note}); expected = mixer.render(672001, {1023});
    CHECK(near(expected[2 * 512000], bassReference(512000, note)) && expected[2 * 672000] == 0);
    CHECK(ll_mixer_active_voices(mixer.value) == 0);
    auto boundary = note; boundary.start_frame = (uint64_t{1} << 52) - 672000; mixer.load({boundary});
    ++boundary.start_frame; CHECK(!ll_mixer_load_events(mixer.value, &boundary, 1));
    mixer.load({note}); mixer.render(123);
    std::vector<LLEvent> invalid;
    auto bad = note; bad.midi = 30; invalid.push_back(bad);
    bad = note; bad.midi = 58; invalid.push_back(bad);
    bad = note; bad.sample_index = 1; invalid.push_back(bad);
    bad = note; bad.hold_frames = 512001; invalid.push_back(bad);
    bad = note; bad.release_frames = 160001; invalid.push_back(bad);
    for (const auto &value : invalid) CHECK(!ll_mixer_load_events(mixer.value, &value, 1));
    CHECK(ll_mixer_position(mixer.value) == 123);
    CHECK(std::vector<float>(expected.begin() + 246, expected.begin() + 2048) == mixer.render(901));
}
static void bassReservationAndOverlap() {
    Mixer mixer; CHECK(mixer.sample(.125f, 8) == 0); CHECK(mixer.sample(0, 4096) == 1);
    auto first = bass(), second = bass(100), rejected = bass(101);
    second.midi = 47; rejected.midi = 54; rejected.velocity = .5f;
    mixer.load({first, second, rejected}); const auto overlap = mixer.render(500, {1});
    CHECK(ll_mixer_active_voices(mixer.value) == 1 && ll_mixer_steals(mixer.value) == 1);
    CHECK(ll_mixer_dropped_events(mixer.value) == 1);
    CHECK(near(overlap[2 * 200], bassReference(200, first) * 59.0 / 159));
    CHECK(overlap[2 * 259] == 0 && near(overlap[2 * 260], bassReference(0, second, .125f)));
    CHECK(near(overlap[2 * 400], bassReference(140, second)));
    mixer.reset(); CHECK(overlap == mixer.render(500, {257, 1, 17}));
    CHECK(ll_mixer_steals(mixer.value) == 1 && ll_mixer_dropped_events(mixer.value) == 1);
    auto tone = event(1, 0, 3000, 0); tone.priority = 2;
    std::vector<LLEvent> mixed(63, tone); first = bass(0, 3000, 0); mixed.push_back(first);
    tone.start_frame = 100; mixed.insert(mixed.end(), 63, tone);
    tone.start_frame = 101; mixed.push_back(tone);
    mixer.load(mixed); const auto saturated = mixer.render(700, {1});
    CHECK(ll_mixer_active_voices(mixer.value) == 64 && ll_mixer_steals(mixer.value) == 63);
    CHECK(ll_mixer_dropped_events(mixer.value) == 1);
    for (uint32_t frame = 0; frame < 700; ++frame)
        CHECK(near(saturated[2 * frame], bassReference(frame, first, frame < 8 ? .125f : 0)));
    mixer.reset(); CHECK(saturated == mixer.render(700, {700}));
    tone.start_frame = 0; mixed.assign(64, tone); first.velocity = 0; mixed.push_back(first);
    mixer.load(mixed); mixer.render(500); // Even a silent bass score reserves its one slot.
    CHECK(ll_mixer_active_voices(mixer.value) == 63 && ll_mixer_steals(mixer.value) == 1);
    tone.start_frame = 700; mixed.assign(64, tone); mixer.load(mixed); mixer.render(500);
    auto invalid = bass(); invalid.midi = 58;
    CHECK(!ll_mixer_load_events(mixer.value, &invalid, 1));
    CHECK(ll_mixer_position(mixer.value) == 500); mixer.render(300);
    CHECK(ll_mixer_active_voices(mixer.value) == 64 && ll_mixer_steals(mixer.value) == 0);
}

static LLEvent percussion(uint8_t instrument = 3, uint32_t sample = 0, uint64_t start = 0) {
    auto note = event(sample, start, 1, 0);
    note.instrument = instrument; note.midi = instrument == 4 ? 1 : 0;
    return note;
}
static float panFactor(float pan, bool right = false) {
    const double phase = (pan + 1.0) * std::acos(-1.0) / 4;
    return static_cast<float>(right ? std::sin(phase) : std::cos(phase)) * static_cast<float>(std::sqrt(2.0));
}
static void percussionSoundAndBounds() {
    Mixer mixer; CHECK(mixer.sample(.1375f, 997) == 0); CHECK(mixer.sample(.1375f, 997, 2) == 1);
    constexpr double gains[] = {.31, .25, .27, .11};
    for (uint8_t instrument = 3; instrument <= 6; ++instrument) {
        auto note = percussion(instrument); note.pan = .31f; note.velocity = .61f;
        const float gain = static_cast<float>(gains[instrument - 3] * std::pow(double(note.velocity), 1.25));
        mixer.load({note}); const auto expected = mixer.render(998, {998});
        for (uint32_t frame = 0; frame < 997; ++frame) { // No attack, gate truncation, or extra decay.
            CHECK(expected[2 * frame] == (.1375f * panFactor(note.pan)) * gain);
            CHECK(expected[2 * frame + 1] == (.1375f * panFactor(note.pan, true)) * gain);
        }
        CHECK(expected[1994] == 0 && expected[1995] == 0 && ll_mixer_active_voices(mixer.value) == 0);
        mixer.reset(); CHECK(expected == mixer.render(998, {1, 17, 255, 257}));
        note.hold_frames = 100; note.release_frames = 800; note.connected = 1;
        mixer.load({note}); CHECK(expected == mixer.render(998));
        for (const float pan : {-1.f, 0.f, 1.f}) {
            auto panned = note; panned.pan = pan; mixer.load({panned}); const auto output = mixer.render(1);
            CHECK(output[0] == (.1375f * panFactor(pan)) * gain);
            CHECK(output[1] == (.1375f * panFactor(pan, true)) * gain);
        }
        auto silent = note; silent.velocity = 0; mixer.load({silent});
        CHECK(mixer.render(998) == std::vector<float>(1996, 0) && ll_mixer_active_voices(mixer.value) == 0);
        mixer.load({note}); mixer.render(37);
        auto bad = note; bad.sample_index = 1; CHECK(!ll_mixer_load_events(mixer.value, &bad, 1));
        bad = note; bad.midi = instrument == 4 ? 0 : 1; CHECK(!ll_mixer_load_events(mixer.value, &bad, 1));
        for (const uint8_t priority : {1, 2}) {
            bad = note; bad.priority = priority; CHECK(!ll_mixer_load_events(mixer.value, &bad, 1));
        }
        CHECK(ll_mixer_position(mixer.value) == 37);
        CHECK(std::vector<float>(expected.begin() + 74, expected.end()) == mixer.render(961));
        auto boundary = note; boundary.start_frame = (uint64_t{1} << 52) - 997; mixer.load({boundary});
        ++boundary.start_frame; CHECK(!ll_mixer_load_events(mixer.value, &boundary, 1));
    }
}
static void percussionStealingAndProtection() {
    Mixer mixer; CHECK(mixer.sample(.125f, 8) == 0); CHECK(mixer.sample(0, 4096) == 1);
    CHECK(mixer.sample(.2f, 4096) == 2); CHECK(mixer.sample(.4f, 4096) == 3);
    auto tone = event(1, 0, 3000, 0); tone.priority = 2;
    std::vector<LLEvent> score(63, tone); const auto low = bass(0, 3000, 0); score.push_back(low);
    score.push_back(percussion(3, 2, 100));
    mixer.load(score); const auto protectedOutput = mixer.render(700, {1});
    CHECK(ll_mixer_active_voices(mixer.value) == 64 && ll_mixer_steals(mixer.value) == 0);
    CHECK(ll_mixer_dropped_events(mixer.value) == 1);
    for (uint32_t frame = 0; frame < 700; ++frame)
        CHECK(near(protectedOutput[2 * frame], bassReference(frame, low, frame < 8 ? .125f : 0)));
    score[0].priority = 0; score.push_back(percussion(6, 3, 101));
    mixer.load(score); const auto mixed = mixer.render(700, {1});
    CHECK(ll_mixer_active_voices(mixer.value) == 64 && ll_mixer_steals(mixer.value) == 1);
    CHECK(ll_mixer_dropped_events(mixer.value) == 1);
    CHECK(near(mixed[2 * 500], (.2f * panFactor(0)) * .31f + bassReference(500, low)));
    mixer.reset(); CHECK(mixed == mixer.render(700, {257, 19, 512}));
    score.assign(63, tone); score.push_back(percussion(3, 2)); // All 64 slots remain available without bass.
    score.push_back(percussion(6, 3, 100)); score.push_back(percussion(3, 2, 101));
    mixer.load(score); const auto fade = mixer.render(500, {1});
    CHECK(ll_mixer_active_voices(mixer.value) == 64 && ll_mixer_steals(mixer.value) == 1);
    CHECK(ll_mixer_dropped_events(mixer.value) == 1);
    CHECK(near(fade[400], (.2f * panFactor(0)) * .31f * 59.0 / 159));
    CHECK(fade[518] == 0 && near(fade[520], (.4f * panFactor(0)) * .11f));
    score.assign(63, tone); score[0] = percussion(3, 2); score[0].hold_frames = 3000;
    score.push_back(event(1, 20, 100, 3000)); score.push_back(percussion(6, 1, 500));
    mixer.load(score); const auto longGate = mixer.render(1000);
    CHECK(longGate[1800] == 0 && ll_mixer_steals(mixer.value) == 1);
    score[0].hold_frames = 1; mixer.load(score); CHECK(longGate == mixer.render(1000));
}

static void invalidInputsAndOwnership() {
    Mixer mixer; const float nan = std::numeric_limits<float>::quiet_NaN(), excessive = 9;
    CHECK(ll_mixer_add_sample(mixer.value, nullptr, 1, 1) == -1);
    CHECK(ll_mixer_add_sample(mixer.value, &nan, 1, 1) == -1);
    CHECK(ll_mixer_add_sample(mixer.value, &excessive, 1, 1) == -1);
    CHECK(ll_mixer_add_sample(mixer.value, &excessive, 0, 1) == -1);
    CHECK(ll_mixer_add_sample(mixer.value, &excessive, 215514, 1) == -1);
    CHECK(ll_mixer_add_sample(mixer.value, &excessive, 1, 3) == -1);
    CHECK(mixer.sample(0.2f) == 0); auto note = event(); mixer.load({note});
    CHECK(ll_mixer_add_sample(mixer.value, &excessive, 1, 1) == -1);
    const auto expected = mixer.render(1800); mixer.reset();
    const auto prefix = mixer.render(123);
    CHECK(std::equal(prefix.begin(), prefix.end(), expected.begin()));
    std::vector<LLEvent> invalid;
    auto bad = note; bad.sample_index = 1; invalid.push_back(bad);
    bad = note; bad.start_frame = uint64_t(1) << 52; invalid.push_back(bad);
    bad = note; bad.hold_frames = 0; invalid.push_back(bad);
    bad = note; bad.hold_frames = 512001; invalid.push_back(bad);
    bad = note; bad.release_frames = 160001; invalid.push_back(bad);
    bad = note; bad.velocity = nan; invalid.push_back(bad);
    bad = note; bad.velocity = 1.1f; invalid.push_back(bad);
    bad = note; bad.pan = 1.1f; invalid.push_back(bad);
    bad = note; bad.pan = nan; invalid.push_back(bad);
    bad = note; bad.instrument = 7; invalid.push_back(bad);
    bad = note; bad.connected = 2; invalid.push_back(bad);
    bad = note; bad.priority = 3; invalid.push_back(bad);
    for (const auto &value : invalid) CHECK(!ll_mixer_load_events(mixer.value, &value, 1));
    CHECK(!ll_mixer_load_events(mixer.value, nullptr, 1));
    CHECK(!ll_mixer_load_events(mixer.value, &note, 2049));
    const LLEvent unsorted[] = {event(0, 10), event(0, 9)};
    CHECK(!ll_mixer_load_events(mixer.value, unsorted, 2));
    CHECK(ll_mixer_position(mixer.value) == 123);
    CHECK(std::vector<float>(expected.begin() + 246, expected.end()) == mixer.render(1677));
    Mixer capacity;
    for (int index = 0; index < 64; ++index) CHECK(capacity.sample(0.1f, 1) == index);
    CHECK(capacity.sample(0.1f, 1) == -1);
    Mixer bytes; std::vector<float> large(215513 * 2, 0.1f); uint32_t accepted = 0;
    while (ll_mixer_add_sample(bytes.value, large.data(), 215513, 2) >= 0) ++accepted;
    CHECK(accepted > 0 && accepted < 64 && ll_mixer_sample_bytes(bytes.value) == accepted * large.size() * sizeof(float));
    CHECK(ll_mixer_sample_bytes(bytes.value) <= LL_SAMPLE_BYTES);
}

int main() {
    timingAndPartitioning(); envelopesAndStereo(); stealing(); bassSoundAndBounds(); bassReservationAndOverlap();
    percussionSoundAndBounds(); percussionStealingAndProtection(); invalidInputsAndOwnership();
    std::puts("Voice mixer timing, instrument gains/envelopes, stealing, bounds, and allocation audit passed");
}
