// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "LowlightDSP.h"

struct LLMixerAdvance;
struct LLMixerChangeSamples;
struct LLSongAdvance {
    LLSongSource *source = nullptr;
    LLMixerAdvance *score = nullptr;
    LLRackFades fades{};
    uint32_t deadline = 0, boundary = 0, delta = 0, frames = 0, voiceSlots = 0, sampleBytes = 0;
};

LLMixerAdvance *ll_mixer_prepare_advance(const LLMixer *, uint32_t boundary, uint16_t pivot,
                                         LLSongAdvance &);
LLMixerChangeSamples *ll_mixer_begin_change(LLMixer *);
void ll_mixer_destroy_change_samples(LLMixerChangeSamples *);
int32_t ll_mixer_change_add_sample(LLMixerChangeSamples *, const LLSongChangeSample &);
LLMixerAdvance *ll_mixer_prepare_change(LLMixer *, const LLSongChangeScore &,
                                        const LLMixerChangeSamples *, LLSongAdvance &);
uint32_t ll_mixer_change_sample_bytes(const LLMixerAdvance *);
void ll_mixer_destroy_advance(LLMixerAdvance *);
bool ll_mixer_can_advance(const LLMixer *, const LLMixerAdvance *);
void ll_mixer_apply_advance(LLMixer *, const LLMixerAdvance *);
uint32_t ll_mixer_local_position(const LLMixer *);
uint32_t ll_mixer_outro_start(const LLMixer *);
bool ll_glue_can_shorten(const LLGlue *, uint32_t);
void ll_glue_shorten(LLGlue *, uint32_t);
void ll_air_replace_fades(LLAir *, const LLRackFades &);
void ll_song_mix_replace_fades(LLSongMix *, const LLRackFades &);
LLSongAdvance *ll_song_source_prepare_advance(LLSongSource *, uint32_t, uint16_t);
bool ll_song_source_can_advance(const LLSongSource *, const LLSongAdvance *);
void ll_song_source_apply_advance(LLSongSource *, const LLSongAdvance *);
uint32_t ll_song_source_physical_position(const LLSongSource *);
uint32_t ll_song_source_outro_start(const LLSongSource *);
LLSongAdvance *ll_song_replay_prepare_advance(LLSongReplay *, uint32_t, uint16_t);
bool ll_song_replay_can_advance(const LLSongReplay *, const LLSongAdvance *);
void ll_song_replay_apply_advance(LLSongReplay *, const LLSongAdvance *);
uint32_t ll_song_replay_physical_position(const LLSongReplay *);
uint32_t ll_song_replay_outro_start(const LLSongReplay *);
bool ll_song_replay_advanced(const LLSongReplay *);
void ll_song_destroy_advance(LLSongAdvance *);

LLMixerChangeSamples *ll_song_source_begin_change(LLSongSource *);
LLMixerChangeSamples *ll_song_replay_begin_change(LLSongReplay *);
LLSongAdvance *ll_song_source_prepare_change(LLSongSource *, const LLSongChangeScore &,
                                             const LLMixerChangeSamples *);
LLSongAdvance *ll_song_replay_prepare_change(LLSongReplay *, const LLSongChangeScore &,
                                             const LLMixerChangeSamples *);
