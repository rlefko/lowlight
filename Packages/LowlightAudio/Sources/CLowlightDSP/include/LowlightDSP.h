// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOWLIGHT_DSP_H
#define LOWLIGHT_DSP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Native floating-point setup, validation, rendering, and analysis use round-to-nearest
// with subnormal flushing, then restore the caller's ARM64 FPCR/FPSR or SSE2 MXCSR.
// Callers may vary rounding, flush mode, and sticky status; exceptions must be masked
// and other FP controls must retain platform defaults. This contract starts with
// supplied PCM/canonical frames. Preparation uses the explicit gradual scope below;
// other caller code and Swift planning are outside these native scopes.

typedef void (*LLPreparationCallback)(void *context);
// Off-audio-thread preparation scope: round-to-nearest with gradual underflow.
// Invokes callback exactly once, synchronously on this thread; retains neither argument.
// Context may be null and is forwarded unchanged. A null callback returns false without
// changing FP state. Otherwise returns true after restoring the caller's full FP state.
// Callback must return normally: capture Swift errors inside and rethrow after return.
// No async work, thread migration, longjmp, or exceptions may escape this scope.
// The masked-exception/default-other-controls preconditions above also apply here.
bool ll_with_preparation_mode(LLPreparationCallback callback, void *context);

// Registered PCM keys are separate from active voices: 80 guitar + 20 piano +
// 54 bass + 2 kick + 2 side-stick + 4 hat + 4 shaker cover the validated key domain.
enum {
    LL_VOICE_LIMIT = 64,
    LL_SAMPLE_LIMIT = 166,
    LL_EVENT_LIMIT = 2048,
    LL_SAMPLE_BYTES = 32 * 1024 * 1024,
    LL_STEAL_FRAMES = 160
};
typedef struct LLMixer LLMixer;
typedef struct {
    uint64_t start_frame;
    uint32_t sample_index, hold_frames, release_frames;
    float velocity, pan;
    uint8_t instrument; // 0 guitar, 1 piano, 2 bass, 3 kick, 4 side-stick, 5 closed hat, 6 shaker
    uint8_t connected;
    uint8_t priority; // 0 bed/support/percussion, 1 answer, 2 protected melody
    uint8_t
        midi; // Bass 31...57; percussion 1 for side-stick, otherwise 0; ignored for guitar/piano.
} LLEvent;
// Separate rack inputs/outputs preserve the future (processed tonal + bass)*duck + drums order.
// Guitar/piano remain uncompressed; bass has energy gain but is not ducked. No mastering.
typedef struct {
    float guitar[2], piano[2], bass[2], drums[2];
    float duck;
} LLBusFrame;

// Setup/destruction require an idle renderer. Owns bounded PCM/event copies.
// No operation is thread safe; one owner must serialize setup and rendering.
LLMixer *ll_mixer_create(void);
void ll_mixer_destroy(LLMixer *mixer);
// Optional absolute 32 kHz origin in 0...2^52; defaults to zero. Setup only before
// the first successful score load, including an empty load. Updates position now;
// reset/reload returns to this origin with no voices or signal history. This is
// a clean song start, not seeking or restoring carry-in notes. Invalid calls
// preserve all state. Events and fades retain the same absolute clock.
bool ll_mixer_configure_origin(LLMixer *mixer, uint64_t frame_origin);
// Optional, off-thread setup before the first score load. Finite energy in 0...1.
// Designs fixed filters and the duck table; invalid calls leave all state untouched.
bool ll_mixer_configure_buses(LLMixer *mixer, double energy);
typedef struct {
    double tonal_in_start_frame, tonal_in_end_frame;
    double tonal_out_start_frame, tonal_out_end_frame;
    double rhythm_in_frame, rhythm_out_frame;
} LLRackFades;
// Optional bus-only fades, copied before the first successful score load; buses must
// already be configured. All endpoints are finite in 0...2^52 canonical 32 kHz frames.
// Arrival 0/0 disables fade-in; departure and each enabled arrival span must be >=1 frame.
// Overlapping tonal spans multiply. rhythm_in <= rhythm_out: gate before arrival,
// then fade the last 2400 frames before departure. Fractional endpoints are supported.
// Invalid calls preserve state. Reset/reload preserves fades; raw dry output is unchanged.
bool ll_mixer_configure_fades(LLMixer *mixer, const LLRackFades *fades);
// Returns a sample index, or -1. Only permitted before loading the first score.
int32_t ll_mixer_add_sample(LLMixer *mixer, const float *pcm, uint32_t frames, uint32_t channels);
// Frozen 100-key x 101-bin gains (key-major), copied during setup. The immutable table
// also designs target filters for this platform. Its owner must outlive every mixer borrower.
typedef struct LLTonalCalibration LLTonalCalibration;
LLTonalCalibration *ll_tonal_calibration_create(const float *gains, uint32_t count);
void ll_tonal_calibration_destroy(LLTonalCalibration *calibration);
bool ll_mixer_configure_tonal(LLMixer *mixer, const LLTonalCalibration *calibration,
                              uint32_t initial_bin);
