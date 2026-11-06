// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>

namespace lowlight {
// Coefficients are designed by the control producer. Only interpolation and fixed-size
// copies take place on the render consumer.
constexpr uint32_t effectRampFrames = 6400;
constexpr uint32_t effectLead = LL_GLUE_LATENCY + LL_PEAK_LATENCY;
constexpr uint32_t combFrames[2][8] = {{950, 1110, 1187, 1315, 1398, 1533, 1706, 1898},
                                       {995, 1155, 1232, 1360, 1443, 1577, 1750, 1942}};
struct EffectShape {
    double toneBin = 0, texture = 0, wet = 0;
    double b0 = 0, b1 = 0, a1 = 0, a2 = 0;
    double feedback[2][8]{};
};
struct EffectTarget {
    LLEffectValues values{};
    EffectShape shape;
    uint64_t revision = 0;
};
inline EffectTarget designEffects(LLEffectValues values, uint32_t bin, uint64_t revision) {
    FloatingPointMode mode;
    EffectTarget target{values, {}, revision};
    auto &shape = target.shape;
    shape.toneBin = bin;
    shape.texture = values.texture;
    shape.wet = static_cast<float>(.60 + .8 * values.space);
    const double tangent = std::tan(3.14159265358979323846 * (1700 - 700 * values.warmth) / 32000);
    const double denominator = 1 + tangent / std::sqrt(.5) + tangent * tangent;
    shape.b0 = tangent * tangent / denominator;
    shape.b1 = 2 * shape.b0;
    shape.a1 = 2 * (tangent * tangent - 1) / denominator;
    shape.a2 = (1 - tangent / std::sqrt(.5) + tangent * tangent) / denominator;
    const double decay = 1.65 + .85 * values.space;
    for (unsigned ch = 0; ch < 2; ++ch)
        for (unsigned i = 0; i < 8; ++i)
            shape.feedback[ch][i] = std::pow(10., -3. * combFrames[ch][i] / 32000 / decay);
    return target;
}
inline uint64_t effectBits(double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    // Preserve positive subnormal identity even when the caller flushes FP inputs.
    return bits == UINT64_C(0x8000000000000000) ? 0 : bits;
}
inline bool sameEffects(LLEffectValues a, LLEffectValues b) {
    return effectBits(a.warmth) == effectBits(b.warmth) &&
           effectBits(a.space) == effectBits(b.space) &&
           effectBits(a.texture) == effectBits(b.texture);
}
struct ShapePoint {
    const EffectShape &from, &to;
    double fraction;
    double interpolate(double a, double b) const {
        return a + fraction * (b - a);
    }
    double field(double EffectShape::*member) const {
        return &from == &to ? to.*member : interpolate(from.*member, to.*member);
    }
    double feedback(unsigned channel, unsigned comb) const {
        return &from == &to ? to.feedback[channel][comb]
                            : interpolate(from.feedback[channel][comb], to.feedback[channel][comb]);
    }
    EffectShape value() const {
        if (&from == &to)
            return to;
        EffectShape result{field(&EffectShape::toneBin), field(&EffectShape::texture),
                           field(&EffectShape::wet),     field(&EffectShape::b0),
                           field(&EffectShape::b1),      field(&EffectShape::a1),
                           field(&EffectShape::a2)};
        for (unsigned ch = 0; ch < 2; ++ch)
            for (unsigned i = 0; i < 8; ++i)
                result.feedback[ch][i] = feedback(ch, i);
        return result;
    }
};
// The note filters can run ahead of the room and air. Preserve only the portion
// already committed by earlier controls that a delayed stage can still encounter.
class EffectTimeline {
    EffectShape history[effectLead]{}, from{}, to{};
    uint64_t start = 0, finish = 0;

public:
    void seed(const EffectShape &shape) {
        from = to = shape;
        start = finish = 0;
    }
    const EffectShape *constant(uint64_t frame) const {
        return frame >= finish ? &to : nullptr;
    }
    uint64_t end() const {
        return finish;
    }
    ShapePoint at(uint64_t frame) const {
        if (frame < start) {
            const auto &past = history[frame % effectLead];
            return {past, past, 0};
        }
        if (frame >= finish)
            return {to, to, 0};
        return {from, to, double(frame - start) / effectRampFrames};
    }
    void retarget(uint64_t frame, const EffectShape &next) {
        const auto current = at(frame).value();
        const auto oldest = frame >= effectLead ? frame - effectLead : 0;
        for (auto cursor = std::max(oldest, start); cursor < frame; ++cursor)
            history[cursor % effectLead] = at(cursor).value();
        from = current;
        to = next;
        start = frame;
        finish = frame + effectRampFrames;
    }
};

// Three slots have exclusive writer, reader and exchange ownership. The producer
// mutex serializes independent off-callback senders. Render only exchanges indices.
class LiveEffects {
    EffectTarget slots[3]{}, lastSent{}, active{};
    std::mutex producer;
    unsigned back = 1, front = 0;
    static constexpr unsigned dirty = 4;
    std::atomic<unsigned> middle{2};
    std::atomic<uint64_t> sequence{0}, adopted{0}, settled{0}, settledBits[3]{};
    bool initialized = false;
    void acknowledge(bool complete) {
        // SC sequence and fields allow non-render readers a coherent multiword observation.
        sequence.fetch_add(1);
        adopted.store(active.revision);
        if (complete) {
            settledBits[0].store(effectBits(active.values.warmth));
            settledBits[1].store(effectBits(active.values.space));
            settledBits[2].store(effectBits(active.values.texture));
            settled.store(active.revision);
        }
        sequence.fetch_add(1);
    }
    static double value(uint64_t raw) {
        double result;
        std::memcpy(&result, &raw, sizeof(result));
        return result;
    }
    static bool valid(LLEffectValues v, uint32_t bin) {
        return unitInterval(v.warmth) && unitInterval(v.space) && unitInterval(v.texture) &&
               bin <= 100;
    }

public:
    EffectTimeline timeline;
    bool enabled() const {
        return initialized;
    }
    bool seed(LLEffectValues values, uint32_t bin) {
        if (initialized || !valid(values, bin))
            return false;
        lastSent = active = designEffects(values, bin, 1);
        timeline.seed(active.shape);
        initialized = true;
        acknowledge(true);
        return true;
    }
    bool send(LLEffectValues v, uint32_t bin, uint64_t revision) {
        if (!initialized || !revision || !valid(v, bin))
            return false;
        std::lock_guard<std::mutex> lock(producer);
        if (revision <= lastSent.revision)
            return revision == lastSent.revision && sameEffects(v, lastSent.values) &&
                   bin == lastSent.shape.toneBin;
        slots[back] = lastSent = designEffects(v, bin, revision);
        back = middle.exchange(back | dirty, std::memory_order_acq_rel) & ~dirty;
        return true;
    }
    void consume(uint64_t input, uint64_t returned) {
        if (!(middle.load(std::memory_order_acquire) & dirty))
            return;
        front = middle.exchange(front, std::memory_order_acq_rel) & ~dirty;
        const auto &next = slots[front];
        if (!sameEffects(active.values, next.values) || active.shape.toneBin != next.shape.toneBin)
            timeline.retarget(input + effectLead, next.shape);
        active = next;
        acknowledge(returned >= timeline.end());
    }
    void advanced(uint64_t returned) {
        if (returned >= timeline.end() &&
            settled.load(std::memory_order_relaxed) != active.revision)
            acknowledge(true);
    }
    LLEffectProgress progress() const {
        LLEffectProgress result{};
        for (;;) {
            const auto before = sequence.load();
            if (before & 1)
                continue;
            result = {adopted.load(),
                      settled.load(),
                      {value(settledBits[0].load()), value(settledBits[1].load()),
                       value(settledBits[2].load())}};
            if (sequence.load() == before)
                return result;
        }
    }
};
}

struct LLMixerAdvance;
// Setup/producer-only: inspect an exclusively owned unstarted rack or an immutable
// prepared patch before admission. Never scan a score on the render consumer.
bool ll_mixer_supports_effects(const LLMixer *);
bool ll_mixer_advance_supports_effects(const LLMixerAdvance *);
bool ll_song_source_supports_effects(const LLSongSource *);
bool ll_song_replay_supports_effects(const LLSongReplay *);
void ll_song_replay_use_effects(LLSongReplay *, const lowlight::EffectTimeline *,
                                uint64_t placement);
void ll_song_source_use_effects(LLSongSource *, const lowlight::EffectTimeline *,
                                uint64_t placement);
bool ll_room_process_effects(LLRoom *, const LLGlueFrame *, LLGlueFrame *, uint32_t,
                             const lowlight::EffectTimeline *, uint64_t);
bool ll_song_mix_process_effects(LLSongMix *, const LLGlueFrame *, float *, uint32_t,
                                 const lowlight::EffectTimeline *, uint64_t);
bool ll_air_add_effects(LLAir *, float *, uint32_t, const lowlight::EffectTimeline *, uint64_t);
