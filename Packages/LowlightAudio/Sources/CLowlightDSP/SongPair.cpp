// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include "SongAdvance.h"
#include <algorithm>
#include <atomic>
#include <new>

namespace {
constexpr uint32_t blockFrames = 256;
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
constexpr uint64_t frameLimit = uint64_t{1} << 52;
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

struct LLSongRevision {
    std::atomic<uint64_t> value{0};
};
struct LLSongChange {
    LLSongChangeOffer offer{};
    LLMixerChangeSamples *samples = nullptr;
    LLSongAdvance *advance = nullptr;
};

struct LLSongNext {
    LLSongNextOffer offer{};
    LLSongAdvance *advance = nullptr;
};

struct LLSongPair {
    LLSongReplay *songs[2]{};
    LLPeakProtector *peak = nullptr;
    uint64_t origins[2]{}, frames = 0, input = 0, position = 0, entryOrigin = 0;
    uint32_t lengths[2]{}, startup = LL_PEAK_LATENCY, restartFade = 12800;
    uint64_t nextOrigin = 0;
    bool faulted = false, rolling = false, streaming = false, placed = false;
    enum Phase : uint32_t { active, requested, preparing, ready };
    std::atomic<uint32_t> phase{active}, visibleFault{0};
    std::atomic<uint64_t> visiblePosition{0}, listeningPosition{0};
    // Written before requested; immutable until the worker publishes ready.
    struct Request {
        LLSongReplay *retired = nullptr, *survivor = nullptr;
        uint64_t survivorEnd = 0;
        uint64_t origin = 0;
        uint32_t voiceSlots = 0;
    } request;
    // Written by the worker before ready; read only after consumer acquire.
    LLSongReplay *replacement = nullptr;
    uint64_t followingOrigin = 0;
    enum NextPhase : uint32_t {
        nextIdle,
        nextRequested,
        nextOffered,
        nextPreparing,
        nextReady,
        nextAccepted,
        nextRejected,
        nextSatisfied
    };
    std::atomic<uint32_t> nextPhase{nextIdle};
    uint64_t nextTarget = 0, nextGeneration = 0;
    LLSongNextOffer nextOffer{};
    LLSongNextResult nextResult{};
    LLSongNext *nextPatch = nullptr;
    void advanceNext();
    enum ChangePhase : uint32_t {
        changeIdle,
        changeRequested,
        changeOffered,
        changePreparing,
        changeWithdrawReady,
        changeWithdrawn,
        changeBuilding,
        changeReady,
        changeAccepted,
        changeRejected,
        changeDeferred,
        changeRollback,
        changeRestoreReady,
        changeRestored
    };
    std::atomic<uint32_t> changePhase{changeIdle};
    uint64_t changeTarget = 0, changeRevision = 0, changeGeneration = 0;
    const LLSongRevision *changeIntent = nullptr;
    LLSongChangeOffer changeOffer{};
    LLSongChangeResult changeResult{};
    LLSongChange *changePatch = nullptr;
    LLSongReplay *changeReplacement = nullptr;
    uint64_t changeFollowingOrigin = 0;
    bool changeWasWithdrawn = false;
    void advanceChange();
    bool changePinsOwners() const {
        const auto state = changePhase.load(std::memory_order_acquire);
        return state != changeIdle && state != changeRequested && state != changeOffered &&
               state != changeRejected && state != changeDeferred;
    }
    uint64_t waitingOrigin() const {
        return changeWasWithdrawn ? changeOffer.original_origin : nextOrigin;
    }
    float piece[2 * blockFrames]{}, sum[2 * blockFrames]{}, delayed[2 * blockFrames]{};