// HP-only PCM: keys 0...79 are (guitar MIDI - 50) * 4 + take and 80...99 are
// 80 + piano MIDI - 50. The existing arena and sample/voice limits apply.
int32_t ll_mixer_add_tonal_sample(LLMixer *, const float *, uint32_t frames, uint32_t channels,
                                  uint32_t key);
// Sorted absolute 32 kHz starts at/after the configured origin; gate/release
// lengths come from canonical endpoints. Successful loads rewind to the origin.
// Invalid loads leave the existing score/state untouched. Empty scores are valid.
// Scores containing bass reserve one of the 64 slots for its monophonic voice.
// Bass PCM is mono recorded touch scaled by .08. Percussion PCM includes fixed hit shaping;
// it must be mono, uses priority 0, and plays its full length regardless of gate/release.
bool ll_mixer_load_events(LLMixer *mixer, const LLEvent *events, uint32_t count);
void ll_mixer_reset(LLMixer *mixer); // Rewinds to the configured absolute origin.
// Allocation/free/lock/I/O-free. Writes every stereo frame; handles 256-frame subblocks.
// Caller supplies 2*frames floats, disjoint from immutable PCM. No concurrent calls.
bool ll_mixer_render(LLMixer *mixer, float *output, uint32_t frames);
// Requires configured buses; shares the same voices/clock as dry rendering.
// Both output views advance configured bus state, so switching views loses no filter history.
// Writes every frame (zeros on failure); caller supplies disjoint storage for frames structs.
// Fades scale summed stems before filters; duck remains score-driven. Filters continue
// after voices/fades end. Reset/reload clears filters and ducking, preserving configuration.
bool ll_mixer_render_buses(LLMixer *mixer, LLBusFrame *output, uint32_t frames);
uint32_t ll_mixer_active_voices(const LLMixer *mixer);
uint32_t ll_mixer_steals(const LLMixer *mixer);
uint32_t ll_mixer_dropped_events(const LLMixer *mixer);
uint64_t ll_mixer_position(const LLMixer *mixer); // Absolute clock shared by both render views.
uint64_t ll_mixer_origin(const LLMixer *mixer);   // Configured reset origin; zero for null.
uint32_t ll_mixer_sample_bytes(const LLMixer *mixer);
// Setup-derived raw peak of non-bass [start, start + lifetime) intervals with
// nonzero prepared gain, plus one reserved slot if any bass event exists, even silent.
// Uses actual sample/gate lifetimes; neither rack fades nor silent PCM reduce it.
// Not clamped to 64: a value <=64 proves no generic stealing is needed; bass
// replacements stay within the reserved slot. Summed per-rack values <=64 bound
// simultaneous readers regardless of relative lookahead. Standalone overload
// behavior is unchanged. Reset/invalid reload preserve it; null/unloaded returns zero.
uint32_t ll_mixer_required_voice_slots(const LLMixer *mixer);

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
bool ll_peak_process(LLPeakProtector *protector, const float *input, float *output,
                     uint32_t frames);
