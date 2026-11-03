// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include "RackFades.h"
#include <algorithm>
#include <new>

namespace {
constexpr uint32_t blockFrames = 256;
void clear(float *output, uint32_t frames) {
    if (output) for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) output[i] = 0;
}
bool overlaps(float *output, uint32_t capacity, uint32_t *written) {
    if (!capacity || !output || !written) return false;
    const auto a = reinterpret_cast<uintptr_t>(output), b = reinterpret_cast<uintptr_t>(written);
    return a <= b ? b - a < uint64_t{capacity} * 2 * sizeof(float) : a - b < sizeof(*written);
}
}

struct LLSongSource {
    LLMixer *mixer = nullptr;
    LLGlue *glue = nullptr;
    LLRoom *room = nullptr;
    LLSongMix *mix = nullptr;
    uint32_t frames = 0, input = 0, position = 0, startup = LL_GLUE_LATENCY;
    bool faulted = false;
    LLBusFrame buses[blockFrames]{};
    LLGlueFrame delayed[blockFrames]{}, wet[blockFrames]{};
};

LLSongSource *ll_song_source_create(LLMixer *mixer, const LLSongSourceConfig *config) {
    lowlight::FloatingPointMode mode;
    lowlight::RackFades fades;
    if (!mixer || !config || config->input_frames == 0 || config->input_frames > LL_AIR_MAX_FRAMES ||
        config->frame_origin > lowlight::frameLimit - config->input_frames || config->take_seed >= (uint32_t{1} << 31) ||
        config->focus > 1 || !lowlight::unitInterval(config->space) || !lowlight::unitInterval(config->warmth) ||
        !lowlight::unitInterval(config->texture) || !fades.configure(config->rack_fades) ||
        ll_mixer_origin(mixer) != config->frame_origin || ll_mixer_position(mixer) != config->frame_origin ||
        !ll_mixer_render_buses(mixer, nullptr, 0)) return nullptr;
    auto *source = new (std::nothrow) LLSongSource;
    if (!source) return nullptr;
    source->mixer = mixer; source->frames = config->input_frames;
    source->glue = ll_glue_create(config->input_frames, config->focus);
    source->room = ll_room_create(config->space, config->warmth);
    source->mix = ll_song_mix_create(config->take_seed, config->input_frames, config->frame_origin,
                                    config->texture, &config->rack_fades);
    if (!source->glue || !source->room || !source->mix) { ll_song_source_destroy(source); return nullptr; }
    return source;
}
void ll_song_source_destroy(LLSongSource *source) {
    if (!source) return;
    ll_glue_destroy(source->glue); ll_room_destroy(source->room); ll_song_mix_destroy(source->mix);
    delete source;
}
void ll_song_source_reset(LLSongSource *source) {
    if (!source) return;
    lowlight::FloatingPointMode mode;
    ll_mixer_reset(source->mixer); ll_glue_reset(source->glue);
    ll_room_reset(source->room); ll_song_mix_reset(source->mix);
    source->input = source->position = 0; source->startup = LL_GLUE_LATENCY; source->faulted = false;
}
bool ll_song_source_render(LLSongSource *source, float *output, uint32_t capacity, uint32_t *written) {
    lowlight::FloatingPointMode mode;
    // Reject aliasing before dereferencing written; clearing live Float storage
    // also clears the overlapping bytes without a mismatched typed write.
    if (overlaps(output, capacity, written)) { clear(output, capacity); return false; }
    if (written) *written = 0;
    clear(output, capacity);
    if (!source || !written || (capacity && !output) || source->faulted) return false;
    const uint32_t requested = std::min(capacity, source->frames - source->position);
    uint32_t produced = 0;
    while (produced < requested) {
        // Do not prefetch beyond the requested output plus startup. This avoids
        // an output FIFO and keeps the finite room/air clock exactly aligned.
        uint32_t physical = std::min(blockFrames, requested - produced + source->startup);
        bool success;
        if (source->input < source->frames) {
            physical = std::min(physical, source->frames - source->input);
            success = ll_mixer_render_buses(source->mixer, source->buses, physical) &&
                ll_glue_process(source->glue, source->buses, source->delayed, physical);
            if (success) source->input += physical;
        } else {
            uint32_t drained = 0;
            success = ll_glue_drain(source->glue, source->delayed, physical, &drained);
            physical = drained;
        }
        if (!success || !physical) { source->faulted = true; clear(output, capacity); return false; }
        const uint32_t skipped = std::min(source->startup, physical);
        source->startup -= skipped;
        const uint32_t count = physical - skipped;
        if (count && (!ll_room_process(source->room, source->delayed + skipped, source->wet, count) ||
            !ll_song_mix_process(source->mix, source->wet, output + uint64_t{produced} * 2, count))) {
            source->faulted = true; clear(output, capacity); return false;
        }
        produced += count;
    }
    source->position += produced; *written = produced;
    return true;
}
uint32_t ll_song_source_position(const LLSongSource *source) { return source ? source->position : 0; }
bool ll_song_source_faulted(const LLSongSource *source) { return !source || source->faulted; }
