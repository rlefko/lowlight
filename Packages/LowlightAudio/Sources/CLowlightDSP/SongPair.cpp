// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
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

struct LLSongPair {
    LLSongReplay *songs[2]{};
    LLPeakProtector *peak = nullptr;
    uint32_t origins[2]{}, lengths[2]{}, frames = 0, input = 0, position = 0, startup = LL_PEAK_LATENCY;
    bool faulted = false;
    float piece[2 * blockFrames]{}, sum[2 * blockFrames]{}, delayed[2 * blockFrames]{};

    bool mix(uint32_t count) {
        clear(sum, count);
        for (uint32_t song = 0; song < 2; ++song) {
            const uint64_t start = std::max(uint64_t{input}, uint64_t{origins[song]});
            const uint64_t end = std::min(uint64_t{input} + count, uint64_t{origins[song]} + lengths[song]);
            if (start >= end) continue;
            const auto amount = static_cast<uint32_t>(end - start);
            uint32_t received = 0;
            if (!ll_song_replay_render(songs[song], piece, amount, &received) || received != amount) return false;
            for (uint32_t i = 0; i < 2 * amount; ++i) sum[2 * (start - input) + i] += piece[i];
        }
        for (uint32_t i = 0; i < count; ++i) {
            const double frame = double(input) + i;
            const double entry = std::min(1.0, frame / (.4 * 32000));
            const double exit = std::clamp((double(frames) - frame) / (2.8 * 32000), 0.0, 1.0);
            for (uint32_t ch = 0; ch < 2; ++ch) {
                sum[2 * i + ch] = float(double(sum[2 * i + ch]) * entry);
                sum[2 * i + ch] = float(double(sum[2 * i + ch]) * exit);
            }
        }
        return ll_peak_process(peak, sum, delayed, count);
    }
};

LLSongPair *ll_song_pair_create(LLSongReplay *first, LLSongReplay *second, uint32_t frameCount) {
    lowlight::FloatingPointMode mode;
    if (!first || !second || first == second || ll_song_replay_faulted(first) || ll_song_replay_faulted(second) ||
        ll_song_replay_position(first) || ll_song_replay_position(second) || ll_song_replay_origin(first)) return nullptr;
    const auto origin = ll_song_replay_origin(second);
    const auto firstFrames = ll_song_replay_frames(first), secondFrames = ll_song_replay_frames(second);
    if (!origin || origin >= firstFrames || frameCount <= origin || uint64_t{frameCount} > origin + secondFrames ||
        uint64_t{ll_song_replay_required_voice_slots(first)} + ll_song_replay_required_voice_slots(second) > LL_VOICE_LIMIT)
        return nullptr;
    auto *pair = new (std::nothrow) LLSongPair;
    if (!pair) return nullptr;
    pair->songs[0] = first; pair->songs[1] = second;
    pair->origins[1] = static_cast<uint32_t>(origin);
    pair->lengths[0] = firstFrames; pair->lengths[1] = secondFrames; pair->frames = frameCount;
    pair->peak = ll_peak_create(LL_PEAK_SESSION);
    if (!pair->peak) { delete pair; return nullptr; }
    return pair;
}
void ll_song_pair_destroy(LLSongPair *pair) {
    if (!pair) return;
    ll_peak_destroy(pair->peak); delete pair;
}
void ll_song_pair_reset(LLSongPair *pair) {
    if (!pair) return;
    lowlight::FloatingPointMode mode;
    for (auto *song : pair->songs) ll_song_replay_reset(song);
    ll_peak_reset(pair->peak);
    pair->input = pair->position = 0; pair->startup = LL_PEAK_LATENCY; pair->faulted = false;
}
bool ll_song_pair_render(LLSongPair *pair, float *output, uint32_t capacity, uint32_t *written) {
    lowlight::FloatingPointMode mode;
    if (overlaps(output, capacity, written)) { clear(output, capacity); return false; }
    if (written) *written = 0;
    clear(output, capacity);
    if (!pair || !written || (capacity && !output) || pair->faulted) return false;
    const uint32_t requested = std::min(capacity, pair->frames - pair->position);
    uint32_t produced = 0;
    while (produced < requested) {
        uint32_t physical = static_cast<uint32_t>(std::min(uint64_t{blockFrames}, uint64_t{requested - produced} + pair->startup));
        bool success;
        if (pair->input < pair->frames) {
            physical = std::min(physical, pair->frames - pair->input);
            success = pair->mix(physical);
            if (success) pair->input += physical;
        } else {
            uint32_t drained = 0;
            success = ll_peak_drain(pair->peak, pair->delayed, physical, &drained) && drained <= physical;
            physical = drained;
        }
        if (!success || !physical) { pair->faulted = true; clear(output, capacity); return false; }
        const uint32_t skipped = std::min(pair->startup, physical);
        pair->startup -= skipped;
        const uint32_t count = physical - skipped;
        std::copy_n(pair->delayed + 2 * skipped, 2 * count, output + uint64_t{produced} * 2);
        produced += count;
    }
    pair->position += produced; *written = produced;
    return true;
}
uint32_t ll_song_pair_position(const LLSongPair *pair) { return pair ? pair->position : 0; }
uint32_t ll_song_pair_frames(const LLSongPair *pair) { return pair ? pair->frames : 0; }
bool ll_song_pair_faulted(const LLSongPair *pair) { return !pair || pair->faulted; }
