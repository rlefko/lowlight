// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <type_traits>
#include <vector>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif
#pragma STDC FENV_ACCESS ON

static uint64_t allocations = 0, frees = 0;
void *operator new(std::size_t size) {
    void *result = std::malloc(size ? size : 1); if (!result) std::abort();
    ++allocations; return result;
}
void *operator new[](std::size_t size) { return ::operator new(size); }
void *operator new(std::size_t size, const std::nothrow_t &) noexcept { return ::operator new(size); }
void *operator new[](std::size_t size, const std::nothrow_t &) noexcept { return ::operator new(size); }
void operator delete(void *pointer) noexcept { if (pointer) ++frees; std::free(pointer); }
void operator delete[](void *pointer) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, std::size_t) noexcept { ::operator delete(pointer); }
void operator delete(void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
void operator delete[](void *pointer, const std::nothrow_t &) noexcept { ::operator delete(pointer); }
static void require(bool valid, int line) {
    if (!valid) { std::fprintf(stderr, "Floating-point assertion failed at line %d\n", line); std::abort(); }
}
#define CHECK(value) require((value), __LINE__)
struct State { uint64_t control, status; };
static State state() {
#if defined(__aarch64__)
    State value{};
    asm volatile("mrs %0, fpcr" : "=r"(value.control) : : "memory");
    asm volatile("mrs %0, fpsr" : "=r"(value.status) : : "memory"); return value;
#else
    return {_mm_getcsr(), 0};
#endif
}
static void install(State value) {
#if defined(__aarch64__)
    asm volatile("msr fpcr, %0" : : "r"(value.control) : "memory");
    asm volatile("msr fpsr, %0" : : "r"(value.status) : "memory");
#else
    _mm_setcsr(static_cast<unsigned>(value.control));
#endif
}
static State mode(State original, uint32_t rounding, uint32_t flush, bool flags) {
#if defined(__aarch64__)
    return {(original.control & ~((uint64_t{3} << 22) | (uint64_t{1} << 24))) |
            (uint64_t{rounding} << 22) | (uint64_t{flush} << 24), flags ? 0x11u : 0u};
#else
    return {(original.control & ~uint64_t{0xe07f}) | (uint64_t{rounding} << 13) |
            ((flush & 1) ? 0x40u : 0u) | ((flush & 2) ? 0x8000u : 0u) | (flags ? 0x21u : 0u), 0};
#endif
}
#if defined(__aarch64__)
constexpr uint32_t flushModes = 2;
#else
constexpr uint32_t flushModes = 4; // Exercise DAZ and FTZ independently as well as together.
#endif
struct Audit {
    State before = state(); uint64_t news = allocations, deletes = frees;
    void check(const char *operation, bool memory) const {
        const auto after = state();
        if (after.control != before.control || after.status != before.status)
            std::fprintf(stderr, "FP state changed in %s: control %llx/%llx status %llx/%llx\n", operation,
                static_cast<unsigned long long>(before.control), static_cast<unsigned long long>(after.control),
                static_cast<unsigned long long>(before.status), static_cast<unsigned long long>(after.status));
        CHECK(after.control == before.control && after.status == before.status);
        CHECK(!memory || (allocations == news && frees == deletes));
    }
};
template<class Function> static auto checked(Function function, const char *name, bool memory = true) {
    const Audit audit;
    if constexpr (std::is_void_v<decltype(function())>) { function(); audit.check(name, memory); }
    else { auto result = function(); audit.check(name, memory); return result; }
}
#define CALL(expression) checked([&] { return (expression); }, #expression)
#define SETUP(expression) checked([&] { return (expression); }, #expression, false)
template<class Float, class Bits> static Float fromBits(Bits bits) {
    static_assert(sizeof(Float) == sizeof(Bits)); Float result; std::memcpy(&result, &bits, sizeof(result)); return result;
}
constexpr uint32_t count = 12801;
constexpr uint64_t origin = 37;
static const LLRackFades fades{37.25, 938.5, 9037.25, 11037.75, 37, 11037.25};
static std::vector<float> source(uint32_t frames) {
    std::vector<float> result(2 * frames);
    for (uint32_t i = 0; i < frames; ++i) {
        result[2 * i] = float(int(i % 31) - 15) / 32;
        result[2 * i + 1] = float(int(i % 17) - 8) / 16;
    }
    return result;
}
struct Graph {
    LLMixer *mixer; LLGlue *glue; LLRoom *room; LLPeakProtector *peak;
    LLAir *air; LLSongMix *mix; LLLoudness *meter; LLSongGain *gain;
    Graph() {
        mixer = SETUP(ll_mixer_create()); CHECK(mixer);
        CHECK(CALL(ll_mixer_configure_origin(mixer, origin)));
        CHECK(CALL(ll_mixer_configure_buses(mixer, .3795510689640131)));
        CHECK(CALL(ll_mixer_configure_fades(mixer, &fades)));
        const auto pcm = source(count);
        CHECK(CALL(ll_mixer_add_sample(mixer, pcm.data(), count, 1)) == 0);
        CHECK(CALL(ll_mixer_add_sample(mixer, pcm.data(), count, 2)) == 1);
        std::array<LLEvent, 7> events{};
        for (uint8_t i = 0; i < events.size(); ++i) {
            auto &e = events[i]; e.start_frame = origin + i * 17; e.instrument = i;
            e.sample_index = i == 1; e.hold_frames = 7001; e.release_frames = 2001;
            e.velocity = .63875f; e.pan = -.1375f; e.connected = i == 1;
            e.priority = i < 3 ? 2 : 0; e.midi = i == 2 ? 43 : (i == 4 ? 1 : 0);
        }
        CHECK(CALL(ll_mixer_load_events(mixer, events.data(), events.size())));
        glue = SETUP(ll_glue_create(count, 1)); room = SETUP(ll_room_create(.44, .78));
        peak = SETUP(ll_peak_create(LL_PEAK_SONG));
        air = SETUP(ll_air_create(1278560406, count, origin, .09, &fades));
        mix = SETUP(ll_song_mix_create(1278560406, count, origin, .09, &fades));
        meter = SETUP(ll_loudness_create(count)); gain = SETUP(ll_song_gain_create(-30.318919941908316));
        CHECK(glue && room && peak && air && mix && meter && gain);
    }
    ~Graph() {
        SETUP(ll_mixer_destroy(mixer)); SETUP(ll_glue_destroy(glue)); SETUP(ll_room_destroy(room));
        SETUP(ll_peak_destroy(peak)); SETUP(ll_air_destroy(air)); SETUP(ll_song_mix_destroy(mix));
        SETUP(ll_loudness_destroy(meter)); SETUP(ll_song_gain_destroy(gain));
    }
    void reset() {
        CALL(ll_mixer_reset(mixer)); CALL(ll_glue_reset(glue)); CALL(ll_room_reset(room));
        CALL(ll_peak_reset(peak)); CALL(ll_air_reset(air)); CALL(ll_song_mix_reset(mix)); CALL(ll_loudness_reset(meter));
    }
    Graph(const Graph &) = delete; Graph &operator=(const Graph &) = delete;
};
struct Result {
    std::vector<unsigned char> audio; LLLoudnessResult meter{}; LLSongGainValues gain{};
    template<class Value> void append(const std::vector<Value> &values) {
        const auto *bytes = reinterpret_cast<const unsigned char *>(values.data());
        audio.insert(audio.end(), bytes, bytes + values.size() * sizeof(Value));
    }
    bool same(const Result &other) const {
        return audio == other.audio && std::memcmp(&gain, &other.gain, sizeof(gain)) == 0 &&
            std::memcmp(&meter.integrated_lufs, &other.meter.integrated_lufs, sizeof(double)) == 0 &&
            meter.total_blocks == other.meter.total_blocks && meter.absolute_blocks == other.meter.absolute_blocks &&
            meter.gated_blocks == other.meter.gated_blocks && meter.measurable == other.meter.measurable;
    }
};
template<class Function> static void chunks(uint32_t frames, bool irregular, Function function) {
    const uint32_t pattern[]{1, 17, 257, 1023}; uint32_t offset = 0, block = 0;
    while (offset < frames) {
        const uint32_t length = std::min(frames - offset, irregular ? pattern[block++ % 4] : frames);
        function(offset, length); offset += length;
    }
}
static Result render(Graph &graph, bool irregular) {
    std::vector<LLBusFrame> bus(count);
    std::vector<LLGlueFrame> delayed(count + LL_GLUE_LATENCY), wet(count);
    std::vector<float> dry(count * 2), stereo(count * 2), air(count * 2, .125f), gained(count * 2);
    std::vector<float> peak((count + LL_PEAK_LATENCY) * 2);
    chunks(count, irregular, [&](uint32_t offset, uint32_t n) { CHECK(CALL(ll_mixer_render(graph.mixer, dry.data() + 2 * offset, n))); });
    CALL(ll_mixer_reset(graph.mixer));
    chunks(count, irregular, [&](uint32_t offset, uint32_t n) { CHECK(CALL(ll_mixer_render_buses(graph.mixer, bus.data() + offset, n))); });
    chunks(count, irregular, [&](uint32_t offset, uint32_t n) {
        CHECK(CALL(ll_glue_process(graph.glue, bus.data() + offset, delayed.data() + offset, n)));
    });
    chunks(LL_GLUE_LATENCY, irregular, [&](uint32_t offset, uint32_t n) {
        uint32_t written = 0; CHECK(CALL(ll_glue_drain(graph.glue, delayed.data() + count + offset, n, &written)) && written == n);
    });
    chunks(count, irregular, [&](uint32_t offset, uint32_t n) {
        CHECK(CALL(ll_room_process(graph.room, delayed.data() + LL_GLUE_LATENCY + offset, wet.data() + offset, n)));
        CHECK(CALL(ll_song_mix_process(graph.mix, wet.data() + offset, stereo.data() + 2 * offset, n)));
        CHECK(CALL(ll_air_add(graph.air, air.data() + 2 * offset, n)));
        CHECK(CALL(ll_loudness_process(graph.meter, stereo.data() + 2 * offset, n)));
        CHECK(CALL(ll_song_gain_process(graph.gain, stereo.data() + 2 * offset, gained.data() + 2 * offset, n)));
        CHECK(CALL(ll_peak_process(graph.peak, gained.data() + 2 * offset, peak.data() + 2 * offset, n)));
    });
    chunks(LL_PEAK_LATENCY, irregular, [&](uint32_t offset, uint32_t n) {
        uint32_t written = 0; CHECK(CALL(ll_peak_drain(graph.peak, peak.data() + 2 * (count + offset), n, &written)) && written == n);
    });
    Result result; CHECK(CALL(ll_loudness_finish(graph.meter, &result.meter)) && result.meter.measurable);
    CHECK(CALL(ll_song_gain_get(graph.gain, &result.gain)));
    static_assert(sizeof(LLBusFrame) == 9 * sizeof(float) && sizeof(LLGlueFrame) == 7 * sizeof(float));
    result.append(dry); result.append(bus); result.append(delayed); result.append(wet);
    result.append(stereo); result.append(air); result.append(gained); result.append(peak);
    CHECK(ll_mixer_position(graph.mixer) == origin + count && ll_mixer_steals(graph.mixer) == 0);
    return result;
}
static void setupAndRenderModes(State original) {
    install(mode(original, 0, 0, false)); Graph baseline; const auto expected = render(baseline, false);
    for (uint32_t setupRound = 0; setupRound < 4; ++setupRound) for (uint32_t setupFlush = 0; setupFlush < flushModes; ++setupFlush) {
        install(mode(original, setupRound, setupFlush, setupFlush % 2)); Graph graph;
        for (uint32_t round = 0; round < 4; ++round) for (uint32_t flush = 0; flush < flushModes; ++flush) {
            install(mode(original, round, flush, (setupRound + round + setupFlush + flush) % 2)); graph.reset();
            CHECK(expected.same(render(graph, true)));
        }
    }
}
static void rejectionAndRollback(State original) {
    const float snan = fromBits<float>(uint32_t{0x7f800001}), negativeTiny = fromBits<float>(uint32_t{0x80000001});
    const double doubleSNaN = fromBits<double>(uint64_t{0x7ff0000000000001}), negativeDoubleTiny = fromBits<double>(uint64_t{0x8000000000000001});
    for (uint32_t round = 0; round < 4; ++round) for (uint32_t flush = 0; flush < flushModes; ++flush) for (bool flags : {false, true}) {
        install(mode(original, round, flush, flags));
        auto *mixer = SETUP(ll_mixer_create()); CHECK(mixer);
        CHECK(!CALL(ll_mixer_configure_buses(mixer, doubleSNaN)));
        CHECK(!CALL(ll_mixer_configure_buses(mixer, negativeDoubleTiny)));
        CHECK(CALL(ll_mixer_configure_buses(mixer, 0)));
        CHECK(CALL(ll_mixer_configure_buses(mixer, -0.0)));
        CHECK(CALL(ll_mixer_configure_buses(mixer, .5)));
        auto invalidFades = fades; invalidFades.tonal_out_end_frame = doubleSNaN;
        CHECK(!CALL(ll_mixer_configure_fades(mixer, &invalidFades)));
        const float invalidPCM[]{.125f, snan}; CHECK(CALL(ll_mixer_add_sample(mixer, invalidPCM, 2, 1)) == -1);
        const float pcm = .125f; CHECK(CALL(ll_mixer_add_sample(mixer, &pcm, 1, 1)) == 0);
        LLEvent note{}; note.hold_frames = 1; note.velocity = negativeTiny;
        CHECK(!CALL(ll_mixer_load_events(mixer, &note, 1)));
        note.velocity = snan; CHECK(!CALL(ll_mixer_load_events(mixer, &note, 1)));
        note.velocity = -0.0f; CHECK(CALL(ll_mixer_load_events(mixer, &note, 1)));
        note.velocity = 0; CHECK(CALL(ll_mixer_load_events(mixer, &note, 1)));
        note.velocity = 1; CHECK(CALL(ll_mixer_load_events(mixer, &note, 1)));
        SETUP(ll_mixer_destroy(mixer));
        CHECK(!SETUP(ll_room_create(doubleSNaN, .5))); CHECK(!SETUP(ll_room_create(.5, negativeDoubleTiny)));
        CHECK(!SETUP(ll_air_create(1, count, 0, doubleSNaN, &fades)));
        CHECK(!SETUP(ll_song_mix_create(1, count, 0, negativeDoubleTiny, &fades)));
        CHECK(!SETUP(ll_song_gain_create(doubleSNaN)));
        auto *zeroGlue = SETUP(ll_glue_create(2, 0)); CHECK(zeroGlue);
        std::array<LLBusFrame, 2> zeroBuses{}; zeroBuses[1].duck = -0.0f;
        std::array<LLGlueFrame, 2> zeroOutput{};
        CHECK(CALL(ll_glue_process(zeroGlue, zeroBuses.data(), zeroOutput.data(), 2)));
        SETUP(ll_glue_destroy(zeroGlue));
        Graph graph; const auto expected = render(graph, false); graph.reset();
        std::array<LLBusFrame, 2> buses{}; buses[0].duck = 1; buses[1].duck = negativeTiny;
        std::array<LLGlueFrame, 2> output{}; CHECK(!CALL(ll_glue_process(graph.glue, buses.data(), output.data(), 2)));
        buses[1].duck = 1; buses[1].guitar[1] = snan; CHECK(!CALL(ll_glue_process(graph.glue, buses.data(), output.data(), 2)));
        std::array<LLGlueFrame, 2> input{}; input[0].duck = input[1].duck = 1; input[1].tonal[1] = snan;
        CHECK(!CALL(ll_room_process(graph.room, input.data(), output.data(), 2)));
        float stereo[4]{.125f, -.125f, .25f, snan}, destination[4]{7, 7, 7, 7};
        CHECK(!CALL(ll_song_mix_process(graph.mix, input.data(), destination, 2)));
        CHECK(!CALL(ll_air_add(graph.air, stereo, 2))); stereo[3] = snan;
        CHECK(!CALL(ll_loudness_process(graph.meter, stereo, 2)));
        CHECK(!CALL(ll_song_gain_process(graph.gain, stereo, destination, 2)));
        CHECK(!CALL(ll_peak_process(graph.peak, stereo, destination, 2)));
        uint32_t written = 7; CHECK(!CALL(ll_glue_drain(graph.glue, output.data(), 2, &written)) && written == 0);
        LLLoudnessResult incomplete{}; CHECK(!CALL(ll_loudness_finish(graph.meter, &incomplete)));
        CHECK(expected.same(render(graph, true))); // Every rejected stage retained its prior signal state.
    }
}
int main() {
    const auto original = state(); setupAndRenderModes(original); rejectionAndRollback(original); install(original);
    std::puts("Native DSP setup/render rounding independence, full FP restoration, rollback and allocation audits passed");
}
