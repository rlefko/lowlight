// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include "RackFades.h"
#include "SongAdvance.h"
#include "TonalRendering.h"
#include "TonalVoice.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <limits>
#include <new>

namespace {
constexpr double pi = 3.14159265358979323846;
constexpr uint64_t timelineLimit = uint64_t{1} << 52;
constexpr uint32_t sampleFramesLimit = 215513;
float normal(float value) {
    return std::abs(value) < std::numeric_limits<float>::min() ? 0 : value;
}
void increment(uint32_t &value) {
    if (value != UINT32_MAX)
        ++value;
}

struct Sample {
    uint32_t offset = 0, frames = 0, channels = 0, tonalKey = lowlight::tonalKeys;
    bool matches(const LLEvent &event) const {
        if (lowlight::bandKey(tonalKey))
            return event.instrument == 1 && event.midi == 50 + (tonalKey - 256) % 20;
        return tonalKey == lowlight::tonalKeys ||
               (tonalKey < 80 ? event.instrument == 0 && event.midi == 50 + tonalKey / 4
                              : event.instrument == 1 && event.midi == 50 + tonalKey - 80);
    }
};
struct Event {
    LLEvent note{};
    Sample sample{};
    uint32_t frames = 0, attack = 0;
    float gain = 0, left = 0, right = 0;
    double frequency = 0, bassGain = 0;
    bool cut = false;
};
struct Voice {
    uint32_t event = 0, age = 0, fade = 0;
    int32_t pending = -1;
    bool active = false;
    lowlight::TonalHistory tonal{};
};
constexpr uint32_t duckFrames = 8960;
struct Lowpass {
    double b0 = 0, b1 = 0, a1 = 0, a2 = 0;
    double first[2]{}, second[2]{};
    void configure(double cutoff) {
        const double tangent = std::tan(pi * cutoff / 32000);
        const double denominator = 1 + tangent / std::sqrt(.5) + tangent * tangent;
        b0 = tangent * tangent / denominator;
        b1 = 2 * b0;
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
    lowlight::RackFades fades{};
    void reset() {
        for (auto &filter : filters)
            for (uint32_t ch = 0; ch < 2; ++ch)
                filter.first[ch] = filter.second[ch] = 0;
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

struct LLMixerAdvance {
    Event events[LL_EVENT_LIMIT]{};
    uint32_t count = 0, slots = 0, prefix = 0, sampleBytes = 0, sharedVoices = LL_VOICE_LIMIT;
    uint64_t deadline = 0, boundary = 0;
    lowlight::RackFades fades{};
    float damping[3520]{};
};

struct LLMixer {
    float *pcm = nullptr;
    Sample samples[LL_SAMPLE_LIMIT]{};
    Event storage[LL_EVENT_LIMIT]{};
    const Event *events = storage;
    const LLMixerAdvance *advance = nullptr;
    Voice voices[LL_VOICE_LIMIT]{};
    Buses buses{};
    lowlight::TonalSetting tonal{};
    uint32_t initialBin = 0;
    uint32_t samplesUsed = 0, floatsUsed = 0, eventCount = 0, next = 0;
    uint32_t steals = 0, dropped = 0;
    uint32_t sharedVoices = LL_VOICE_LIMIT;
    std::atomic<uint32_t> requiredVoiceSlots{0}, visibleSampleBytes{0};
    uint64_t origin = 0, position = 0;
    bool loaded = false;
};

LLMixer *ll_mixer_create() {
    auto *mixer = new (std::nothrow) LLMixer;
    if (!mixer)
        return nullptr;
    mixer->pcm = new (std::nothrow) float[LL_SAMPLE_BYTES / sizeof(float)];
    if (!mixer->pcm) {
        delete mixer;
        return nullptr;
    }
    return mixer;
}
void ll_mixer_destroy(LLMixer *mixer) {
    if (mixer) {
        delete[] mixer->pcm;
        delete mixer;
    }
}
bool ll_mixer_configure_origin(LLMixer *m, uint64_t frameOrigin) {
    if (!m || m->loaded || frameOrigin > timelineLimit)
        return false;
    m->origin = frameOrigin;
    m->position = frameOrigin;
    return true;
}
bool ll_mixer_configure_buses(LLMixer *m, double energy) {
    lowlight::FloatingPointMode mode;
    if (!m || m->loaded || !lowlight::unitInterval(energy))
        return false;
    constexpr double cutoffs[] = {280, 1050, 1450, 1200};
    for (uint32_t i = 0; i < 4; ++i)
        m->buses.filters[i].configure(cutoffs[i]);
    for (uint32_t i = 0; i < duckFrames; ++i)
        m->buses.duck[i] =
            static_cast<float>(1 - .055 * std::exp(-static_cast<double>(i) / 32000 / .105));
    m->buses.drumGain = static_cast<float>(.85 + .45 * energy);
    m->buses.hatGain = static_cast<float>(.9 + .35 * energy);
    m->buses.bassGain = static_cast<float>(.98 + .06 * energy);
    m->buses.configured = true;
    m->buses.reset();
    return true;
}
bool ll_mixer_configure_fades(LLMixer *m, const LLRackFades *fades) {
    lowlight::FloatingPointMode mode;
    if (!m || !fades || m->loaded || !m->buses.configured)
        return false;
    return m->buses.fades.configure(*fades);
}
LLTonalCalibration *ll_tonal_calibration_create(const float *gains, uint32_t count) {
    lowlight::FloatingPointMode mode(lowlight::UnderflowMode::gradual);
    if (!gains || count != lowlight::tonalKeys * lowlight::warmthBins)
        return nullptr;
    for (uint32_t i = 0; i < count; ++i) {
        const bool guitar = i / lowlight::warmthBins < 80;
        if (!std::isfinite(gains[i]) || gains[i] < (guitar ? .45f : .35f) ||
            gains[i] > (guitar ? 3.2f : 4.f))
            return nullptr;
    }
    auto *table = new (std::nothrow) LLTonalCalibration;
    if (!table)
        return nullptr;
    std::memcpy(table->gains, gains, count * sizeof(float));
    for (uint32_t frame = 0; frame < 32000; ++frame) {
        const double time = static_cast<double>(frame) / 32000;
        table->pianoShape[frame] = .60 + .40 * (1 - std::exp(-time / .060));
    }
    for (uint32_t bin = 0; bin < lowlight::warmthBins; ++bin) {
        const double warmth = static_cast<double>(bin) / 100;
        for (uint32_t instrument = 0; instrument < 3; ++instrument) {
            const double cutoffs[] = {1300 - 600 * warmth, 1200 - 500 * warmth,
                                      4200 - 2500 * warmth};
            const double cutoff = cutoffs[instrument];
            const double tangent = std::tan(pi * cutoff / 32000);
            auto &filter = table->filters[instrument][bin];
            filter.sections[0] = lowlight::TonalSection::design(tangent, .541196100146197);
            filter.sections[1] = lowlight::TonalSection::design(tangent, 1.306562964876377);
        }
    }
    return table;
}
void ll_tonal_calibration_destroy(LLTonalCalibration *table) {
    delete table;
}
bool ll_mixer_configure_tonal(LLMixer *m, const LLTonalCalibration *table, uint32_t bin) {
    if (!m || m->loaded || m->tonal.table || !table || bin >= lowlight::warmthBins)
        return false;
    m->tonal.table = table;
    m->initialBin = bin;
    m->tonal.set(bin);
    return true;
}
static int32_t addSample(LLMixer *m, const float *pcm, uint32_t frames, uint32_t channels,
                         uint32_t key) {
    lowlight::FloatingPointMode mode;
    if (!m || !pcm || m->loaded || m->samplesUsed == LL_SAMPLE_LIMIT || !frames ||
        frames > sampleFramesLimit || (channels != 1 && channels != 2))
        return -1;
    const uint32_t count = frames * channels;
    if (count > LL_SAMPLE_BYTES / sizeof(float) - m->floatsUsed)
        return -1;
    for (uint32_t i = 0; i < count; ++i)
        if (!std::isfinite(pcm[i]) || std::abs(pcm[i]) > 8)
            return -1;
    const uint32_t index = m->samplesUsed++;
    m->samples[index] = {m->floatsUsed, frames, channels, key};
    for (uint32_t i = 0; i < count; ++i)
        m->pcm[m->floatsUsed + i] = key == lowlight::tonalKeys ? normal(pcm[i]) : pcm[i];
    m->floatsUsed += count;
    m->visibleSampleBytes.store(m->floatsUsed * sizeof(float), std::memory_order_relaxed);
    return static_cast<int32_t>(index);
}
int32_t ll_mixer_add_sample(LLMixer *m, const float *pcm, uint32_t frames, uint32_t channels) {
    return addSample(m, pcm, frames, channels, lowlight::tonalKeys);
}
int32_t ll_mixer_add_tonal_sample(LLMixer *m, const float *pcm, uint32_t frames, uint32_t channels,
                                  uint32_t key) {
    if (!m || !m->tonal.table || !lowlight::tonalFormat(key, channels))
        return -1;
    return addSample(m, pcm, frames, channels, key);
}
void ll_mixer_reset(LLMixer *m) {
    if (!m)
        return;
    for (auto &voice : m->voices)
        voice = Voice{};
    m->buses.reset();
    if (m->tonal.table)
        m->tonal.set(m->initialBin);
    m->position = m->origin;
    m->next = 0;
    m->steals = 0;
    m->dropped = 0;
}
static void configureEvent(Event &out, const LLEvent &e, const Sample &sample) {
    out.note = e;
    out.sample = sample;
    const bool bass = e.instrument == 2;
    const bool percussion = e.instrument >= 3;
    out.frames = bass ? e.hold_frames + e.release_frames
                      : (percussion ? sample.frames
                                    : std::min(sample.frames, e.hold_frames + e.release_frames));
    out.attack = bass || percussion ? 0 : std::min(out.frames, e.instrument ? 288u : 448u);
    out.frequency = bass ? 440 * std::pow(2.0, (static_cast<int>(e.midi) - 69) / 12.0) : 0;
    out.bassGain = bass ? .24 * std::pow(static_cast<double>(e.velocity), 1.10) : 0;
    if (percussion) {
        constexpr double gains[] = {.31, .25, .27, .11};
        out.gain = normal(static_cast<float>(gains[e.instrument - 3] *
                                             std::pow(static_cast<double>(e.velocity), 1.25)));
    } else
        out.gain = normal(static_cast<float>(
            bass ? out.bassGain
                 : (e.instrument ? .23 : .235) * std::pow(static_cast<double>(e.velocity), 1.05) *
                       (e.connected ? .9 : 1)));
    const double pan = bass ? 0 : e.pan;
    out.left =
        static_cast<float>(std::cos((pan + 1.0) * pi / 4)) * static_cast<float>(std::sqrt(2.0));
    out.right =
        static_cast<float>(std::sin((pan + 1.0) * pi / 4)) * static_cast<float>(std::sqrt(2.0));
}
bool ll_mixer_load_events(LLMixer *m, const LLEvent *events, uint32_t count) {
    lowlight::FloatingPointMode mode;
    if (!m || count > LL_EVENT_LIMIT || (count && !events))
        return false;
    if (m->advance)
        return false;
    bool hasBass = false;
    for (uint32_t i = 0; i < count; ++i) {
        const auto &e = events[i];
        if (e.start_frame < m->origin || e.sample_index >= m->samplesUsed ||
            !m->samples[e.sample_index].matches(e) ||
            (i && e.start_frame < events[i - 1].start_frame) || !e.hold_frames ||
            e.hold_frames > 16 * 32000 || e.release_frames > 5 * 32000 ||
            !lowlight::unitInterval(e.velocity) || !std::isfinite(e.pan) || e.pan < -1 ||
            e.pan > 1 || e.instrument > 6 || e.connected > 1 || e.priority > 2)
            return false;
        const bool bass = e.instrument == 2;
        const bool percussion = e.instrument >= 3;
        if (bass && (e.midi < 31 || e.midi > 57 || m->samples[e.sample_index].channels != 1))
            return false;
        if (percussion && (e.priority != 0 || e.midi != (e.instrument == 4 ? 1 : 0) ||
                           m->samples[e.sample_index].channels != 1))
            return false;
        const uint32_t lifetime =
            bass ? e.hold_frames + e.release_frames
                 : (percussion ? m->samples[e.sample_index].frames : sampleFramesLimit);
        if (e.start_frame > timelineLimit - lifetime)
            return false;
        hasBass |= bass;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const auto &e = events[i];
        auto &out = m->storage[i];
        configureEvent(out, e, m->samples[e.sample_index]);
    }
    // Setup-only half-open lifetime sweep. The fixed event cap bounds this O(E^2)
    // scan without scratch allocation; fades and silent PCM do not retire readers.
    uint32_t peak = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const auto &current = m->events[i];
        if (current.note.instrument == 2 || current.gain == 0)
            continue;
        uint32_t active = 1;
        for (uint32_t j = 0; j < i; ++j) {
            const auto &prior = m->events[j];
            if (prior.note.instrument != 2 && prior.gain != 0 &&
                prior.note.start_frame + prior.frames > current.note.start_frame)
                ++active;
        }
        peak = std::max(peak, active);
    }
    m->requiredVoiceSlots = peak + (hasBass ? 1u : 0u);
    m->sharedVoices = hasBass ? LL_VOICE_LIMIT - 1 : LL_VOICE_LIMIT;
    m->eventCount = count;
    m->loaded = true;
    ll_mixer_reset(m);
    return true;
}

namespace {
void start(Voice &voice, uint32_t event) {
    voice = Voice{event, 0, 0, -1, true};
}
void replace(LLMixer &m, Voice &voice, uint32_t index) {
    if (voice.pending >= 0) {
        increment(m.dropped);
        return;
    }
    voice.pending = static_cast<int32_t>(index);
    voice.fade = LL_STEAL_FRAMES;
    increment(m.steals);
}
void schedule(LLMixer &m, uint32_t index) {
    const auto &incoming = m.events[index];
    if (incoming.gain == 0)
        return;
    if (incoming.note.instrument == 2) {
        auto &bass = m.voices[LL_VOICE_LIMIT - 1];
        if (bass.active)
            replace(m, bass, index);
        else
            start(bass, index);
        return;
    }
    for (uint32_t i = 0; i < m.sharedVoices; ++i) {
        auto &voice = m.voices[i];
        if (!voice.active) {
            start(voice, index);
            return;
        }
    }
    int best = -1;
    for (uint32_t i = 0; i < m.sharedVoices; ++i) {
        const auto &voice = m.voices[i];
        const auto &event = m.events[voice.event];
        if (voice.pending >= 0 || event.note.priority > incoming.note.priority)
            continue;
        if (best < 0) {
            best = i;
            continue;
        }
        const auto &prior = m.voices[best];
        const auto &priorEvent = m.events[prior.event];
        const bool releasing = event.note.instrument >= 3 || voice.age >= event.note.hold_frames;
        const bool priorReleasing =
            priorEvent.note.instrument >= 3 || prior.age >= priorEvent.note.hold_frames;
        if (event.note.priority < priorEvent.note.priority ||
            (event.note.priority == priorEvent.note.priority &&
             ((releasing && !priorReleasing) ||
              (releasing == priorReleasing && voice.age > prior.age))))
            best = i;
    }
    if (best < 0) {
        increment(m.dropped);
        return;
    }
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
        const double cosine =
            release == 1 ? 1 : std::cos((pi / 2) * (v.age - e.note.hold_frames) / (release - 1));
        result *= static_cast<float>(cosine * cosine);
    }
    if (v.fade)
        result *= static_cast<float>(v.fade - 1) / (LL_STEAL_FRAMES - 1);
    return normal(result * e.gain);
}
float bassSample(const Voice &v, const Event &e, const Sample &s, const float *pcm) {
    const double time = v.age / 32000.0;
    const double tone = .21 * std::sin(2 * pi * e.frequency * time) +
                        .105 * std::sin(4 * pi * e.frequency * time) +
                        .037 * std::sin(6 * pi * e.frequency * time);
    const double attackDecay = (1 - std::exp(-time / .016)) * std::exp(-time / 2.6);
    const double body = v.age < s.frames ? pcm[s.offset + v.age] : 0;
    double value = (tone * attackDecay + body) * e.bassGain;
    if (v.age >= e.note.hold_frames) {
        const double cosine =
            e.note.release_frames == 1
                ? 1
                : std::cos((pi / 2) * (v.age - e.note.hold_frames) / (e.note.release_frames - 1));
        value *= cosine * cosine;
    }
    if (v.fade)
        value *= static_cast<double>(v.fade - 1) / (LL_STEAL_FRAMES - 1);
    return normal(static_cast<float>(value));
}
void renderFrame(LLMixer &m, float *output, LLBusFrame *busOutput) {
    while (m.next < m.eventCount && m.events[m.next].note.start_frame <= m.position) {
        // Score-keyed, even when a silent/overloaded kick is never admitted to a voice.
        if (m.events[m.next].note.instrument == 3)
            m.buses.duckAge = 0;
        schedule(m, m.next++);
    }
    float left = 0, right = 0;
    float stems[7][2]{};
    for (auto &v : m.voices) {
        if (!v.active)
            continue;
        const auto &e = m.events[v.event];
        const auto &s = e.sample;
        float voiceLeft, voiceRight;
        if (e.note.instrument == 2) {
            const float sample = bassSample(v, e, s, m.pcm);
            voiceLeft = sample * e.left;
            voiceRight = sample * e.right;
        } else if (e.note.instrument >= 3) {
            const float sample = m.pcm[s.offset + v.age];
            const float fade = v.fade ? static_cast<float>(v.fade - 1) / (LL_STEAL_FRAMES - 1) : 1;
            // Preserve the accepted per-hit rounding: pan first, then velocity gain.
            voiceLeft = ((sample * e.left) * e.gain) * fade;
            voiceRight = ((sample * e.right) * e.gain) * fade;
        } else {
            const uint32_t offset = s.offset + v.age * s.channels;
            float gain = envelope(v, e);
            if (e.cut && m.position >= m.advance->deadline) {
                const auto offset = std::min(uint64_t{3519}, m.position - m.advance->deadline);
                gain = normal(gain * m.advance->damping[offset]);
            }
            float sourceLeft = m.pcm[offset], sourceRight = m.pcm[offset + s.channels - 1];
            if (s.tonalKey != lowlight::tonalKeys) {
                const float calibration = m.tonal.gain(s.tonalKey);
                const auto &filter =
                    m.tonal.filters[lowlight::bandKey(s.tonalKey) ? 2 : e.note.instrument];
                sourceLeft = v.tonal.process(sourceLeft, 0, filter, calibration);
                if (s.channels == 1) {
                    sourceRight = sourceLeft;
                } else {
                    sourceRight = v.tonal.process(sourceRight, 1, filter, calibration);
                    // Beyond one second the softening factor is within half a Float ULP
                    // of unity for every normal sample. Earlier frames keep the original
                    // Double exponential and the Float boundary after calibration.
                    if (v.age < 32000) {
                        const double shape = m.tonal.table->pianoShape[v.age];
                        sourceLeft = lowlight::admittedTonal(sourceLeft * shape);
                        sourceRight = lowlight::admittedTonal(sourceRight * shape);
                    }
                }
            }
            const float l = sourceLeft * gain;
            const float r = sourceRight * gain;
            const float mid = (l + r) * .5f;
            const float side = (l - r) * .5f * (e.note.instrument ? .75f : 0);
            voiceLeft = (mid + side) * e.left;
            voiceRight = (mid - side) * e.right;
        }
        // Preserve the original slot-order dry sum independently of instrument routing.
        left += voiceLeft;
        right += voiceRight;
        if (m.buses.configured) {
            stems[e.note.instrument][0] += voiceLeft;
            stems[e.note.instrument][1] += voiceRight;
        }
        ++v.age;
        if (v.fade)
            --v.fade;
        if (v.age == e.frames || (e.cut && m.position + 1 >= m.advance->boundary) ||
            (v.pending >= 0 && v.fade == 0)) {
            if (v.pending >= 0)
                start(v, static_cast<uint32_t>(v.pending));
            else
                v.active = false;
        }
    }
    if (output) {
        output[0] = normal(left);
        output[1] = normal(right);
    }
    if (m.buses.configured) {
        m.buses.fades.apply(stems, m.position);
        const auto frame = m.buses.process(stems);
        if (busOutput)
            *busOutput = frame;
    }
    ++m.position;
}
}

bool ll_mixer_render(LLMixer *m, float *output, uint32_t frames) {
    if (frames && !output)
        return false;
    if (!m || !m->loaded || frames > timelineLimit - m->position) {
        for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
            output[i] = 0;
        return false;
    }
    lowlight::FloatingPointMode mode;
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset)
            renderFrame(*m, output + uint64_t{offset} * 2, nullptr);
    }
    return true;
}
bool ll_mixer_render_buses(LLMixer *m, LLBusFrame *output, uint32_t frames) {
    if (frames && !output)
        return false;
    if (!m || !m->loaded || !m->buses.configured || frames > timelineLimit - m->position) {
        for (uint32_t i = 0; i < frames; ++i)
            output[i] = LLBusFrame{};
        return false;
    }
    lowlight::FloatingPointMode mode;
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset)
            renderFrame(*m, nullptr, output + offset);
    }
    return true;
}
bool ll_mixer_render_effect_buses(LLMixer *m, LLBusFrame *output, uint32_t frames,
                                  const double *bins) {
    if (!m || !m->tonal.table || !m->loaded || !m->buses.configured ||
        frames > timelineLimit - m->position || (frames && (!output || !bins)))
        return false;
    lowlight::FloatingPointMode mode;
    for (uint32_t i = 0; i < frames; ++i)
        if (lowlight::frameBits(bins[i]) > lowlight::frameBits(100.))
            return false;
    for (uint32_t i = 0; i < frames; ++i) {
        m->tonal.set(bins[i]);
        renderFrame(*m, nullptr, output + i);
    }
    return true;
}
uint32_t ll_mixer_active_voices(const LLMixer *m) {
    uint32_t result = 0;
    if (m)
        for (const auto &voice : m->voices)
            result += voice.active;
    return result;
}
uint32_t ll_mixer_steals(const LLMixer *m) {
    return m ? m->steals : 0;
}
uint32_t ll_mixer_dropped_events(const LLMixer *m) {
    return m ? m->dropped : 0;
}
uint64_t ll_mixer_position(const LLMixer *m) {
    return m ? m->position : 0;
}
uint64_t ll_mixer_origin(const LLMixer *m) {
    return m ? m->origin : 0;
}
uint32_t ll_mixer_sample_bytes(const LLMixer *m) {
    return m ? m->visibleSampleBytes.load(std::memory_order_acquire) : 0;
}
uint32_t ll_mixer_required_voice_slots(const LLMixer *m) {
    return m ? m->requiredVoiceSlots.load(std::memory_order_relaxed) : 0;
}

