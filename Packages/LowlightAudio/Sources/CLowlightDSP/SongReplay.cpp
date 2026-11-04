// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include <algorithm>
#include <new>

namespace {
constexpr uint32_t blockFrames = 256;
void clear(float *output, uint32_t frames) {
    if (output)
        for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
            output[i] = 0;
}
bool overlaps(float *output, uint32_t capacity, uint32_t *written) {
    if (!capacity || !output || !written)
        return false;
    const auto a = reinterpret_cast<uintptr_t>(output), b = reinterpret_cast<uintptr_t>(written);
    return a <= b ? b - a < uint64_t{capacity} * 2 * sizeof(float) : a - b < sizeof(*written);
}
}

struct LLSongReplay {
    LLSongSource *source = nullptr;
    LLSongGain *gain = nullptr;
    LLPeakProtector *peak = nullptr;
    uint32_t frames = 0, input = 0, position = 0, startup = LL_PEAK_LATENCY;
    bool faulted = false;
    float dry[2 * blockFrames]{}, gained[2 * blockFrames]{}, delayed[2 * blockFrames]{};
};

LLSongReplay *ll_song_replay_create(LLSongSource *source, double bodyLUFS) {
    lowlight::FloatingPointMode mode;
    if (!source || !ll_song_source_frames(source) || ll_song_source_position(source) ||
        ll_song_source_faulted(source))
        return nullptr;
    auto *gain = ll_song_gain_create(bodyLUFS);
    if (!gain)
        return nullptr;
    auto *replay = new (std::nothrow) LLSongReplay;
    if (!replay) {
        ll_song_gain_destroy(gain);
        return nullptr;
    }
    replay->source = source;
    replay->gain = gain;
    replay->frames = ll_song_source_frames(source);
    replay->peak = ll_peak_create(LL_PEAK_SONG);
    if (!replay->peak) {
        ll_song_replay_destroy(replay);
        return nullptr;
    }
    return replay;
}
void ll_song_replay_destroy(LLSongReplay *replay) {
    if (!replay)
        return;
    ll_song_gain_destroy(replay->gain);
    ll_peak_destroy(replay->peak);
    delete replay;
}
void ll_song_replay_reset(LLSongReplay *replay) {
    if (!replay)
        return;
    lowlight::FloatingPointMode mode;
    ll_song_source_reset(replay->source);
    ll_peak_reset(replay->peak);
    replay->input = replay->position = 0;
    replay->startup = LL_PEAK_LATENCY;
    replay->faulted = false;
}
bool ll_song_replay_gain(const LLSongReplay *replay, LLSongGainValues *values) {
    return ll_song_gain_get(replay ? replay->gain : nullptr, values);
}
bool ll_song_replay_render(LLSongReplay *replay, float *output, uint32_t capacity,
                           uint32_t *written) {
    lowlight::FloatingPointMode mode;
    if (overlaps(output, capacity, written)) {
        clear(output, capacity);
        return false;
    }
    if (written)
        *written = 0;
    clear(output, capacity);
    if (!replay || !written || (capacity && !output) || replay->faulted)
        return false;
    const uint32_t requested = std::min(capacity, replay->frames - replay->position);
    uint32_t produced = 0;
    while (produced < requested) {
        uint32_t physical = std::min(blockFrames, requested - produced + replay->startup);
        bool success;
        if (replay->input < replay->frames) {
            physical = std::min(physical, replay->frames - replay->input);
            uint32_t received = 0;
            success = ll_song_source_render(replay->source, replay->dry, physical, &received) &&
                      received == physical &&
                      ll_song_gain_process(replay->gain, replay->dry, replay->gained, physical) &&
                      ll_peak_process(replay->peak, replay->gained, replay->delayed, physical);
            if (success)
                replay->input += physical;
        } else {
            uint32_t drained = 0;
            success = ll_peak_drain(replay->peak, replay->delayed, physical, &drained) &&
                      drained <= physical;
            physical = drained;
        }
        if (!success || !physical) {
            replay->faulted = true;
            clear(output, capacity);
            return false;
        }
        const uint32_t skipped = std::min(replay->startup, physical);
        replay->startup -= skipped;
        const uint32_t count = physical - skipped;
        std::copy_n(replay->delayed + 2 * skipped, 2 * count, output + uint64_t{produced} * 2);
        produced += count;
    }
    replay->position += produced;
    *written = produced;
    return true;
}
uint32_t ll_song_replay_position(const LLSongReplay *replay) {
    return replay ? replay->position : 0;
}
uint32_t ll_song_replay_frames(const LLSongReplay *replay) {
    return replay ? replay->frames : 0;
}
uint64_t ll_song_replay_origin(const LLSongReplay *replay) {
    return replay ? ll_song_source_origin(replay->source) : 0;
}
uint32_t ll_song_replay_required_voice_slots(const LLSongReplay *replay) {
    return replay ? ll_song_source_required_voice_slots(replay->source) : 0;
}
bool ll_song_replay_faulted(const LLSongReplay *replay) {
    return !replay || replay->faulted;
}