// First valid call (even capacity 0) closes input. Emits exactly 160 more physical
// frames for nonempty streams, none for empty; extends the last detector peak.
// Repeated calls after exhaustion succeed with written=0. Clears unused capacity.
// written is required; capacity 0 permits null output. Rejects output/written
// overlap before writing through written. Failure clears provided output, sets
// nonaliased written=0, and preserves state. Caller supplies full capacity storage.
bool ll_peak_drain(LLPeakProtector *protector, float *output, uint32_t capacity, uint32_t *written);

enum { LL_AIR_MAX_FRAMES = 5792000 };
typedef struct LLAir LLAir;
// Finite 32 kHz song air. Setup runs off-thread: it scans both complete channels
// for normalization and certifies <=64 raw RNG words per normal before replay.
// take_seed <2^31; input_frames in 1...LL_AIR_MAX_FRAMES; texture finite in 0...1.
// frame_origin+input_frames <=2^52. Required fades use the mixer descriptor rules;
// origin affects only the tonal fade clock, while modulation/RNG remain song-local.
// Returns null on invalid input, allocation failure, or an over-budget RNG stream.
LLAir *ll_air_create(uint32_t take_seed, uint32_t input_frames, uint64_t frame_origin,
                     double texture, const LLRackFades *fades);
void ll_air_destroy(LLAir *air);
void ll_air_reset(LLAir *air); // Rewinds both prepared streams and filters without a new scan.
// Allocation/free/lock/I/O-free. Adds air in place to 2*frames finite stereo Floats,
// retaining the Double modulation/addition before one Float store. Frames must not
// exceed the prepared remainder; count 0 permits a null buffer for a valid air.
// Failure clears provided output and preserves signal state. No extra latency or
// drain; callers must account for upstream DSP latency before supplying song frames.
// Setup/add use round-to-nearest and flush subnormals, restoring full host FP state.
bool ll_air_add(LLAir *air, float *stereo, uint32_t frames);

#define LL_SONG_MIX_BUS_LIMIT 1e20f
typedef struct LLSongMix LLSongMix;
// Single-owner finite song mix after room, before fixed loudness gain/protection.
// Owns prepared air and HP32 state. Creation uses the same seed/N/origin/texture/
// fades rules as ll_air_create; setup/destruction belong off the audio callback.
LLSongMix *ll_song_mix_create(uint32_t take_seed, uint32_t input_frames, uint64_t frame_origin,
                              double texture, const LLRackFades *fades);
void ll_song_mix_destroy(LLSongMix *mix);
void ll_song_mix_reset(LLSongMix *mix); // Rewinds air and clears HP history without another scan.
// Allocation/free/lock/I/O-free: Float (tonal+bass)*duck+drums, accepted air, then
// Double-state HP32 with Float output. Writes 2*frames interleaved stereo Floats.
// Input buses must be finite with magnitude <=LL_SONG_MIX_BUS_LIMIT; duck in 0...1.
// Count cannot exceed the remaining N logical song frames; no added latency/drain.
// Caller removes glue's 399 startup frames and retains its delayed/drained song frames.
// Validates the whole call before advancing; any input/output overlap is rejected.
// Failure clears provided output and preserves signal state. Caller supplies full
// count storage. Count 0 permits null buffers for a valid mix, including at EOF.
// Setup/process enforce RN+FTZ and restore full caller FP state. No concurrent calls.
bool ll_song_mix_process(LLSongMix *mix, const LLGlueFrame *input, float *output, uint32_t frames);

