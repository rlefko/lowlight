// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "LowlightDSP.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <new>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif

namespace {
constexpr double pi = 3.14159265358979323846;
constexpr uint64_t timelineLimit = uint64_t{1} << 52;
constexpr uint32_t sampleFramesLimit = 215513;
float normal(float value) { return std::abs(value) < std::numeric_limits<float>::min() ? 0 : value; }
void increment(uint32_t &value) { if (value != UINT32_MAX) ++value; }

// Scoped thread-local FP mode; preserve the host's exact state on return.
struct FlushSubnormals {
#if defined(__aarch64__)
    uint64_t previous;
    FlushSubnormals() {
        asm volatile("mrs %0, fpcr" : "=r"(previous) : : "memory");
        const uint64_t next = previous | (uint64_t{1} << 24);
        asm volatile("msr fpcr, %0" : : "r"(next) : "memory");
    }
    ~FlushSubnormals() { asm volatile("msr fpcr, %0" : : "r"(previous) : "memory"); }
#elif defined(__SSE2__)
    unsigned previous = _mm_getcsr();
    FlushSubnormals() { _mm_setcsr(previous | 0x8040); }
    ~FlushSubnormals() { _mm_setcsr(previous); }
#else
#error Lowlight requires an ARM64 or SSE2 floating-point target
#endif
};
struct Sample { uint32_t offset = 0, frames = 0, channels = 0; };
struct Event {
    LLEvent note{};
    uint32_t frames = 0, attack = 0;
    float gain = 0, left = 0, right = 0;
    double frequency = 0, bassGain = 0;
};
struct Voice {
    uint32_t event = 0, age = 0, fade = 0;
    int32_t pending = -1;
    bool active = false;
};
}

struct LLMixer {
    float *pcm = nullptr;
    Sample samples[LL_SAMPLE_LIMIT]{};
    Event events[LL_EVENT_LIMIT]{};
    Voice voices[LL_VOICE_LIMIT]{};
    uint32_t samplesUsed = 0, floatsUsed = 0, eventCount = 0, next = 0;
    uint32_t steals = 0, dropped = 0;
    uint32_t tonalVoices = LL_VOICE_LIMIT;
    uint64_t position = 0;
    bool loaded = false;
};