uint32_t ll_mixer_local_position(const LLMixer *m) {
    return m ? static_cast<uint32_t>(m->position - m->origin) : 0;
}
uint32_t ll_mixer_outro_start(const LLMixer *m) {
    if (!m || !m->buses.fades.configured)
        return 0;
    const double start = m->buses.fades.points.tonal_out_start_frame;
    return start >= m->origin && start - m->origin <= UINT32_MAX && std::floor(start) == start
               ? static_cast<uint32_t>(start - m->origin)
               : 0;
}
LLMixerAdvance *ll_mixer_prepare_advance(const LLMixer *m, uint32_t boundary, uint16_t pivot,
                                         LLSongAdvance &result) {
    lowlight::FloatingPointMode mode;
    if (!m || !m->loaded || m->advance || boundary < 3520 || !pivot || pivot > 0xfff)
        return nullptr;
    const uint32_t outro = ll_mixer_outro_start(m);
    if (boundary >= outro)
        return nullptr;
    auto *patch = new (std::nothrow) LLMixerAdvance;
    if (!patch)
        return nullptr;
    patch->boundary = m->origin + boundary;
    patch->deadline = patch->boundary - 3520;
    const auto delta = outro - boundary;
    auto fades = m->buses.fades.points;
    fades.tonal_out_start_frame -= delta;
    fades.tonal_out_end_frame -= delta;
    fades.rhythm_out_frame -= delta;
    if (fades.tonal_out_start_frame < fades.tonal_in_end_frame || !patch->fades.configure(fades)) {
        delete patch;
        return nullptr;
    }
    for (uint32_t i = 0; i < 3520; ++i) {
        const double cosine = std::cos((pi / 2) * i / 3519);
        patch->damping[i] = i == 3519 ? 0.f : static_cast<float>(cosine * cosine);
    }
    // The loaded rack keeps its reserved bass slot even if the edited future has no bass.
    bool bass = m->sharedVoices < LL_VOICE_LIMIT;
    for (uint32_t i = 0; i < m->eventCount; ++i) {
        auto event = m->events[i];
        if (event.note.start_frame < patch->deadline) {
            event.cut = event.note.instrument < 2 && !(pivot & (1u << (event.note.midi % 12)));
            ++patch->prefix;
        } else if (event.note.start_frame >= m->origin + outro) {
            event.note.start_frame -= delta;
        } else
            continue;
        patch->events[patch->count++] = event;
        bass |= event.note.instrument == 2;
    }
    uint32_t peak = 0;
    for (uint32_t i = 0; i < patch->count; ++i) {
        const auto &current = patch->events[i];
        if (current.note.instrument == 2 || current.gain == 0)
            continue;
        uint32_t active = 1;
        for (uint32_t j = 0; j < i; ++j) {
            const auto &prior = patch->events[j];
            const auto end = prior.cut
                                 ? std::min(prior.note.start_frame + prior.frames, patch->boundary)
                                 : prior.note.start_frame + prior.frames;
            if (prior.note.instrument != 2 && prior.gain != 0 && end > current.note.start_frame)
                ++active;
        }
        peak = std::max(peak, active);
    }
    patch->slots = peak + (bass ? 1u : 0u);
    patch->sharedVoices = bass ? LL_VOICE_LIMIT - 1 : LL_VOICE_LIMIT;
    result.fades = fades;
    result.deadline = boundary - 3520;
    result.boundary = boundary;
    result.delta = delta;
    result.voiceSlots = patch->slots;
    return patch;
}
void ll_mixer_destroy_advance(LLMixerAdvance *patch) {
    delete patch;
}
bool ll_mixer_can_advance(const LLMixer *m, const LLMixerAdvance *patch) {
    return m && patch && !m->advance && m->position <= patch->deadline && m->next <= patch->prefix;
}
void ll_mixer_apply_advance(LLMixer *m, const LLMixerAdvance *patch) {
    m->events = patch->events;
    m->eventCount = patch->count;
    m->advance = patch;
    m->buses.fades = patch->fades;
    m->sharedVoices = patch->sharedVoices;
    m->requiredVoiceSlots.store(patch->slots, std::memory_order_relaxed);
    if (patch->sampleBytes)
        m->visibleSampleBytes.store(patch->sampleBytes, std::memory_order_release);
}

