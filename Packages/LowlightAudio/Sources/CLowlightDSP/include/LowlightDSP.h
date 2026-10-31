// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOWLIGHT_DSP_H
#define LOWLIGHT_DSP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { LL_VOICE_LIMIT = 64, LL_SAMPLE_LIMIT = 64, LL_EVENT_LIMIT = 2048,
       LL_SAMPLE_BYTES = 32 * 1024 * 1024, LL_STEAL_FRAMES = 160 };
typedef struct LLMixer LLMixer;
typedef struct {
    uint64_t start_frame;
    uint32_t sample_index, hold_frames, release_frames;
    float velocity, pan;
    uint8_t instrument; // 0 guitar, 1 piano, 2 bass, 3 kick, 4 side-stick, 5 closed hat, 6 shaker
    uint8_t connected;
    uint8_t priority; // 0 bed/support/percussion, 1 answer, 2 protected melody
    uint8_t midi; // Bass 31...57; percussion 1 for side-stick, otherwise 0; ignored for guitar/piano.
} LLEvent;

// Setup/destruction require an idle renderer. Owns bounded PCM/event copies.
// No operation is thread safe; one owner must serialize setup and rendering.
LLMixer *ll_mixer_create(void);
void ll_mixer_destroy(LLMixer *mixer);
// Returns a sample index, or -1. Only permitted before loading the first score.
int32_t ll_mixer_add_sample(LLMixer *mixer, const float *pcm, uint32_t frames, uint32_t channels);
// Sorted absolute 32 kHz starts; gate/release lengths come from canonical endpoints.
// Invalid loads leave the existing score/state untouched. Empty scores are valid.
// Scores containing bass reserve one of the 64 slots for its monophonic voice.
// Bass PCM is mono recorded touch scaled by .08. Percussion PCM includes fixed hit shaping;
// it must be mono, uses priority 0, and plays its full length regardless of gate/release.
bool ll_mixer_load_events(LLMixer *mixer, const LLEvent *events, uint32_t count);
void ll_mixer_reset(LLMixer *mixer);
// Allocation/free/lock/I/O-free. Writes every stereo frame; handles 256-frame subblocks.
// Caller supplies 2*frames floats, disjoint from immutable PCM. No concurrent calls.
bool ll_mixer_render(LLMixer *mixer, float *output, uint32_t frames);
uint32_t ll_mixer_active_voices(const LLMixer *mixer);
uint32_t ll_mixer_steals(const LLMixer *mixer);
uint32_t ll_mixer_dropped_events(const LLMixer *mixer);
uint64_t ll_mixer_position(const LLMixer *mixer);
uint32_t ll_mixer_sample_bytes(const LLMixer *mixer);

#ifdef __cplusplus
}
#endif
#endif
