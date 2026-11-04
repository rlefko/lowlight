// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include <algorithm>
#include <atomic>
#include <new>

namespace {
constexpr uint32_t blockFrames = 256;
static_assert(std::atomic<uint32_t>::is_always_lock_free);
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

struct LLSongPair {
    LLSongReplay *songs[2]{};
    LLPeakProtector *peak = nullptr;
    uint32_t origins[2]{}, lengths[2]{}, frames = 0, input = 0, position = 0,
                                         startup = LL_PEAK_LATENCY;
    uint32_t nextOrigin = 0;
    bool faulted = false, rolling = false, streaming = false;
    enum Phase : uint32_t { active, requested, preparing, ready };
    std::atomic<uint32_t> phase{active}, visiblePosition{0}, visibleFault{0};
    // Written before requested; immutable until the worker publishes ready.
    struct Request {
        LLSongReplay *retired = nullptr, *survivor = nullptr;
        uint64_t survivorEnd = 0;
        uint32_t origin = 0, voiceSlots = 0;
    } request;
    // Written by the worker before ready; read only after consumer acquire.
    LLSongReplay *replacement = nullptr;
    uint32_t followingOrigin = 0;
    float piece[2 * blockFrames]{}, sum[2 * blockFrames]{}, delayed[2 * blockFrames]{};