    bool hasNext() const {
        return !frames || nextOrigin < frames;
    }
    bool needsPreparation() const {
        if (streaming) {
            const auto edit = nextPhase.load(std::memory_order_acquire);
            if (changePinsOwners() || edit == nextPreparing || edit == nextReady ||
                edit == nextAccepted)
                return false;
            const auto value = phase.load(std::memory_order_acquire);
            return !visibleFault.load(std::memory_order_acquire) &&
                   (value == requested || value == preparing);
        }
        return rolling && !faulted && hasNext() &&
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
        if (songs[1] && hasNext() && uint64_t{input} >= uint64_t{origins[0]} + lengths[0]) {
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
            const double entry = std::min(1.0, (frame - double(entryOrigin)) / (.4 * 32000));
            const double exit =
                frames ? std::clamp((double(frames) - frame) / (2.8 * 32000), 0.0, 1.0) : 1;
            for (uint32_t ch = 0; ch < 2; ++ch) {
                sum[2 * i + ch] = float(double(sum[2 * i + ch]) * entry);
                sum[2 * i + ch] = float(double(sum[2 * i + ch]) * exit);
            }
        }
        return ll_peak_process(peak, sum, delayed, count);
    }
};

static LLSongPair *create(LLSongReplay *first, LLSongReplay *second, uint64_t frameCount,
                          uint64_t nextOrigin, bool rolling, bool placed = false,
                          uint64_t firstOrigin = 0, uint64_t secondOrigin = 0) {
    lowlight::FloatingPointMode mode;
    if (!first || !second || first == second || ll_song_replay_faulted(first) ||
        ll_song_replay_faulted(second) || ll_song_replay_position(first) ||
        ll_song_replay_position(second) || (!placed && ll_song_replay_origin(first)))
        return nullptr;
    const auto origin = placed ? secondOrigin : ll_song_replay_origin(second);
    const auto firstFrames = ll_song_replay_frames(first),
               secondFrames = ll_song_replay_frames(second);
    const bool more = !frameCount || nextOrigin < frameCount;
    if (firstOrigin > frameLimit - firstFrames || origin <= firstOrigin ||
        (frameCount && frameCount <= origin) || origin - firstOrigin >= firstFrames ||
        origin > frameLimit - secondFrames || nextOrigin <= origin || nextOrigin > frameLimit ||
        frameCount > frameLimit || (!placed && frameCount && nextOrigin > frameCount) ||
        nextOrigin > origin + secondFrames ||
        (more && (firstOrigin + firstFrames > nextOrigin || nextOrigin == origin + secondFrames)) ||
        uint64_t{ll_song_replay_required_voice_slots(first)} +
                ll_song_replay_required_voice_slots(second) >
            LL_VOICE_LIMIT)
        return nullptr;
    auto *pair = new (std::nothrow) LLSongPair;
    if (!pair)
        return nullptr;
    pair->songs[0] = first;
    pair->songs[1] = second;
    pair->origins[0] = firstOrigin;
    pair->origins[1] = origin;
    pair->input = pair->position = pair->entryOrigin = firstOrigin;
    pair->visiblePosition.store(firstOrigin, std::memory_order_relaxed);
    pair->listeningPosition.store(firstOrigin, std::memory_order_relaxed);
    pair->lengths[0] = firstFrames;
    pair->lengths[1] = secondFrames;
    pair->frames = frameCount;
    pair->nextOrigin = nextOrigin;
    pair->rolling = rolling;
    pair->placed = placed;
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
LLSongPair *ll_song_pair_create_transport_at(LLSongReplay *first, LLSongReplay *second,
                                             uint64_t firstOrigin, uint64_t secondOrigin,
                                             uint64_t frameCount, uint64_t nextOrigin) {
    auto *pair =
        create(first, second, frameCount, nextOrigin, true, true, firstOrigin, secondOrigin);
    if (pair)
        pair->streaming = true;
    return pair;
}
LLSongPair *ll_song_pair_create_transport(LLSongReplay *first, LLSongReplay *second,
                                          uint64_t secondOrigin, uint64_t frameCount,
                                          uint64_t nextOrigin) {
    return ll_song_pair_create_transport_at(first, second, 0, secondOrigin, frameCount, nextOrigin);
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
    // Once retirement is claimed, the consumer cannot create a new offer against its
    // old pair. Resolve an unclaimed offer before releasing that owner; claimed/ready
    // edits must instead be acknowledged or abandoned by this same worker first.
    const auto edit = pair->nextPhase.load(std::memory_order_acquire);
    if (pair->changePinsOwners() || edit == LLSongPair::nextPreparing ||
        edit == LLSongPair::nextReady || edit == LLSongPair::nextAccepted) {
        pair->phase.store(LLSongPair::requested, std::memory_order_release);
        return false;
    }
    if (edit == LLSongPair::nextOffered) {
        pair->nextResult = {2, pair->nextOffer.target_origin, 0, 0, 0};
        pair->nextPhase.store(LLSongPair::nextRejected, std::memory_order_release);
    }
    if (pair->changePhase.load(std::memory_order_acquire) == LLSongPair::changeOffered) {
        pair->changeResult = {3, 0, pair->changeOffer.revision, pair->changeOffer.target_origin, 0,
                              0, 0};
        pair->changePhase.store(LLSongPair::changeDeferred, std::memory_order_release);
    }
    *retired = pair->request.retired;
    return true;
}
static bool publish(LLSongPair *pair, LLSongReplay *next, uint64_t origin, uint64_t nextOrigin) {
    if (!pair || !pair->streaming ||
        pair->phase.load(std::memory_order_acquire) != LLSongPair::preparing ||
        pair->visibleFault.load(std::memory_order_acquire) || !next ||
        next == pair->request.survivor)
        return false;
    // Never inspect the concurrently rendered survivor or live input clock.
    const auto end = origin + ll_song_replay_frames(next);
    if (ll_song_replay_position(next) || ll_song_replay_faulted(next) ||
        origin != pair->request.origin || origin >= pair->request.survivorEnd ||
        origin > frameLimit - ll_song_replay_frames(next) || nextOrigin <= origin ||
        nextOrigin > frameLimit || (!pair->placed && pair->frames && nextOrigin > pair->frames) ||
        nextOrigin > end ||
        ((!pair->frames || nextOrigin < pair->frames) &&
         (pair->request.survivorEnd > nextOrigin || nextOrigin == end)) ||
        uint64_t{pair->request.voiceSlots} + ll_song_replay_required_voice_slots(next) >
            LL_VOICE_LIMIT)
        return false;
    pair->replacement = next;
    pair->followingOrigin = nextOrigin;
    pair->phase.store(LLSongPair::ready, std::memory_order_release);
    return true;
}
bool ll_song_pair_publish(LLSongPair *pair, LLSongReplay *next, uint32_t nextOrigin) {
    return pair && !pair->placed && publish(pair, next, ll_song_replay_origin(next), nextOrigin);
}
bool ll_song_pair_publish_transport(LLSongPair *pair, LLSongReplay *next, uint64_t origin,
                                    uint64_t nextOrigin) {
    return pair && pair->placed && publish(pair, next, origin, nextOrigin);
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
    if (!pair->frames && capacity && pair->position == frameLimit) {
        pair->faulted = true;
        pair->visibleFault.store(1, std::memory_order_release);
        return false;
    }
    const uint32_t requested = static_cast<uint32_t>(
        std::min(uint64_t{capacity}, (pair->frames ? pair->frames : frameLimit) - pair->position));
    uint32_t produced = 0;
    while (produced < requested) {
        if (pair->streaming) {
            pair->handoff();
            pair->advanceChange();
            pair->advanceNext();
            if (!pair->songs[1] && pair->input == pair->waitingOrigin())
                break;
        } else if (pair->needsPreparation())
            break;
        uint32_t physical = static_cast<uint32_t>(
            std::min(uint64_t{blockFrames}, uint64_t{requested - produced} + pair->startup));
        bool success;
        if (!pair->frames || pair->input < pair->frames) {
            physical = static_cast<uint32_t>(std::min(
                uint64_t{physical}, (pair->frames ? pair->frames : frameLimit) - pair->input));
            if (pair->rolling && pair->hasNext()) {
                const uint64_t stop = pair->songs[1] ? uint64_t{pair->origins[0]} + pair->lengths[0]
                                                     : pair->waitingOrigin();
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
        if (pair->restartFade < 12800) {
            for (uint32_t i = 0; i < count && pair->restartFade < 12800; ++i, ++pair->restartFade) {
                const double gain = double(pair->restartFade) / 12800;
                for (uint32_t ch = 0; ch < 2; ++ch)
                    output[2 * (uint64_t{produced} + i) + ch] =
                        float(double(output[2 * (uint64_t{produced} + i) + ch]) * gain);
            }
        }
        produced += count;
        // Publish generated musical progress before releasing a retirement request. A
        // worker must not select the survivor using the preceding call's stale cursor.
        // Keep the existing returned-output/fault position contract separate.
        if (pair->placed)
            pair->listeningPosition.store(pair->position + produced, std::memory_order_release);
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
    return static_cast<uint32_t>(ll_song_pair_position64(pair));
}
uint32_t ll_song_pair_frames(const LLSongPair *pair) {
    return static_cast<uint32_t>(ll_song_pair_frames64(pair));
}
bool ll_song_pair_faulted(const LLSongPair *pair) {
    return !pair || (pair->streaming ? pair->visibleFault.load(std::memory_order_acquire) != 0
                                     : pair->faulted);
}

uint64_t ll_song_pair_position64(const LLSongPair *pair) {
    return pair ? (pair->streaming ? pair->visiblePosition.load(std::memory_order_acquire)
                                   : pair->position)
                : 0;
}
uint64_t ll_song_pair_frames64(const LLSongPair *pair) {
    return pair ? pair->frames : 0;
}
uint64_t ll_song_pair_listening_position64(const LLSongPair *pair) {
    return pair && pair->placed ? pair->listeningPosition.load(std::memory_order_acquire)
                                : ll_song_pair_position64(pair);
}
bool ll_song_pair_finished(const LLSongPair *pair) {
    return pair && pair->frames && ll_song_pair_position64(pair) == pair->frames;
}

void LLSongPair::advanceNext() {
    const auto state = nextPhase.load(std::memory_order_acquire);
    if (state == nextRequested) {
        nextResult = {0, nextTarget, nextOrigin, 0, 0};
        if (nextTarget < origins[0] ||
            (nextTarget == origins[0] && (ll_song_replay_advanced(songs[0]) ||
                                          (songs[1] && ll_song_replay_position(songs[1]))))) {
            nextResult.status = 3;
            nextPhase.store(nextSatisfied, std::memory_order_release);
        } else if (songs[1] && phase.load(std::memory_order_acquire) == active &&
                   nextTarget == origins[0]) {
            const auto outro = ll_song_replay_outro_start(songs[0]);
            if (!outro || origins[0] + outro != origins[1]) {
                nextResult.status = 2;
                nextPhase.store(nextRejected, std::memory_order_release);
                return;
            }
            nextOffer = {songs[0],
                         songs[1],
                         nextGeneration,
                         nextTarget,
                         ll_song_replay_physical_position(songs[0]),
                         outro};
            nextPhase.store(nextOffered, std::memory_order_release);
        } else if (songs[1] && nextTarget != origins[0] && nextTarget != origins[1]) {
            nextResult.status = 2;
            nextPhase.store(nextRejected, std::memory_order_release);
        }
    } else if (state == nextReady) {
        const auto &patch = *nextPatch;
        const auto &change = *patch.advance;
        const bool valid =
            songs[0] == patch.offer.first && songs[1] == patch.offer.second &&
            origins[0] == patch.offer.target_origin && !ll_song_replay_position(songs[1]) &&
            phase.load(std::memory_order_acquire) == active && origins[1] >= change.delta &&
            nextOrigin >= change.delta &&
            uint64_t{change.voiceSlots} + ll_song_replay_required_voice_slots(songs[1]) <=
                LL_VOICE_LIMIT &&
            ll_song_replay_can_advance(songs[0], &change);
        nextResult = {valid ? 1u : 2u, patch.offer.target_origin, nextOrigin, change.boundary,
                      valid ? change.delta : 0u};
        if (valid) {
            ll_song_replay_apply_advance(songs[0], &change);
            lengths[0] = change.frames;
            origins[1] -= change.delta;
            nextOrigin -= change.delta;
            nextResult.following_origin = nextOrigin;
        }
        nextPatch = nullptr; // The source borrows accepted score storage; worker retains it.
        nextPhase.store(valid ? nextAccepted : nextRejected, std::memory_order_release);
    }
}
bool ll_song_pair_request_next(LLSongPair *pair, uint64_t targetOrigin) {
    if (!pair || !pair->placed || !pair->streaming || targetOrigin > frameLimit ||
        ll_song_pair_faulted(pair) || ll_song_pair_finished(pair) ||
        pair->nextPhase.load(std::memory_order_acquire) != LLSongPair::nextIdle ||
        pair->changePhase.load(std::memory_order_acquire) != LLSongPair::changeIdle)
        return false;
    pair->nextTarget = targetOrigin;
    ++pair->nextGeneration;
    pair->nextPhase.store(LLSongPair::nextRequested, std::memory_order_release);
    return true;
}
bool ll_song_pair_claim_next(LLSongPair *pair, LLSongNextOffer *offer) {
    if (offer)
        *offer = {};
    if (!pair || !offer)
        return false;
    uint32_t expected = LLSongPair::nextOffered;
    if (!pair->nextPhase.compare_exchange_strong(expected, LLSongPair::nextPreparing,
                                                 std::memory_order_acquire))
        return false;
    *offer = pair->nextOffer;
    return true;
}
LLSongNext *ll_song_pair_prepare_next(const LLSongNextOffer *offer, uint32_t boundary,
                                      uint16_t pivot) {
    lowlight::FloatingPointMode mode;
    if (!offer || !offer->first || !offer->second || offer->first == offer->second ||
        boundary < 3520 || boundary - 3520 < offer->source_input_frames ||
        boundary >= offer->outro_start_frames)
        return nullptr;
    auto *patch = new (std::nothrow) LLSongNext;
    if (!patch)
        return nullptr;
    patch->offer = *offer;
    patch->advance = ll_song_replay_prepare_advance(offer->first, boundary, pivot);
    if (!patch->advance ||
        uint64_t{patch->advance->voiceSlots} + ll_song_replay_required_voice_slots(offer->second) >
            LL_VOICE_LIMIT) {
        ll_song_next_destroy(patch);
        return nullptr;
    }
    return patch;
}
uint32_t ll_song_next_required_voice_slots(const LLSongNext *patch) {
    return patch && patch->advance ? patch->advance->voiceSlots : 0;
}
void ll_song_next_destroy(LLSongNext *patch) {
    if (!patch)
        return;
    ll_song_destroy_advance(patch->advance);
    delete patch;
}
bool ll_song_pair_publish_next(LLSongPair *pair, LLSongNext *patch) {
    if (!pair || !patch || !patch->advance || ll_song_pair_faulted(pair) ||
        pair->nextPhase.load(std::memory_order_acquire) != LLSongPair::nextPreparing ||
        patch->offer.generation != pair->nextOffer.generation ||
        patch->offer.first != pair->nextOffer.first ||
        patch->offer.second != pair->nextOffer.second)
        return false;
    pair->nextPatch = patch;
    pair->nextPhase.store(LLSongPair::nextReady, std::memory_order_release);
    return true;
}
bool ll_song_pair_abandon_next(LLSongPair *pair) {
    if (!pair || pair->nextPhase.load(std::memory_order_acquire) != LLSongPair::nextPreparing)
        return false;
    pair->nextPhase.store(LLSongPair::nextIdle, std::memory_order_release);
    return true;
}
bool ll_song_pair_next_result(LLSongPair *pair, LLSongNextResult *result) {
    if (result)
        *result = {};
    if (!pair || !result)
        return false;
    const auto state = pair->nextPhase.load(std::memory_order_acquire);
    if (state != LLSongPair::nextAccepted && state != LLSongPair::nextRejected &&
        state != LLSongPair::nextSatisfied)
        return false;
    *result = pair->nextResult;
    pair->nextPhase.store(LLSongPair::nextIdle, std::memory_order_release);
    return true;
}
void ll_song_pair_restart_fade(LLSongPair *pair) {
    if (pair)
        pair->restartFade = 0;
}

LLSongRevision *ll_song_revision_create() {
    return new (std::nothrow) LLSongRevision;
}
void ll_song_revision_destroy(LLSongRevision *revision) {
    delete revision;
}
bool ll_song_revision_set(LLSongRevision *token, uint64_t revision) {
    if (!token || !revision)
        return false;
    auto previous = token->value.load(std::memory_order_relaxed);
    while (previous < revision)
        if (token->value.compare_exchange_weak(previous, revision, std::memory_order_release,
                                               std::memory_order_relaxed))
            return true;
    return previous == revision;
}
uint64_t ll_song_revision_get(const LLSongRevision *token) {
    return token ? token->value.load(std::memory_order_acquire) : 0;
}
void LLSongPair::advanceChange() {
    const auto state = changePhase.load(std::memory_order_acquire);
    if (state == changeRequested) {
        changeResult = {3, 0, changeRevision, changeTarget, nextOrigin, 0, 0};
        if (ll_song_revision_get(changeIntent) != changeRevision || changeTarget < origins[0] ||
            (changeTarget == origins[0] && (ll_song_replay_advanced(songs[0]) ||
                                            (songs[1] && ll_song_replay_position(songs[1]))))) {
            changePhase.store(changeDeferred, std::memory_order_release);
        } else if (songs[1] && phase.load(std::memory_order_acquire) == active &&
                   changeTarget == origins[0]) {
            const auto outro = ll_song_replay_outro_start(songs[0]);
            if (!outro || origins[0] + outro != origins[1]) {
                changePhase.store(changeDeferred, std::memory_order_release);
                return;
            }
            changeOffer = {songs[0],
                           songs[1],
                           changeIntent,
                           changeGeneration,
                           changeRevision,
                           changeTarget,
                           origins[1],
                           nextOrigin,
                           ll_song_replay_physical_position(songs[0]),
                           outro,
                           lengths[0],
                           lengths[1],
                           ll_song_replay_required_voice_slots(songs[0]),
                           ll_song_replay_required_voice_slots(songs[1])};
            changePhase.store(changeOffered, std::memory_order_release);
        } else if (songs[1] && changeTarget != origins[0] && changeTarget != origins[1]) {
            changePhase.store(changeDeferred, std::memory_order_release);
        }
    } else if (state == changeWithdrawReady) {
        const auto &patch = *changePatch;
        const bool valid = songs[0] == patch.offer.first && songs[1] == patch.offer.second &&
                           origins[0] == patch.offer.target_origin &&
                           phase.load(std::memory_order_acquire) == active &&
                           !ll_song_replay_position(songs[1]) &&
                           ll_song_revision_get(patch.offer.intent) == patch.offer.revision &&
                           ll_song_replay_can_advance(songs[0], patch.advance);
        changeResult = {valid ? 0u : 2u,           0,          patch.offer.revision,
                        patch.offer.target_origin, nextOrigin, patch.advance->boundary,
                        patch.advance->frames};
        if (valid) {
            songs[1] = nullptr;
            origins[1] = lengths[1] = 0;
            changeWasWithdrawn = true;
        }
        changePhase.store(valid ? changeWithdrawn : changeRejected, std::memory_order_release);
    } else if (state == changeReady) {
        const auto &patch = *changePatch;
        const auto &change = *patch.advance;
        const bool valid = songs[0] == patch.offer.first && !songs[1] &&
                           origins[0] == patch.offer.target_origin &&
                           ll_song_revision_get(patch.offer.intent) == patch.offer.revision &&
                           ll_song_replay_can_advance(songs[0], &change);
        changeResult = {valid ? 1u : 2u,
                        1,
                        patch.offer.revision,
                        patch.offer.target_origin,
                        valid ? changeFollowingOrigin : changeOffer.original_following_origin,
                        change.boundary,
                        change.frames};
        if (valid) {
            ll_song_replay_apply_advance(songs[0], &change);
            lengths[0] = change.frames;
            songs[1] = changeReplacement;
            origins[1] = origins[0] + change.boundary;
            lengths[1] = ll_song_replay_frames(changeReplacement);
            nextOrigin = changeFollowingOrigin;
            changeWasWithdrawn = false;
        }
        changePhase.store(valid ? changeAccepted : changeRejected, std::memory_order_release);
    } else if (state == changeRestoreReady) {
        songs[1] = changeReplacement;
        origins[1] = changeOffer.original_origin;
        lengths[1] = changeOffer.second_frames;
        nextOrigin = changeOffer.original_following_origin;
        changeWasWithdrawn = false;
        changeResult = {4, 1, changeOffer.revision, changeOffer.target_origin, nextOrigin, 0, 0};
        changePhase.store(changeRestored, std::memory_order_release);
    }
}
bool ll_song_pair_request_change(LLSongPair *pair, uint64_t target, uint64_t revision,
                                 const LLSongRevision *intent) {
    if (!pair || !pair->placed || !pair->streaming || !revision || target > frameLimit ||
        ll_song_revision_get(intent) != revision || ll_song_pair_faulted(pair) ||
        ll_song_pair_finished(pair) || pair->changeGeneration == UINT64_MAX ||
        pair->changePhase.load(std::memory_order_acquire) != LLSongPair::changeIdle ||
        pair->nextPhase.load(std::memory_order_acquire) != LLSongPair::nextIdle)
        return false;
    pair->changeTarget = target;
    pair->changeRevision = revision;
    pair->changeIntent = intent;
    ++pair->changeGeneration;
    pair->changePhase.store(LLSongPair::changeRequested, std::memory_order_release);
    return true;
}
bool ll_song_pair_claim_change(LLSongPair *pair, LLSongChangeOffer *offer) {
    if (offer)
        *offer = {};
    if (!pair || !offer)
        return false;
    uint32_t expected = LLSongPair::changeOffered;
    if (!pair->changePhase.compare_exchange_strong(expected, LLSongPair::changePreparing,
                                                   std::memory_order_acquire))
        return false;
    *offer = pair->changeOffer;
    return true;
}
LLSongChange *ll_song_pair_begin_change(const LLSongChangeOffer *offer) {
    if (!offer || !offer->first || !offer->second || offer->first == offer->second ||
        !offer->revision || ll_song_revision_get(offer->intent) != offer->revision)
        return nullptr;
    auto *patch = new (std::nothrow) LLSongChange;
    if (!patch)
        return nullptr;
    patch->offer = *offer;
    patch->samples = ll_song_replay_begin_change(offer->first);
    if (!patch->samples) {
        delete patch;
        return nullptr;
    }
    return patch;
}
int32_t ll_song_change_add_sample(LLSongChange *patch, const LLSongChangeSample *sample) {
    return patch && !patch->advance && sample ? ll_mixer_change_add_sample(patch->samples, *sample)
                                              : -1;
}
bool ll_song_change_finish(LLSongChange *patch, const LLSongChangeScore *score) {
    if (!patch || patch->advance || !score || score->samples || score->sample_count ||
        ll_song_revision_get(patch->offer.intent) != patch->offer.revision ||
        score->boundary_frames < 3520 ||
        score->boundary_frames - 3520 < patch->offer.source_input_frames ||
        score->boundary_frames > patch->offer.outro_start_frames ||
        score->input_frames > patch->offer.original_frames)
        return false;
    patch->advance = ll_song_replay_prepare_change(patch->offer.first, *score, patch->samples);
    if (!patch->advance)
        return false;
    ll_mixer_destroy_change_samples(patch->samples);
    patch->samples = nullptr;
    return true;
}
LLSongChange *ll_song_pair_prepare_change(const LLSongChangeOffer *offer,
                                          const LLSongChangeScore *score) {
    if (!score || score->sample_count > LL_SAMPLE_LIMIT || (score->sample_count && !score->samples))
        return nullptr;
    auto *patch = ll_song_pair_begin_change(offer);
    if (!patch)
        return nullptr;
    for (uint32_t i = 0; i < score->sample_count; ++i)
        if (ll_song_change_add_sample(patch, &score->samples[i]) < 0) {
            ll_song_change_destroy(patch);
            return nullptr;
        }
    auto copied = *score;
    copied.samples = nullptr;
    copied.sample_count = 0;
    if (!ll_song_change_finish(patch, &copied)) {
        ll_song_change_destroy(patch);
        return nullptr;
    }
    return patch;
}
uint32_t ll_song_change_required_voice_slots(const LLSongChange *patch) {
    return patch && patch->advance ? patch->advance->voiceSlots : 0;
}
uint32_t ll_song_change_sample_bytes(const LLSongChange *patch) {
    return patch && patch->advance ? patch->advance->sampleBytes : 0;
}
void ll_song_change_destroy(LLSongChange *patch) {
    if (patch) {
        ll_song_destroy_advance(patch->advance);
        ll_mixer_destroy_change_samples(patch->samples);
        delete patch;
    }
}
static bool matchingChange(const LLSongPair *pair, const LLSongChange *patch) {
    return pair && patch && patch->advance &&
           patch->offer.generation == pair->changeOffer.generation &&
           patch->offer.revision == pair->changeOffer.revision &&
           patch->offer.intent == pair->changeOffer.intent &&
           patch->offer.target_origin == pair->changeOffer.target_origin &&
           patch->offer.original_origin == pair->changeOffer.original_origin &&
           patch->offer.original_following_origin == pair->changeOffer.original_following_origin &&
           patch->offer.first == pair->changeOffer.first &&
           patch->offer.second == pair->changeOffer.second;
}
bool ll_song_pair_withdraw_change(LLSongPair *pair, LLSongChange *patch) {
    if (!matchingChange(pair, patch) || ll_song_pair_faulted(pair) ||
        pair->changePhase.load(std::memory_order_acquire) != LLSongPair::changePreparing ||
        ll_song_revision_get(patch->offer.intent) != patch->offer.revision)
        return false;
    pair->changePatch = patch;
    pair->changePhase.store(LLSongPair::changeWithdrawReady, std::memory_order_release);
    return true;
}
bool ll_song_pair_claim_withdrawn_change(LLSongPair *pair, LLSongReplay **retired) {
    if (retired)
        *retired = nullptr;
    if (!pair || !retired)
        return false;
    uint32_t expected = LLSongPair::changeWithdrawn;
    if (!pair->changePhase.compare_exchange_strong(expected, LLSongPair::changeBuilding,
                                                   std::memory_order_acquire))
        return false;
    *retired = pair->changeOffer.second;
    return true;
}
bool ll_song_pair_publish_change(LLSongPair *pair, LLSongChange *patch, LLSongReplay *replacement,
                                 uint64_t following) {
    if (!matchingChange(pair, patch) || !replacement || replacement == patch->offer.first ||
        ll_song_pair_faulted(pair) ||
        pair->changePhase.load(std::memory_order_acquire) != LLSongPair::changeBuilding ||
        ll_song_replay_faulted(replacement) || ll_song_replay_position(replacement))
        return false;
    const uint64_t origin = patch->offer.target_origin + patch->advance->boundary;
    const uint32_t length = ll_song_replay_frames(replacement);
    if (origin >= patch->offer.target_origin + patch->advance->frames ||
        origin > frameLimit - length || following <= origin || following > frameLimit ||
        following >= origin + length ||
        following < patch->offer.target_origin + patch->advance->frames ||
        (pair->frames && pair->frames <= origin) ||
        uint64_t{patch->advance->voiceSlots} + ll_song_replay_required_voice_slots(replacement) >
            LL_VOICE_LIMIT)
        return false;
    pair->changePatch = patch;
    pair->changeReplacement = replacement;
    pair->changeFollowingOrigin = following;
    pair->changePhase.store(LLSongPair::changeReady, std::memory_order_release);
    return true;
}
bool ll_song_pair_restore_change(LLSongPair *pair, LLSongReplay *original) {
    if (!pair || !original || ll_song_pair_faulted(pair) || ll_song_replay_faulted(original) ||
        ll_song_replay_position(original))
        return false;
    const auto state = pair->changePhase.load(std::memory_order_acquire);
    if ((state != LLSongPair::changeBuilding && state != LLSongPair::changeRollback) ||
        original == pair->changeOffer.first ||
        ll_song_replay_frames(original) != pair->changeOffer.second_frames ||
        ll_song_replay_required_voice_slots(original) != pair->changeOffer.second_voice_slots)
        return false;
    pair->changeReplacement = original;
    pair->changePhase.store(LLSongPair::changeRestoreReady, std::memory_order_release);
    return true;
}
bool ll_song_pair_abandon_change(LLSongPair *pair) {
    if (!pair || pair->changePhase.load(std::memory_order_acquire) != LLSongPair::changePreparing)
        return false;
    pair->changePhase.store(LLSongPair::changeIdle, std::memory_order_release);
    return true;
}
bool ll_song_pair_change_result(LLSongPair *pair, LLSongChangeResult *result) {
    if (result)
        *result = {};
    if (!pair || !result)
        return false;
    const auto state = pair->changePhase.load(std::memory_order_acquire);
    if (state != LLSongPair::changeAccepted && state != LLSongPair::changeRejected &&
        state != LLSongPair::changeDeferred && state != LLSongPair::changeRestored)
        return false;
    *result = pair->changeResult;
    pair->changePhase.store(state == LLSongPair::changeRejected && result->withdrawn
                                ? LLSongPair::changeRollback
                                : LLSongPair::changeIdle,
                            std::memory_order_release);
    return true;
}