LLMixer *ll_mixer_create() {
    auto *mixer = new (std::nothrow) LLMixer;
    if (!mixer) return nullptr;
    mixer->pcm = new (std::nothrow) float[LL_SAMPLE_BYTES / sizeof(float)];
    if (!mixer->pcm) { delete mixer; return nullptr; }
    return mixer;
}
void ll_mixer_destroy(LLMixer *mixer) {
    if (mixer) { delete[] mixer->pcm; delete mixer; }
}
int32_t ll_mixer_add_sample(LLMixer *m, const float *pcm, uint32_t frames, uint32_t channels) {
    if (!m || !pcm || m->loaded || m->samplesUsed == LL_SAMPLE_LIMIT || !frames ||
        frames > sampleFramesLimit || (channels != 1 && channels != 2)) return -1;
    const uint32_t count = frames * channels;
    if (count > LL_SAMPLE_BYTES / sizeof(float) - m->floatsUsed) return -1;
    for (uint32_t i = 0; i < count; ++i)
        if (!std::isfinite(pcm[i]) || std::abs(pcm[i]) > 8) return -1;
    const uint32_t index = m->samplesUsed++;
    m->samples[index] = {m->floatsUsed, frames, channels};
    for (uint32_t i = 0; i < count; ++i) m->pcm[m->floatsUsed + i] = normal(pcm[i]);
    m->floatsUsed += count;
    return static_cast<int32_t>(index);
}
void ll_mixer_reset(LLMixer *m) {
    if (!m) return;
    for (auto &voice : m->voices) voice = Voice{};
    m->position = 0; m->next = 0; m->steals = 0; m->dropped = 0;
}
bool ll_mixer_load_events(LLMixer *m, const LLEvent *events, uint32_t count) {
    if (!m || count > LL_EVENT_LIMIT || (count && !events)) return false;
    bool hasBass = false;
    for (uint32_t i = 0; i < count; ++i) {
        const auto &e = events[i];
        if (e.sample_index >= m->samplesUsed ||
            (i && e.start_frame < events[i - 1].start_frame) || !e.hold_frames ||
            e.hold_frames > 16 * 32000 || e.release_frames > 5 * 32000 ||
            !std::isfinite(e.velocity) || e.velocity < 0 || e.velocity > 1 ||
            !std::isfinite(e.pan) || e.pan < -1 || e.pan > 1 || e.instrument > 2 ||
            e.connected > 1 || e.priority > 2) return false;
        const bool bass = e.instrument == 2;
        if (bass && (e.midi < 31 || e.midi > 57 || m->samples[e.sample_index].channels != 1)) return false;
        const uint32_t lifetime = bass ? e.hold_frames + e.release_frames : sampleFramesLimit;
        if (e.start_frame > timelineLimit - lifetime) return false;
        hasBass |= bass;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const auto &e = events[i];
        auto &out = m->events[i];
        out.note = e;
        const bool bass = e.instrument == 2;
        out.frames = bass ? e.hold_frames + e.release_frames :
            std::min(m->samples[e.sample_index].frames, e.hold_frames + e.release_frames);
        out.attack = bass ? 0 : std::min(out.frames, e.instrument ? 288u : 448u);
        out.frequency = bass ? 440 * std::pow(2.0, (static_cast<int>(e.midi) - 69) / 12.0) : 0;
        out.bassGain = bass ? .24 * std::pow(static_cast<double>(e.velocity), 1.10) : 0;
        out.gain = normal(static_cast<float>(bass ? out.bassGain : (e.instrument ? .23 : .235) *
            std::pow(static_cast<double>(e.velocity), 1.05) * (e.connected ? .9 : 1)));
        const double pan = bass ? 0 : e.pan;
        out.left = static_cast<float>(std::cos((pan + 1.0) * pi / 4)) * static_cast<float>(std::sqrt(2.0));
        out.right = static_cast<float>(std::sin((pan + 1.0) * pi / 4)) * static_cast<float>(std::sqrt(2.0));
    }
    m->tonalVoices = hasBass ? LL_VOICE_LIMIT - 1 : LL_VOICE_LIMIT;
    m->eventCount = count; m->loaded = true;
    ll_mixer_reset(m);
    return true;
}