struct LLMixerChangeSamples {
    LLMixer *owner;
    Sample samples[LL_SAMPLE_LIMIT]{};
    uint32_t count = 0, floats;
    explicit LLMixerChangeSamples(LLMixer *m) : owner(m), floats(m->floatsUsed) {}
};
LLMixerChangeSamples *ll_mixer_begin_change(LLMixer *m) {
    if (!m || !m->loaded || m->advance)
        return nullptr;
    return new (std::nothrow) LLMixerChangeSamples(m);
}
void ll_mixer_destroy_change_samples(LLMixerChangeSamples *samples) {
    delete samples;
}
int32_t ll_mixer_change_add_sample(LLMixerChangeSamples *builder, const LLSongChangeSample &sample,
                                   uint32_t tonalKey) {
    lowlight::FloatingPointMode mode;
    if (!builder || builder->count == LL_SAMPLE_LIMIT)
        return -1;
    auto *m = builder->owner;
    Sample prepared;
    if (sample.original_sample >= 0) {
        if (static_cast<uint32_t>(sample.original_sample) >= m->samplesUsed || sample.pcm ||
            sample.frames || sample.channels)
            return -1;
        prepared = m->samples[sample.original_sample];
    } else {
        if ((tonalKey != lowlight::tonalKeys &&
             (!m->tonal.table || !lowlight::tonalFormat(tonalKey, sample.channels))) ||
            sample.original_sample != -1 || !sample.pcm || !sample.frames ||
            sample.frames > sampleFramesLimit || (sample.channels != 1 && sample.channels != 2))
            return -1;
        const uint32_t count = sample.frames * sample.channels;
        if (count > LL_SAMPLE_BYTES / sizeof(float) - builder->floats)
            return -1;
        const auto input = reinterpret_cast<uintptr_t>(sample.pcm);
        const auto arena = reinterpret_cast<uintptr_t>(m->pcm);
        if (input <= arena ? arena - input < uint64_t{count} * sizeof(float)
                           : input - arena < LL_SAMPLE_BYTES)
            return -1;
        for (uint32_t i = 0; i < count; ++i)
            if (!std::isfinite(sample.pcm[i]) || std::abs(sample.pcm[i]) > 8)
                return -1;
        prepared = {builder->floats, sample.frames, sample.channels, tonalKey};
        for (uint32_t i = 0; i < count; ++i)
            m->pcm[builder->floats + i] =
                tonalKey == lowlight::tonalKeys ? normal(sample.pcm[i]) : sample.pcm[i];
        builder->floats += count;
    }
    builder->samples[builder->count] = prepared;
    return static_cast<int32_t>(builder->count++);
}