typedef struct LLSongSource LLSongSource;
typedef struct {
    uint64_t frame_origin;
    uint32_t input_frames, take_seed;
    uint8_t focus;
    double space, warmth, texture;
    LLRackFades rack_fades;
} LLSongSourceConfig;
// Off-thread finite pre-gain source: mixer buses -> aligned glue -> room -> song mix.
// Borrows an exclusively owned, loaded bus mixer at its configured origin. The
// mixer must outlive the source and must not be used independently until destruction.
// Its events/fades use the config's absolute clock; supply the same rack fades here.
// N/seed/origin/texture/fades follow ll_air_create; focus/space/warmth follow glue/room.
// Invalid creation leaves the mixer untouched. Owns fixed scratch/downstream state;
// no whole-song PCM, body analysis, fixed gain, peak protection, or extra tail.
LLSongSource *ll_song_source_create(LLMixer *mixer, const LLSongSourceConfig *config);
void ll_song_source_destroy(LLSongSource *source); // Does not destroy the borrowed mixer.
void ll_song_source_reset(LLSongSource *source); // Resets every stage and clears a terminal fault.
// Allocation/free/lock/I/O-free. Emits min(capacity, N-position) logical stereo
// frames, hiding glue's startup/drain; room/air see exactly N aligned song frames.
// Clears unused capacity. written is required and cannot overlap output; buffers
// must be fully sized and disjoint from both opaque allocations. Capacity 0 permits
// null output and succeeds at EOF. Invalid arguments clear output/written without
// advancing. An internal stage failure clears the whole call and latches a fault
// until reset: position stays at the last successful call, but internal stages may
// have advanced. No whole-chain rollback is claimed. No concurrent operations.
bool ll_song_source_render(LLSongSource *source, float *output, uint32_t capacity,
                           uint32_t *written);
uint32_t ll_song_source_position(const LLSongSource *source); // Logical clock; zero for null.
uint32_t
ll_song_source_frames(const LLSongSource *source); // Declared logical length; zero for null.
uint64_t
ll_song_source_origin(const LLSongSource *source); // Absolute layout origin; zero for null.
uint32_t ll_song_source_required_voice_slots(
    const LLSongSource *source);                         // Immutable raw demand; zero for null.
bool ll_song_source_faulted(const LLSongSource *source); // True for null.

enum { LL_LOUDNESS_MIN_FRAMES = 12800, LL_LOUDNESS_MAX_FRAMES = 5792000 };
#define LL_LOUDNESS_INPUT_LIMIT 1e6f
typedef struct LLLoudness LLLoudness;
typedef struct {
    double integrated_lufs; // Defined only when measurable; otherwise zero, never a suggested gain.
    uint32_t total_blocks, absolute_blocks, gated_blocks;
    bool measurable;
} LLLoudnessResult;
// Off-thread, single-owner analysis of one known-length 32 kHz stereo body slice.
// K filters start at the supplied body's first frame, with no preceding song warmup.
// Pinned pyloudnorm 0.1.1 staging/gates, including its rounded partial final block.
// Fixed storage; never retains the complete body. No gain application or audio output.
LLLoudness *ll_loudness_create(uint32_t body_frames);
void ll_loudness_destroy(LLLoudness *meter);
void ll_loudness_reset(LLLoudness *meter); // Retains N; clears filters, analysis, and finalization.
// Reads 2*frames finite Floats with |input|<=LL_LOUDNESS_INPUT_LIMIT, up to remaining N.
// Whole-call preflight preserves meter/input on failure. Count 0 accepts null input
// before finalization, including at N. Every process call after finish fails until reset.
// Input/result storage must be fully sized and disjoint from the opaque allocation.
// Process/finish/reset allocate/free nothing. No concurrent operations are permitted.
bool ll_loudness_process(LLLoudness *meter, const float *stereo, uint32_t frames);
// Requires exactly N consumed frames and a result pointer. Success finalizes once;
// repeated finish returns the same cached result. Silence/below-gate is successful
// but not measurable, with LUFS zero and actual gate counts. Failure clears supplied
// result and preserves the meter. Setup/process/finish force RN+FTZ and restore all
// caller FP control/status. No drain, padding, or filter-tail frames are appended.
bool ll_loudness_finish(LLLoudness *meter, LLLoudnessResult *result);