    bool needsPreparation() const {
        if (streaming) {
            const auto value = phase.load(std::memory_order_acquire);
            return !visibleFault.load(std::memory_order_acquire) &&
                   (value == requested || value == preparing);
        }
        return rolling && !faulted && nextOrigin < frames &&
               (!songs[1] || uint64_t{input} >= uint64_t{origins[0]} + lengths[0]);
    }
    void handoff() {
        if (phase.load(std::memory_order_acquire) == ready) {
            songs[1] = replacement;
            origins[1] = request.origin;
            lengths[1] = ll_song_replay_frames(replacement);
            nextOrigin = followingOrigin;
            phase.store(active, std::memory_order_release);
        }
        if (songs[1] && nextOrigin < frames &&
            uint64_t{input} >= uint64_t{origins[0]} + lengths[0]) {
            request = {songs[0], songs[1], uint64_t{origins[1]} + lengths[1], nextOrigin,
                       ll_song_replay_required_voice_slots(songs[1])};
            songs[0] = songs[1];
            songs[1] = nullptr;
            origins[0] = origins[1];
            lengths[0] = lengths[1];
            origins[1] = lengths[1] = 0;
            phase.store(requested, std::memory_order_release);
        }
    }
    bool mix(uint32_t count) {
        clear(sum, count);
        for (uint32_t song = 0; song < 2; ++song) {
            const uint64_t start = std::max(uint64_t{input}, uint64_t{origins[song]});
            const uint64_t end =
                std::min(uint64_t{input} + count, uint64_t{origins[song]} + lengths[song]);
            if (start >= end)
                continue;
            const auto amount = static_cast<uint32_t>(end - start);
            uint32_t received = 0;
            if (!ll_song_replay_render(songs[song], piece, amount, &received) || received != amount)
                return false;
            for (uint32_t i = 0; i < 2 * amount; ++i)
                sum[2 * (start - input) + i] += piece[i];
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

static LLSongPair *create(LLSongReplay *first, LLSongReplay *second, uint32_t frameCount,
                          uint32_t nextOrigin, bool rolling) {
    lowlight::FloatingPointMode mode;
    if (!first || !second || first == second || ll_song_replay_faulted(first) ||
        ll_song_replay_faulted(second) || ll_song_replay_position(first) ||
        ll_song_replay_position(second) || ll_song_replay_origin(first))
        return nullptr;
    const auto origin = ll_song_replay_origin(second);
    const auto firstFrames = ll_song_replay_frames(first),
               secondFrames = ll_song_replay_frames(second);
    if (!origin || origin >= firstFrames || nextOrigin <= origin || nextOrigin > frameCount ||
        uint64_t{nextOrigin} > origin + secondFrames ||
        (nextOrigin < frameCount &&
         (firstFrames > nextOrigin || uint64_t{nextOrigin} == origin + secondFrames)) ||
        uint64_t{ll_song_replay_required_voice_slots(first)} +
                ll_song_replay_required_voice_slots(second) >
            LL_VOICE_LIMIT)
        return nullptr;
    auto *pair = new (std::nothrow) LLSongPair;
    if (!pair)
        return nullptr;
    pair->songs[0] = first;
    pair->songs[1] = second;
    pair->origins[1] = static_cast<uint32_t>(origin);
    pair->lengths[0] = firstFrames;
    pair->lengths[1] = secondFrames;
    pair->frames = frameCount;
    pair->nextOrigin = nextOrigin;
    pair->rolling = rolling;
    pair->peak = ll_peak_create(LL_PEAK_SESSION);
    if (!pair->peak) {
        delete pair;
        return nullptr;
    }
    return pair;
}
LLSongPair *ll_song_pair_create(LLSongReplay *first, LLSongReplay *second, uint32_t frameCount) {
    return create(first, second, frameCount, frameCount, false);
}
LLSongPair *ll_song_pair_create_rolling(LLSongReplay *first, LLSongReplay *second,
                                        uint32_t frameCount, uint32_t nextOrigin) {
    return create(first, second, frameCount, nextOrigin, true);
}
LLSongPair *ll_song_pair_create_streaming(LLSongReplay *first, LLSongReplay *second,
                                          uint32_t frameCount, uint32_t nextOrigin) {
    auto *pair = create(first, second, frameCount, nextOrigin, true);
    if (pair)
        pair->streaming = true;
    return pair;
}
bool ll_song_pair_claim_retired(LLSongPair *pair, LLSongReplay **retired) {
    if (retired)
        *retired = nullptr;
    if (!pair || !pair->streaming || !retired || pair->visibleFault.load(std::memory_order_acquire))
        return false;
    uint32_t expected = LLSongPair::requested;
    if (!pair->phase.compare_exchange_strong(expected, LLSongPair::preparing,
                                             std::memory_order_acquire))
        return false;
    *retired = pair->request.retired;
    return true;
}
bool ll_song_pair_publish(LLSongPair *pair, LLSongReplay *next, uint32_t nextOrigin) {
    if (!pair || !pair->streaming ||
        pair->phase.load(std::memory_order_acquire) != LLSongPair::preparing ||
        pair->visibleFault.load(std::memory_order_acquire) || !next ||
        next == pair->request.survivor)
        return false;
    // Never inspect the concurrently rendered survivor or live input clock.
    const auto origin = ll_song_replay_origin(next), end = origin + ll_song_replay_frames(next);
    if (ll_song_replay_position(next) || ll_song_replay_faulted(next) ||
        origin != pair->request.origin || origin >= pair->request.survivorEnd ||
        nextOrigin <= origin || nextOrigin > pair->frames || nextOrigin > end ||
        (nextOrigin < pair->frames &&
         (pair->request.survivorEnd > nextOrigin || nextOrigin == end)) ||
        uint64_t{pair->request.voiceSlots} + ll_song_replay_required_voice_slots(next) >
            LL_VOICE_LIMIT)
        return false;
    pair->replacement = next;
    pair->followingOrigin = nextOrigin;
    pair->phase.store(LLSongPair::ready, std::memory_order_release);
    return true;
}
bool ll_song_pair_needs_preparation(const LLSongPair *pair) {
    return pair && pair->needsPreparation();
}
bool ll_song_pair_retire_first(LLSongPair *pair) {
    if (!pair || pair->streaming || !pair->needsPreparation() || !pair->songs[1] ||
        ll_song_replay_position(pair->songs[0]) != pair->lengths[0])
        return false;
    pair->songs[0] = pair->songs[1];
    pair->songs[1] = nullptr;
    pair->origins[0] = pair->origins[1];
    pair->lengths[0] = pair->lengths[1];
    pair->origins[1] = pair->lengths[1] = 0;
    return true;
}
bool ll_song_pair_append(LLSongPair *pair, LLSongReplay *next, uint32_t nextOrigin) {
    if (!pair || pair->streaming || !pair->needsPreparation() || pair->songs[1] || !next ||
        next == pair->songs[0] || ll_song_replay_position(next) || ll_song_replay_faulted(next))
        return false;
    const auto origin = ll_song_replay_origin(next);
    const auto length = ll_song_replay_frames(next);
    const uint64_t oldEnd = uint64_t{pair->origins[0]} + pair->lengths[0];
    if (origin != pair->nextOrigin || origin < pair->input || origin >= oldEnd ||
        nextOrigin <= origin || nextOrigin > pair->frames ||
        uint64_t{nextOrigin} > origin + length ||
        (nextOrigin < pair->frames &&
         (oldEnd > nextOrigin || uint64_t{nextOrigin} == origin + length)) ||
        uint64_t{ll_song_replay_required_voice_slots(pair->songs[0])} +
                ll_song_replay_required_voice_slots(next) >
            LL_VOICE_LIMIT)
        return false;
    pair->songs[1] = next;
    pair->origins[1] = static_cast<uint32_t>(origin);
    pair->lengths[1] = length;
    pair->nextOrigin = nextOrigin;
    return true;
}
void ll_song_pair_destroy(LLSongPair *pair) {
    if (!pair)
        return;
    ll_peak_destroy(pair->peak);
    delete pair;
}
void ll_song_pair_reset(LLSongPair *pair) {
    if (!pair || pair->rolling)
        return;
    lowlight::FloatingPointMode mode;
    for (auto *song : pair->songs)
        ll_song_replay_reset(song);
    ll_peak_reset(pair->peak);
    pair->input = pair->position = 0;
    pair->startup = LL_PEAK_LATENCY;
    pair->faulted = false;
}
bool ll_song_pair_render(LLSongPair *pair, float *output, uint32_t capacity, uint32_t *written) {
    lowlight::FloatingPointMode mode;
    if (overlaps(output, capacity, written)) {
        clear(output, capacity);
        return false;
    }
    if (written)
        *written = 0;
    clear(output, capacity);
    if (!pair || !written || (capacity && !output) || pair->faulted)
        return false;
    const uint32_t requested = std::min(capacity, pair->frames - pair->position);
    uint32_t produced = 0;
    while (produced < requested) {
        if (pair->streaming) {
            pair->handoff();
            if (!pair->songs[1] && pair->input == pair->nextOrigin)
                break;
        } else if (pair->needsPreparation())
            break;
        uint32_t physical = static_cast<uint32_t>(
            std::min(uint64_t{blockFrames}, uint64_t{requested - produced} + pair->startup));
        bool success;
        if (pair->input < pair->frames) {
            physical = std::min(physical, pair->frames - pair->input);
            if (pair->rolling && pair->nextOrigin < pair->frames) {
                const uint64_t stop = pair->songs[1] ? uint64_t{pair->origins[0]} + pair->lengths[0]
                                                     : pair->nextOrigin;
                physical = static_cast<uint32_t>(std::min(uint64_t{physical}, stop - pair->input));
            }
            success = pair->mix(physical);
            if (success)
                pair->input += physical;
        } else {
            uint32_t drained = 0;
            success =
                ll_peak_drain(pair->peak, pair->delayed, physical, &drained) && drained <= physical;
            physical = drained;
        }
        if (!success || !physical) {
            pair->faulted = true;
            if (pair->streaming)
                pair->visibleFault.store(1, std::memory_order_release);
            clear(output, capacity);
            return false;
        }
        const uint32_t skipped = std::min(pair->startup, physical);
        pair->startup -= skipped;
        const uint32_t count = physical - skipped;
        std::copy_n(pair->delayed + 2 * skipped, 2 * count, output + uint64_t{produced} * 2);
        produced += count;
        if (pair->streaming)
            pair->handoff();
    }
    pair->position += produced;
    *written = produced;
    if (pair->streaming)
        pair->visiblePosition.store(pair->position, std::memory_order_release);
    return true;
}
uint32_t ll_song_pair_position(const LLSongPair *pair) {
    return pair ? (pair->streaming ? pair->visiblePosition.load(std::memory_order_acquire)
                                   : pair->position)
                : 0;
}
uint32_t ll_song_pair_frames(const LLSongPair *pair) {
    return pair ? pair->frames : 0;
}
bool ll_song_pair_faulted(const LLSongPair *pair) {
    return !pair || (pair->streaming ? pair->visibleFault.load(std::memory_order_acquire) != 0
                                     : pair->faulted);
}