LLMixerAdvance *ll_mixer_prepare_change(LLMixer *m, const LLSongChangeScore &score,
                                        const LLMixerChangeSamples *builder,
                                        LLSongAdvance &result) {
    lowlight::FloatingPointMode mode;
    if (!m || !builder || builder->owner != m || !m->loaded || m->advance ||
        score.boundary_frames < 3520 || score.boundary_frames > ll_mixer_outro_start(m) ||
        !score.pivot_pitch_classes || score.pivot_pitch_classes > 0xfff ||
        score.event_count > LL_EVENT_LIMIT || score.sample_count || score.samples ||
        (score.event_count && !score.events) || !score.input_frames ||
        m->origin > timelineLimit - score.input_frames)
        return nullptr;
    const auto boundary = m->origin + score.boundary_frames;
    const auto &oldFades = m->buses.fades.points;
    lowlight::RackFades fades;
    if (score.fades.tonal_in_start_frame != oldFades.tonal_in_start_frame ||
        score.fades.tonal_in_end_frame != oldFades.tonal_in_end_frame ||
        score.fades.rhythm_in_frame != oldFades.rhythm_in_frame ||
        score.fades.tonal_out_start_frame != boundary ||
        score.fades.tonal_out_end_frame > m->origin + score.input_frames ||
        score.fades.rhythm_out_frame < boundary || !fades.configure(score.fades))
        return nullptr;
    const auto *samples = builder->samples;
    const auto sampleCount = builder->count;
    auto *patch = new (std::nothrow) LLMixerAdvance;
    if (!patch)
        return nullptr;
    patch->boundary = boundary;
    patch->deadline = boundary - 3520;
    patch->fades = fades;
    patch->sampleBytes = builder->floats * sizeof(float);
    for (uint32_t i = 0; i < 3520; ++i) {
        const double cosine = std::cos((pi / 2) * i / 3519);
        patch->damping[i] = i == 3519 ? 0.f : static_cast<float>(cosine * cosine);
    }
    // Keep every prefix index, including pending steals, stable across publication.
    for (uint32_t i = 0; i < m->eventCount && m->events[i].note.start_frame < patch->deadline;
         ++i) {
        auto event = m->events[i];
        event.cut = event.note.instrument < 2 &&
                    !(score.pivot_pitch_classes & (1u << (event.note.midi % 12)));
        patch->events[patch->count++] = event;
    }
    patch->prefix = patch->count;
    if (score.event_count > LL_EVENT_LIMIT - patch->count) {
        delete patch;
        return nullptr;
    }
    bool bass = m->sharedVoices < LL_VOICE_LIMIT;
    for (uint32_t i = 0; i < score.event_count; ++i) {
        const auto &e = score.events[i];
        const bool isBass = e.instrument == 2, percussion = e.instrument >= 3;
        if (e.sample_index >= sampleCount || !samples[e.sample_index].matches(e) ||
            e.start_frame < boundary || e.start_frame >= m->origin + score.input_frames ||
            (i && e.start_frame < score.events[i - 1].start_frame) || !e.hold_frames ||
            e.hold_frames > 16 * 32000 || e.release_frames > 5 * 32000 ||
            !lowlight::unitInterval(e.velocity) || !std::isfinite(e.pan) || e.pan < -1 ||
            e.pan > 1 || e.instrument > 6 || e.connected > 1 || e.priority > 2 ||
            (e.instrument < 2 && !(score.pivot_pitch_classes & (1u << (e.midi % 12)))) ||
            (isBass && (e.midi < 31 || e.midi > 57 || samples[e.sample_index].channels != 1)) ||
            (percussion && (e.priority || e.midi != (e.instrument == 4 ? 1 : 0) ||
                            samples[e.sample_index].channels != 1))) {
            delete patch;
            return nullptr;
        }
        const uint32_t lifetime =
            isBass ? e.hold_frames + e.release_frames
                   : (percussion ? samples[e.sample_index].frames : sampleFramesLimit);
        if (e.start_frame > timelineLimit - lifetime) {
            delete patch;
            return nullptr;
        }
        configureEvent(patch->events[patch->count++], e, samples[e.sample_index]);
        bass |= isBass;
    }
    uint32_t peak = 0;
    for (uint32_t i = 0; i < patch->count; ++i) {
        const auto &current = patch->events[i];
        if (current.note.instrument == 2 || current.gain == 0)
            continue;
        uint32_t active = 1;
        for (uint32_t j = 0; j < i; ++j) {
            const auto &prior = patch->events[j];
            const auto end = prior.cut
                                 ? std::min(prior.note.start_frame + prior.frames, patch->boundary)
                                 : prior.note.start_frame + prior.frames;
            if (prior.note.instrument != 2 && prior.gain != 0 && end > current.note.start_frame)
                ++active;
        }
        peak = std::max(peak, active);
    }
    patch->slots = peak + (bass ? 1u : 0u);
    patch->sharedVoices = bass ? LL_VOICE_LIMIT - 1 : LL_VOICE_LIMIT;
    if (patch->slots > LL_VOICE_LIMIT) {
        delete patch;
        return nullptr;
    }
    result.fades = score.fades;
    result.deadline = score.boundary_frames - 3520;
    result.boundary = score.boundary_frames;
    result.frames = score.input_frames;
    result.delta = ll_mixer_outro_start(m) - score.boundary_frames;
    result.voiceSlots = patch->slots;
    result.sampleBytes = patch->sampleBytes;
    return patch;
}
uint32_t ll_mixer_change_sample_bytes(const LLMixerAdvance *patch) {
    return patch ? patch->sampleBytes : 0;
}

// A baked tonal sample still renders through the finite compatibility API. It cannot
// follow a live Warmth target, so check each new score before its rack is published.
static bool supportsEffects(const Event *events, uint32_t count) {
    return std::all_of(events, events + count, [](const Event &event) {
        return event.note.instrument >= 2 || event.sample.tonalKey != lowlight::tonalKeys;
    });
}
bool ll_mixer_supports_effects(const LLMixer *mixer) {
    return mixer && mixer->loaded && mixer->buses.configured && mixer->tonal.table &&
           supportsEffects(mixer->events, mixer->eventCount);
}
bool ll_mixer_advance_supports_effects(const LLMixerAdvance *patch) {
    return patch && supportsEffects(patch->events, patch->count);
}
