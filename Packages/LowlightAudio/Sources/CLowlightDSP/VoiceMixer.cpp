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
constexpr uint32_t duckFrames = 8960;
struct Lowpass {
    double b0 = 0, b1 = 0, a1 = 0, a2 = 0;
    double first[2]{}, second[2]{};
    void configure(double cutoff) {
        const double tangent = std::tan(pi * cutoff / 32000);
        const double denominator = 1 + tangent / std::sqrt(.5) + tangent * tangent;
        b0 = tangent * tangent / denominator; b1 = 2 * b0;
        a1 = 2 * (tangent * tangent - 1) / denominator;
        a2 = (1 - tangent / std::sqrt(.5) + tangent * tangent) / denominator;
    }
    float process(float input, uint32_t channel) {
        const double result = b0 * input + first[channel];
        first[channel] = b1 * input - a1 * result + second[channel];
        second[channel] = b0 * input - a2 * result;
        return normal(static_cast<float>(result));
    }
};
struct Buses {
    Lowpass filters[4]{};
    float duck[duckFrames]{};
    float drumGain = 0, hatGain = 0, bassGain = 0;
    uint32_t duckAge = duckFrames;
    bool configured = false;
    void reset() {
        for (auto &filter : filters)
            for (uint32_t ch = 0; ch < 2; ++ch) filter.first[ch] = filter.second[ch] = 0;
        duckAge = duckFrames;
    }
    LLBusFrame process(const float (&stems)[7][2]) {
        LLBusFrame result{};
        result.duck = duckAge < duckFrames ? duck[duckAge++] : 1;
        for (uint32_t ch = 0; ch < 2; ++ch) {
            result.guitar[ch] = normal(stems[0][ch]);
            result.piano[ch] = normal(stems[1][ch]);
            result.bass[ch] = normal((stems[2][ch] * 1.20f) * bassGain);
            const float kick = filters[0].process(stems[3][ch], ch) * .50f;
            const float stick = filters[1].process(stems[4][ch], ch) * .44f;
            float drums = (kick + stick) * drumGain;
            drums += (filters[2].process(stems[5][ch], ch) * .42f) * hatGain;
            drums += filters[3].process(stems[6][ch], ch) * .24f;
            result.drums[ch] = normal(drums);
        }
        return result;
    }
};
}