#define LL_SONG_GAIN_INPUT_LIMIT 1e6f
typedef struct LLSongGain LLSongGain;
typedef struct {
    double gain_db, linear_multiplier;
} LLSongGainValues;
// One immutable gain targeting -20.5 LUFS from a measurable body. Setup and
// destruction run off the callback. body_lufs must be finite and >=-70; a
// nonfinite/nonpositive Double multiplier (including underflow to zero) fails.
// No clamping, body selection, gain smoothing, or fallback for unmeasurable input.
LLSongGain *ll_song_gain_create(double body_lufs);
void ll_song_gain_destroy(LLSongGain *gain);
// Copies prepared values; invalid handle/result clears supplied values and fails.
// Result storage must be disjoint from the opaque allocation.
bool ll_song_gain_get(const LLSongGain *gain, LLSongGainValues *values);
// Disjoint caller-owned interleaved stereo buffers, finite |input|<=1e6.
// Validates the complete call, then Double input*multiplier -> Float output.
// Applies the same gain to every supplied frame, including intro/outro/tails;
// no stream position, latency, drain, or reset. Allocation/free/lock/I/O-free.
// Failure clears every supplied output frame; rejected overlap may clear input.
// Count 0 permits null buffers for a valid handle. Storage must be fully sized
// and disjoint from the opaque allocation; destroy only after reads complete.
// Setup/process force RN+FTZ and restore full caller FP control/status.
bool ll_song_gain_process(const LLSongGain *gain, const float *input, float *output,
                          uint32_t frames);

typedef struct LLSongReplay LLSongReplay;
// Off-thread fixed-gain/song-peak composition. Borrows an exclusive finite source
// at logical position zero, not faulted; the source must outlive replay and cannot
// be used independently while borrowed. Owns immutable gain, peak state, and fixed
// scratch. body_lufs follows ll_song_gain_create; caller measures the selected
// post-HP32 body first and validates ALL source frames against the gain input bound.
// Creation never advances/resets the source, including on failure. No complete song PCM is retained.
LLSongReplay *ll_song_replay_create(LLSongSource *source, double body_lufs);
void ll_song_replay_destroy(LLSongReplay *replay); // Does not destroy the borrowed source.
void ll_song_replay_reset(
    LLSongReplay *replay); // Rewinds source/peak without reanalysis or gain changes.
bool ll_song_replay_gain(const LLSongReplay *replay,
                         LLSongGainValues *values); // Same rules as gain_get.
// Allocation/free/lock/I/O-free. Emits min(capacity, N-position) logical stereo
// frames, hiding peak's 160 startup/drain frames. The source advances exactly N.
// Unused output is zero. Capacity 0 permits null output, including at EOF; written
// is required and cannot overlap output. Caller storage is fully sized and disjoint
// from opaque allocations. Invalid arguments clear output/written without advancing.
// Unexpected stage failure clears the whole call and faults until reset; position
// stays at the last successful call, but internal state may have advanced. No
// whole-chain rollback or hard/true-peak ceiling is claimed. No concurrent calls.
bool ll_song_replay_render(LLSongReplay *replay, float *output, uint32_t capacity,
                           uint32_t *written);
uint32_t ll_song_replay_position(const LLSongReplay *replay); // Logical clock; zero for null.
uint32_t
ll_song_replay_frames(const LLSongReplay *replay); // Declared logical length; zero for null.
uint64_t
ll_song_replay_origin(const LLSongReplay *replay); // Absolute layout origin; zero for null.
uint32_t ll_song_replay_required_voice_slots(
    const LLSongReplay *replay);                         // Immutable raw demand; zero for null.
bool ll_song_replay_faulted(const LLSongReplay *replay); // True for null.

