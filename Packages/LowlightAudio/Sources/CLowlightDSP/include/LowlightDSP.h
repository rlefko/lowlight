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
// Separate rack inputs/outputs preserve the future (processed tonal + bass)*duck + drums order.
// Guitar/piano remain dry; bass has energy gain but is not ducked. No mastering or rack fades.
typedef struct {
    float guitar[2], piano[2], bass[2], drums[2];
    float duck;
} LLBusFrame;

// Setup/destruction require an idle renderer. Owns bounded PCM/event copies.
// No operation is thread safe; one owner must serialize setup and rendering.
LLMixer *ll_mixer_create(void);
void ll_mixer_destroy(LLMixer *mixer);
// Optional, off-thread setup before the first score load. Finite energy in 0...1.
// Designs fixed filters and the duck table; invalid calls leave all state untouched.
bool ll_mixer_configure_buses(LLMixer *mixer, double energy);
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
// Requires configured buses; shares the same voices/clock as dry rendering.
// Both output views advance configured bus state, so switching views loses no filter history.
// Writes every frame (zeros on failure); caller supplies disjoint storage for frames structs.
// Filters continue after active_voices reaches zero. Reset/reload clears filters and ducking.
bool ll_mixer_render_buses(LLMixer *mixer, LLBusFrame *output, uint32_t frames);
uint32_t ll_mixer_active_voices(const LLMixer *mixer);
uint32_t ll_mixer_steals(const LLMixer *mixer);
uint32_t ll_mixer_dropped_events(const LLMixer *mixer);
uint64_t ll_mixer_position(const LLMixer *mixer);
uint32_t ll_mixer_sample_bytes(const LLMixer *mixer);

enum { LL_GLUE_LATENCY = 399 };
typedef struct LLGlue LLGlue;
// Compressed harmony before room/.92 scaling; rhythm/control share its latency.
typedef struct {
    float tonal[2], bass[2], drums[2], duck;
} LLGlueFrame;

// Separate, single-owner 32 kHz processor. Setup/destruction require an idle renderer.
// Focus 0=guitar, 1=piano; input_frames is known and at most 2^52-399. Empty is valid.
LLGlue *ll_glue_create(uint64_t input_frames, uint8_t focus);
void ll_glue_destroy(LLGlue *glue);
void ll_glue_reset(LLGlue *glue); // Preserves focus/length; clears all signal history.
// Allocation/free/lock/I/O-free. Consumes <= the remaining input length and writes
// one physical frame per input. Initial 399 frames are silence with duck=1.
// Requires finite fields, duck in 0...1, and finite Float focus sum/linked power.
// Validate the entire call before advancing; failure zeroes provided output.
// Caller supplies full count storage; overlapping input/output is rejected (output is still cleared).
// Count 0 permits null buffers.
bool ll_glue_process(LLGlue *glue, const LLBusFrame *input, LLGlueFrame *output, uint32_t frames);
// Only after all input is consumed. Emits exactly 399 more physical frames for a
// nonempty stream (none for empty), reflecting detector boundaries, then succeeds
// with written=0. Clears unused capacity. written is required; capacity 0 permits
// null output. Overlapping output/written is rejected. Failure sets written=0,
// clears provided output, and preserves state.
bool ll_glue_drain(LLGlue *glue, LLGlueFrame *output, uint32_t capacity, uint32_t *written);

enum { LL_ROOM_TONAL_LIMIT = 1024 };
typedef struct LLRoom LLRoom;
// Separate, single-owner 32 kHz room; finite space/warmth in 0...1. Setup/destruction
// require an idle renderer. Fixed delays and coefficients are prepared at creation.
LLRoom *ll_room_create(double space, double warmth);
void ll_room_destroy(LLRoom *room);
void ll_room_reset(LLRoom *room); // Clears the tail, preserving controls/coefficients.
// Allocation/free/lock/I/O-free. Same-frame .92 dry + scaled wet replaces tonal;
// bass/drums/duck pass unchanged. No added alignment latency. Feed zero tonal input
// to continue the tail; no finite drain/truncation is imposed.
// Requires finite fields, |tonal| <= LL_ROOM_TONAL_LIMIT and duck in 0...1.
// Validates the entire call before advancing. Overlap (including in-place) is
// rejected; failure clears provided output and preserves state. Caller supplies
// full count storage; count 0 permits null buffers for a valid room.
bool ll_room_process(LLRoom *room, const LLGlueFrame *input, LLGlueFrame *output, uint32_t frames);

enum { LL_PEAK_LATENCY = 160, LL_PEAK_SONG = 0, LL_PEAK_SESSION = 1 };
#define LL_PEAK_INPUT_LIMIT 1e20f
typedef struct LLPeakProtector LLPeakProtector;
// Separate, single-owner 32 kHz linked stereo protector. Modes select the accepted
// -5 dB song or -2.2 dB session target. Smoothing is not a hard/true-peak ceiling.
// Setup/destruction require an idle renderer; stream length need not be known.
LLPeakProtector *ll_peak_create(uint8_t mode);
void ll_peak_destroy(LLPeakProtector *protector);
void ll_peak_reset(LLPeakProtector *protector); // Preserves mode; reopens and clears history.
// Allocation/free/lock/I/O-free. Caller supplies 2*frames interleaved floats.
// Writes one physical frame per input; the first 160 are silence. Inputs must be
// finite with magnitude <= LL_PEAK_INPUT_LIMIT, keeping the Float detector finite.
// Validates the whole call before advancing; overlap (including in-place) is
// rejected. Failure clears provided output and preserves state. Count 0 permits
// null buffers for an open valid processor. Calls after drain fail until reset.
bool ll_peak_process(LLPeakProtector *protector, const float *input, float *output, uint32_t frames);
// First valid call (even capacity 0) closes input. Emits exactly 160 more physical
// frames for nonempty streams, none for empty; extends the last detector peak.
// Repeated calls after exhaustion succeed with written=0. Clears unused capacity.
// written is required; capacity 0 permits null output. Rejects output/written
// overlap before writing through written. Failure clears provided output, sets
// nonaliased written=0, and preserves state. Caller supplies full capacity storage.
bool ll_peak_drain(LLPeakProtector *protector, float *output, uint32_t capacity, uint32_t *written);

#ifdef __cplusplus
}
#endif
#endif