struct LLMixer {
    float *pcm = nullptr;
    Sample samples[LL_SAMPLE_LIMIT]{};
    Event events[LL_EVENT_LIMIT]{};
    Voice voices[LL_VOICE_LIMIT]{};
    Buses buses{};
    uint32_t samplesUsed = 0, floatsUsed = 0, eventCount = 0, next = 0;
    uint32_t steals = 0, dropped = 0;
    uint32_t sharedVoices = LL_VOICE_LIMIT;
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
bool ll_mixer_configure_buses(LLMixer *m, double energy) {
    if (!m || m->loaded || !std::isfinite(energy) || energy < 0 || energy > 1) return false;
    constexpr double cutoffs[] = {280, 1050, 1450, 1200};
    for (uint32_t i = 0; i < 4; ++i) m->buses.filters[i].configure(cutoffs[i]);
    for (uint32_t i = 0; i < duckFrames; ++i)
        m->buses.duck[i] = static_cast<float>(1 - .055 * std::exp(-static_cast<double>(i) / 32000 / .105));
    m->buses.drumGain = static_cast<float>(.85 + .45 * energy);
    m->buses.hatGain = static_cast<float>(.9 + .35 * energy);
    m->buses.bassGain = static_cast<float>(.98 + .06 * energy);
    m->buses.configured = true;
    m->buses.reset();
    return true;
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
    m->buses.reset();
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
            !std::isfinite(e.pan) || e.pan < -1 || e.pan > 1 || e.instrument > 6 ||
            e.connected > 1 || e.priority > 2) return false;
        const bool bass = e.instrument == 2;
        const bool percussion = e.instrument >= 3;
        if (bass && (e.midi < 31 || e.midi > 57 || m->samples[e.sample_index].channels != 1)) return false;
        if (percussion && (e.priority != 0 || e.midi != (e.instrument == 4 ? 1 : 0) ||
                           m->samples[e.sample_index].channels != 1)) return false;
        const uint32_t lifetime = bass ? e.hold_frames + e.release_frames :
            (percussion ? m->samples[e.sample_index].frames : sampleFramesLimit);
        if (e.start_frame > timelineLimit - lifetime) return false;
        hasBass |= bass;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const auto &e = events[i];
        auto &out = m->events[i];
        out.note = e;
        const bool bass = e.instrument == 2;
        const bool percussion = e.instrument >= 3;
        out.frames = bass ? e.hold_frames + e.release_frames :
            (percussion ? m->samples[e.sample_index].frames :
             std::min(m->samples[e.sample_index].frames, e.hold_frames + e.release_frames));
        out.attack = bass || percussion ? 0 : std::min(out.frames, e.instrument ? 288u : 448u);
        out.frequency = bass ? 440 * std::pow(2.0, (static_cast<int>(e.midi) - 69) / 12.0) : 0;
        out.bassGain = bass ? .24 * std::pow(static_cast<double>(e.velocity), 1.10) : 0;
        if (percussion) {
            constexpr double gains[] = {.31, .25, .27, .11};
            out.gain = normal(static_cast<float>(gains[e.instrument - 3] *
                std::pow(static_cast<double>(e.velocity), 1.25)));
        } else out.gain = normal(static_cast<float>(bass ? out.bassGain : (e.instrument ? .23 : .235) *
            std::pow(static_cast<double>(e.velocity), 1.05) * (e.connected ? .9 : 1)));
        const double pan = bass ? 0 : e.pan;
        out.left = static_cast<float>(std::cos((pan + 1.0) * pi / 4)) * static_cast<float>(std::sqrt(2.0));
        out.right = static_cast<float>(std::sin((pan + 1.0) * pi / 4)) * static_cast<float>(std::sqrt(2.0));
    }
    m->sharedVoices = hasBass ? LL_VOICE_LIMIT - 1 : LL_VOICE_LIMIT;
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
    for (uint32_t i = 0; i < m.sharedVoices; ++i) {
        auto &voice = m.voices[i];
        if (!voice.active) { start(voice, index); return; }
    }
    int best = -1;
    for (uint32_t i = 0; i < m.sharedVoices; ++i) {
        const auto &voice = m.voices[i];
        const auto &event = m.events[voice.event];
        if (voice.pending >= 0 || event.note.priority > incoming.note.priority) continue;
        if (best < 0) { best = i; continue; }
        const auto &prior = m.voices[best];
        const auto &priorEvent = m.events[prior.event];
        const bool releasing = event.note.instrument >= 3 || voice.age >= event.note.hold_frames;
        const bool priorReleasing = priorEvent.note.instrument >= 3 || prior.age >= priorEvent.note.hold_frames;
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
void renderFrame(LLMixer &m, float *output, LLBusFrame *busOutput) {
    while (m.next < m.eventCount && m.events[m.next].note.start_frame <= m.position) {
        // Score-keyed, even when a silent/overloaded kick is never admitted to a voice.
        if (m.events[m.next].note.instrument == 3) m.buses.duckAge = 0;
        schedule(m, m.next++);
    }
    float left = 0, right = 0;
    float stems[7][2]{};
    for (auto &v : m.voices) {
        if (!v.active) continue;
        const auto &e = m.events[v.event];
        const auto &s = m.samples[e.note.sample_index];
        float voiceLeft, voiceRight;
        if (e.note.instrument == 2) {
            const float sample = bassSample(v, e, s, m.pcm);
            voiceLeft = sample * e.left; voiceRight = sample * e.right;
        } else if (e.note.instrument >= 3) {
            const float sample = m.pcm[s.offset + v.age];
            const float fade = v.fade ? static_cast<float>(v.fade - 1) / (LL_STEAL_FRAMES - 1) : 1;
            // Preserve the accepted per-hit rounding: pan first, then velocity gain.
            voiceLeft = ((sample * e.left) * e.gain) * fade;
            voiceRight = ((sample * e.right) * e.gain) * fade;
        } else {
            const uint32_t offset = s.offset + v.age * s.channels;
            const float gain = envelope(v, e);
            const float l = m.pcm[offset] * gain;
            const float r = m.pcm[offset + s.channels - 1] * gain;
            const float mid = (l + r) * .5f;
            const float side = (l - r) * .5f * (e.note.instrument ? .75f : 0);
            voiceLeft = (mid + side) * e.left;
            voiceRight = (mid - side) * e.right;
        }
        // Preserve the original slot-order dry sum independently of instrument routing.
        left += voiceLeft; right += voiceRight;
        if (m.buses.configured) {
            stems[e.note.instrument][0] += voiceLeft;
            stems[e.note.instrument][1] += voiceRight;
        }
        ++v.age;
        if (v.fade) --v.fade;
        if (v.age == e.frames || (v.pending >= 0 && v.fade == 0)) {
            if (v.pending >= 0) start(v, static_cast<uint32_t>(v.pending));
            else v.active = false;
        }
    }
    if (output) { output[0] = normal(left); output[1] = normal(right); }
    if (m.buses.configured) {
        const auto frame = m.buses.process(stems);
        if (busOutput) *busOutput = frame;
    }
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
        for (; offset < end; ++offset) renderFrame(*m, output + uint64_t{offset} * 2, nullptr);
    }
    return true;
}
bool ll_mixer_render_buses(LLMixer *m, LLBusFrame *output, uint32_t frames) {
    if (frames && !output) return false;
    if (!m || !m->loaded || !m->buses.configured || frames > timelineLimit - m->position) {
        for (uint32_t i = 0; i < frames; ++i) output[i] = LLBusFrame{};
        return false;
    }
    FlushSubnormals mode;
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset) renderFrame(*m, nullptr, output + offset);
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