typedef struct LLSongPair LLSongPair;
// Finite initial-session composition of two exclusively borrowed, distinct replays.
// Both must be fresh/nonfaulted, first origin=0, 0<second origin<first length,
// second origin<frame_count<=second origin+second length, and summed raw demand<=64.
// Creation leaves children untouched, including on failure. They must outlive the
// pair and cannot be used independently while borrowed. Owns fixed scratch and a
// session peak protector; never owns/releases either song. Caller separately
// validates schedule adjacency and stops before a third song is required.
LLSongPair *ll_song_pair_create(LLSongReplay *first, LLSongReplay *second, uint32_t frame_count);
// Single-pass rolling variant, using the same mix/fade/peak path. next_origin is
// the following unprepared onset capped at frame_count. It must follow the second
// origin and not exceed that child's EOF. A required successor must start before
// that EOF and at/after oldest full EOF, preventing three simultaneous racks.
LLSongPair *ll_song_pair_create_rolling(LLSongReplay *first, LLSongReplay *second,
                                        uint32_t frame_count, uint32_t next_origin);
// Opt-in streaming variant with the same bounds and single render consumer.
// At oldest full EOF, render detaches that raw borrower and requests preparation,
// then continues the survivor up to next_origin. If no replacement is ready there,
// it returns short/0 without advancing the musical clock or draining the peak.
// One serialized worker may claim/publish concurrently with render and the atomic
// position/fault/needs_preparation getters. All other operations require quiescence.
LLSongPair *ll_song_pair_create_streaming(LLSongReplay *first, LLSongReplay *second,
                                          uint32_t frame_count, uint32_t next_origin);
// Claims a detached pointer exactly once; caller may then destroy its owner on the
// worker. Failure clears supplied output. Output storage is disjoint from pair.
// Preparation failure leaves this request pending; retry without claiming again.
bool ll_song_pair_claim_retired(LLSongPair *pair, LLSongReplay **retired);
// Worker retains a distinct fresh candidate BEFORE publishing. Success transfers
// exclusive DSP access to render; keep its owner until a later retirement claim
// or quiescent destruction. Validates immutable request bounds, not live survivor
// state. Failure preserves the request and leaves candidate ownership unchanged.
// A publication racing a render fault may succeed but remain unconsumed: retain
// that candidate too. Stop both roles and wait for in-flight calls before destroying
// pair/owners. No concurrent cancellation, callback deletion, waiting, or spinning.
bool ll_song_pair_publish(LLSongPair *pair, LLSongReplay *next, uint32_t next_origin);
// Rolling render pauses eagerly at oldest full EOF, returning a successful short/0
// count and zeroing unused output. No silence is consumed or peak drained/reset.
// Audible position can be 160 frames behind the retirement input clock.
bool ll_song_pair_needs_preparation(
    const LLSongPair *pair); // Streaming: requested/preparing; false after publish/null/fault.
// Serialized off-callback service only. Detach before releasing the old owner;
// neither function deletes songs. Failed calls preserve state. Waiting persists
// after retirement until a distinct fresh child is appended at the exact expected
// origin. Append validates following coverage, no triple overlap and <=64 slots.
bool ll_song_pair_retire_first(LLSongPair *pair);
bool ll_song_pair_append(LLSongPair *pair, LLSongReplay *next, uint32_t next_origin);
void ll_song_pair_destroy(LLSongPair *pair);
void ll_song_pair_reset(LLSongPair *pair); // Fixed pair rewind; rolling mode is a no-op.
// Oldest-first Float sum, separate Double entry(.4s)/exit(2.8s) fade products with
// a Float store after each, then session peak protection. Emits exactly frame_count
// logical frames across calls, removing only the new 160-frame peak startup/drain.
// No intermediate PCM quantization. Borrowed songs may end or be truncated at EOF;
// complete song preparation/normalization still uses each declared full length.
// Same buffer, no-allocation/free, invalid-call and terminal-fault rules as replay.
// Render/reset never destroy songs or release reservations. Streaming render only
// detaches/adopts raw borrowers through its fixed single-entry handoff.
bool ll_song_pair_render(LLSongPair *pair, float *output, uint32_t capacity, uint32_t *written);
uint32_t ll_song_pair_position(const LLSongPair *pair); // Zero for null.
uint32_t ll_song_pair_frames(const LLSongPair *pair);   // Zero for null.
bool ll_song_pair_faulted(const LLSongPair *pair);      // True for null.