namespace {
void start(Voice &voice, uint32_t event) { voice = Voice{event, 0, 0, -1, true}; }
void replace(LLMixer &m, Voice &voice, uint32_t index) {
    if (voice.pending >= 0) { increment(m.dropped); return; }
    voice.pending = static_cast<int32_t>(index);
    voice.fade = LL_STEAL_FRAMES;
    increment(m.steals);
}
void schedule(LLMixer &m, uint32_t index) {
    const auto &incoming = m.events[index];
    if (incoming.gain == 0) return;
    if (incoming.note.instrument == 2) {
        auto &bass = m.voices[LL_VOICE_LIMIT - 1];
        if (bass.active) replace(m, bass, index);
        else start(bass, index);
        return;
    }
    for (uint32_t i = 0; i < m.tonalVoices; ++i) {
        auto &voice = m.voices[i];
        if (!voice.active) { start(voice, index); return; }
    }
    int best = -1;
    for (uint32_t i = 0; i < m.tonalVoices; ++i) {
        const auto &voice = m.voices[i];
        const auto &event = m.events[voice.event];
        if (voice.pending >= 0 || event.note.priority > incoming.note.priority) continue;
        if (best < 0) { best = i; continue; }
        const auto &prior = m.voices[best];
        const auto &priorEvent = m.events[prior.event];
        const bool releasing = voice.age >= event.note.hold_frames;
        const bool priorReleasing = prior.age >= priorEvent.note.hold_frames;
        if (event.note.priority < priorEvent.note.priority ||
            (event.note.priority == priorEvent.note.priority &&
             ((releasing && !priorReleasing) || (releasing == priorReleasing && voice.age > prior.age)))) best = i;
    }
    if (best < 0) { increment(m.dropped); return; }
    replace(m, m.voices[best], index);
}
float envelope(const Voice &v, const Event &e) {
    float result = 1;
    if (v.age < e.attack) {
        const double sine = e.attack == 1 ? 0 : std::sin((pi / 2) * v.age / (e.attack - 1));
        result = static_cast<float>(sine * sine);
    }
    if (v.age >= e.note.hold_frames) {
        const uint32_t release = e.frames - e.note.hold_frames;
        const double cosine = release == 1 ? 1 : std::cos((pi / 2) * (v.age - e.note.hold_frames) / (release - 1));
        result *= static_cast<float>(cosine * cosine);
    }
    if (v.fade) result *= static_cast<float>(v.fade - 1) / (LL_STEAL_FRAMES - 1);
    return normal(result * e.gain);
}
float bassSample(const Voice &v, const Event &e, const Sample &s, const float *pcm) {
    const double time = v.age / 32000.0;
    const double tone = .21 * std::sin(2 * pi * e.frequency * time) +
        .105 * std::sin(4 * pi * e.frequency * time) + .037 * std::sin(6 * pi * e.frequency * time);
    const double attackDecay = (1 - std::exp(-time / .016)) * std::exp(-time / 2.6);
    const double body = v.age < s.frames ? pcm[s.offset + v.age] : 0;
    double value = (tone * attackDecay + body) * e.bassGain;
    if (v.age >= e.note.hold_frames) {
        const double cosine = e.note.release_frames == 1 ? 1 :
            std::cos((pi / 2) * (v.age - e.note.hold_frames) / (e.note.release_frames - 1));
        value *= cosine * cosine;
    }
    if (v.fade) value *= static_cast<double>(v.fade - 1) / (LL_STEAL_FRAMES - 1);
    return normal(static_cast<float>(value));
}
void renderFrame(LLMixer &m, float *output) {
    while (m.next < m.eventCount && m.events[m.next].note.start_frame <= m.position)
        schedule(m, m.next++);
    float left = 0, right = 0;
    for (auto &v : m.voices) {
        if (!v.active) continue;
        const auto &e = m.events[v.event];
        const auto &s = m.samples[e.note.sample_index];
        if (e.note.instrument == 2) {
            const float sample = bassSample(v, e, s, m.pcm);
            left += sample * e.left; right += sample * e.right;
        } else {
            const uint32_t offset = s.offset + v.age * s.channels;
            const float gain = envelope(v, e);
            const float l = m.pcm[offset] * gain;
            const float r = m.pcm[offset + s.channels - 1] * gain;
            const float mid = (l + r) * .5f;
            const float side = (l - r) * .5f * (e.note.instrument ? .75f : 0);
            left += (mid + side) * e.left;
            right += (mid - side) * e.right;
        }
        ++v.age;
        if (v.fade) --v.fade;
        if (v.age == e.frames || (v.pending >= 0 && v.fade == 0)) {
            if (v.pending >= 0) start(v, static_cast<uint32_t>(v.pending));
            else v.active = false;
        }
    }
    output[0] = normal(left); output[1] = normal(right);
    ++m.position;
}
}

bool ll_mixer_render(LLMixer *m, float *output, uint32_t frames) {
    if (frames && !output) return false;
    if (!m || !m->loaded || frames > timelineLimit - m->position) {
        for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) output[i] = 0;
        return false;
    }
    FlushSubnormals mode;
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset) renderFrame(*m, output + uint64_t{offset} * 2);
    }
    return true;
}
uint32_t ll_mixer_active_voices(const LLMixer *m) {
    uint32_t result = 0;
    if (m) for (const auto &voice : m->voices) result += voice.active;
    return result;
}
uint32_t ll_mixer_steals(const LLMixer *m) { return m ? m->steals : 0; }
uint32_t ll_mixer_dropped_events(const LLMixer *m) { return m ? m->dropped : 0; }
uint64_t ll_mixer_position(const LLMixer *m) { return m ? m->position : 0; }
uint32_t ll_mixer_sample_bytes(const LLMixer *m) { return m ? m->floatsUsed * sizeof(float) : 0; }