// Streaming transport places canonical children independently of their source origins.
// A zero frame_count explicitly selects continuous output (no finite exit fade/drain).
// A finite endpoint must strictly follow second_origin.
// Other frame coordinates are absolute transport frames, bounded by 2^52. Child lengths
// and render capacities remain UInt32. The _at variant begins a fresh, faded-in epoch at
// first_origin; it does not restore prior signal history. All ownership rules above apply.
LLSongPair *ll_song_pair_create_transport(LLSongReplay *first, LLSongReplay *second,
                                          uint64_t second_origin, uint64_t frame_count,
                                          uint64_t next_origin);
LLSongPair *ll_song_pair_create_transport_at(LLSongReplay *first, LLSongReplay *second,
                                             uint64_t first_origin, uint64_t second_origin,
                                             uint64_t frame_count, uint64_t next_origin);
bool ll_song_pair_publish_transport(LLSongPair *pair, LLSongReplay *next, uint64_t origin,
                                    uint64_t next_origin);
uint64_t ll_song_pair_position64(const LLSongPair *pair);
// Generated sub-block progress, published before retirement. May lead the last completed
// render call; use for worker listening selection, not a device/returned-output playhead.
uint64_t ll_song_pair_listening_position64(const LLSongPair *pair);
uint64_t ll_song_pair_frames64(const LLSongPair *pair); // Zero means continuous, or null.
bool ll_song_pair_finished(const LLSongPair *pair);     // False for continuous or null.
// Quiescent-only after off-thread restoration warmup; fades the next 0.4 seconds of
// returned output without resetting or advancing any DSP state.
void ll_song_pair_restart_fade(LLSongPair *pair);

typedef struct LLSongNext LLSongNext;
typedef struct {
    LLSongReplay *first, *second; // Borrowed immutable preparation inputs, pinned by worker owners.
    uint64_t generation, target_origin;
    uint32_t source_input_frames, outro_start_frames;
} LLSongNextOffer;
typedef struct {
    uint32_t status; // 1 accepted, 2 late/rejected, 3 natural transition already satisfies Next.
    uint64_t target_origin, following_origin;
    uint32_t boundary_frames, advanced_frames;
} LLSongNextResult;
// Single worker requests/claims/builds/publishes; single consumer adopts. Preparation and
// descriptor destruction are off-callback. Accepted descriptors remain pinned through
// destruction of their first child, even after the acknowledgment is consumed. A claimed
// offer pins both child owners until its result/abandonment; service this before retirement.
bool ll_song_pair_request_next(LLSongPair *, uint64_t target_origin);
bool ll_song_pair_claim_next(LLSongPair *, LLSongNextOffer *);
LLSongNext *ll_song_pair_prepare_next(const LLSongNextOffer *, uint32_t boundary_frames,
                                      uint16_t pivot_pitch_classes);
uint32_t ll_song_next_required_voice_slots(const LLSongNext *);
void ll_song_next_destroy(LLSongNext *);
bool ll_song_pair_publish_next(LLSongPair *, LLSongNext *);
bool ll_song_pair_abandon_next(LLSongPair *); // Only a claimed, unpublished offer.
bool ll_song_pair_next_result(LLSongPair *, LLSongNextResult *); // Consumes one acknowledgment.

// Configure once before rendering an ongoing transport. Publication and observation
// run off the callback. The single render consumer adopts the latest complete target.
typedef struct {
    double warmth, space, texture;
} LLEffectValues;
typedef struct {
    uint64_t adopted_revision, settled_revision;
    LLEffectValues settled_values;
} LLEffectProgress;
bool ll_song_pair_seed_effects(LLSongPair *, LLEffectValues, uint32_t tonal_bin);
bool ll_song_pair_send_effects(LLSongPair *, LLEffectValues, uint32_t tonal_bin, uint64_t revision);
LLEffectProgress ll_song_pair_effect_progress(const LLSongPair *);

// Structural controls use a separate, monotonic intent token retained by the caller
// through pair destruction. Updating it is bounded and thread safe; it never renders.
typedef struct LLSongRevision LLSongRevision;
LLSongRevision *ll_song_revision_create(void);
void ll_song_revision_destroy(LLSongRevision *);
bool ll_song_revision_set(LLSongRevision *, uint64_t revision);
uint64_t ll_song_revision_get(const LLSongRevision *);

typedef struct LLSongChange LLSongChange;
typedef struct {
    LLSongReplay *first, *second;
    const LLSongRevision *intent;
    uint64_t generation, revision, target_origin, original_origin, original_following_origin;
    uint32_t source_input_frames, outro_start_frames, original_frames, second_frames;
    uint32_t original_voice_slots, second_voice_slots;
} LLSongChangeOffer;
typedef struct {
    // Reuse an original sample with index>=0 and all other fields zero; otherwise
    // original_sample=-1 and bounded, fully validated PCM is copied during preparation.
    int32_t original_sample;
    const float *pcm;
    uint32_t frames, channels;
} LLSongChangeSample;
typedef struct {
    // Events are the replacement outro only, on the first child's canonical clock.
    // Their sample indices select this supplied sample list. Prefix indices stay fixed.
    const LLEvent *events;
    const LLSongChangeSample *samples;
    uint32_t event_count, sample_count, boundary_frames, input_frames;
    uint16_t pivot_pitch_classes;
    LLRackFades fades;
} LLSongChangeScore;
typedef struct {
    // 1 accepted, 2 rejected (withdrawn requires rollback), 3 deferred, 4 rolled back.
    uint32_t status, withdrawn;
    uint64_t revision, target_origin, following_origin;
    uint32_t boundary_frames, input_frames;
} LLSongChangeResult;
// One serialized worker owns this protocol. The intent token may be updated separately.
// Offers pin the current owners. Preparation touches only immutable descriptors and the
// unused tail of the first child's fixed PCM arena. Keep a published change alive through
// acknowledgment; accepted changes remain alive through first-child destruction.
bool ll_song_pair_request_change(LLSongPair *, uint64_t target_origin, uint64_t revision,
                                 const LLSongRevision *);
bool ll_song_pair_claim_change(LLSongPair *, LLSongChangeOffer *);
LLSongChange *ll_song_pair_prepare_change(const LLSongChangeOffer *, const LLSongChangeScore *);
// Incremental alternative keeps Swift scratch to one complete note. Add samples in
// event-key order, then finish with score.samples=null and sample_count=0. Destruction
// abandons unpublished arena contents. Do not interleave two builders for one rack.
LLSongChange *ll_song_pair_begin_change(const LLSongChangeOffer *);
int32_t ll_song_change_add_sample(LLSongChange *, const LLSongChangeSample *);
// New HP-only tonal PCM in the same supplemental arena. Original-slot references retain their key.
int32_t ll_song_change_add_tonal_sample(LLSongChange *, const LLSongChangeSample *, uint32_t key);
bool ll_song_change_finish(LLSongChange *, const LLSongChangeScore *);
uint32_t ll_song_change_required_voice_slots(const LLSongChange *);
uint32_t ll_song_change_sample_bytes(const LLSongChange *);
void ll_song_change_destroy(LLSongChange *);
bool ll_song_pair_withdraw_change(LLSongPair *, LLSongChange *);
// A successful claim exclusively returns the unstarted old successor, safe to destroy.
bool ll_song_pair_claim_withdrawn_change(LLSongPair *, LLSongReplay **);
bool ll_song_pair_publish_change(LLSongPair *, LLSongChange *, LLSongReplay *replacement,
                                 uint64_t following_origin);
// Fresh deterministic reconstruction of the withdrawn successor, after candidate failure.
// No revised timeline is applied. Keep this owner until later retirement or destruction.
bool ll_song_pair_restore_change(LLSongPair *, LLSongReplay *original);
bool ll_song_pair_abandon_change(LLSongPair *); // Claimed, not yet withdrawn/published only.
bool ll_song_pair_change_result(LLSongPair *, LLSongChangeResult *);

#ifdef __cplusplus
}
#endif
#endif
