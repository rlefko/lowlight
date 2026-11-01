// Modifications Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Float reduction adapted from NumPy 2.3.5 loops_utils.h.src, commit
// c3d60fc8393f3ca3306b8ce8b6453d43737e3d90; NumPy Developers, all rights reserved.
// Full upstream notice: Lowlight/ThirdParty/NumPy-Random-Notices.txt.
#include "FloatingPointMode.h"
#include "LowlightDSP.h"
#include "NumpyRandom.h"
#include "RackFades.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <new>

namespace {
constexpr double pi = 3.14159265358979323846;
float normal(float value) { return std::abs(value) < std::numeric_limits<float>::min() ? 0 : value; }
struct FilterState { double first = 0, second = 0; };
struct Biquad {
    double b0, b1, a1, a2;
    Biquad(double cutoff, bool highpass) {
        const double tangent = std::tan(pi * cutoff / 32000);
        const double denominator = 1 + tangent / std::sqrt(.5) + tangent * tangent;
        b0 = (highpass ? 1 : tangent * tangent) / denominator;
        b1 = (highpass ? -2 : 2) * b0;
        a1 = 2 * (tangent * tangent - 1) / denominator;
        a2 = (1 - tangent / std::sqrt(.5) + tangent * tangent) / denominator;
    }
    float process(float input, FilterState &state) const {
        const double result = b0 * input + state.first;
        state.first = b1 * input - a1 * result + state.second;
        state.second = b0 * input - a2 * result;
        return normal(static_cast<float>(result));
    }
};
struct Channel {
    lowlight::NumpyRandom random;
    FilterState highpass, lowpass;
    explicit Channel(lowlight::NumpyRandom start) : random(start) {}
    bool next(const Biquad &hp, const Biquad &lp, float &output) {
        float noise;
        if (!random.nextFloat(noise)) return false;
        output = lp.process(hp.process(noise, highpass), lowpass);
        return true;
    }
};
struct Stream {
    Channel channels[2];
    uint32_t position = 0;
    Stream(lowlight::NumpyRandom left, lowlight::NumpyRandom right) : channels{Channel(left), Channel(right)} {}
};
// NumPy 2.3.5 Float pairwise order (loops_utils.h.src); consume the left subtree
// first so the filter and RNG remain sequential. At most 17 recursive splits,
// with eight Float accumulators per leaf, only during off-thread preparation.
// Upstream copyright/license attribution: Lowlight/ThirdParty/NumPy-Random-Notices.txt.
struct PowerSum {
    Channel &channel;
    const Biquad &hp, &lp;
    bool valid = true;
    float next() {
        float value = 0;
        if (valid) valid = channel.next(hp, lp, value);
        return value * value;
    }
    float sum(uint32_t count) {
        if (count < 8) {
            float result = -0.f;
            for (uint32_t i = 0; i < count; ++i) result += next();
            return result;
        }
        if (count <= 128) {
            float lanes[8];
            for (auto &lane : lanes) lane = next();
            uint32_t i = 8;
            for (; i < count - count % 8; i += 8)
                for (auto &lane : lanes) lane += next();
            float result = ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3])) +
                           ((lanes[4] + lanes[5]) + (lanes[6] + lanes[7]));
            for (; i < count; ++i) result += next();
            return result;
        }
        uint32_t half = count / 2;
        half -= half % 8;
        const float left = sum(half);
        return left + sum(count - half);
    }
};
void clear(float *stereo, uint32_t frames) {
    if (stereo) for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i) stereo[i] = 0;
}
}

struct LLAir {
    lowlight::NumpyRandom starts[2];
    Biquad highpass{160, true}, lowpass{800, false};
    lowlight::RackFades fades;
    uint32_t frames;
    uint64_t origin;
    float gains[2]{};
    Stream stream;
    LLAir(uint32_t seed, uint32_t count, uint64_t start, lowlight::RackFades fade)
        : starts{lowlight::NumpyRandom(seed), lowlight::NumpyRandom(seed)}, fades(fade),
          frames(count), origin(start), stream(starts[0], starts[1]) {}
};

LLAir *ll_air_create(uint32_t takeSeed, uint32_t inputFrames, uint64_t frameOrigin,
                     double texture, const LLRackFades *fades) {
    lowlight::FloatingPointMode mode;
    lowlight::RackFades fade;
    if (takeSeed >= (uint32_t{1} << 31) || !inputFrames || inputFrames > LL_AIR_MAX_FRAMES ||
        frameOrigin > lowlight::frameLimit - inputFrames ||
        lowlight::frameBits(texture) > UINT64_C(0x3ff0000000000000) || !fades || !fade.configure(*fades)) return nullptr;
    auto *air = new (std::nothrow) LLAir(takeSeed, inputFrames, frameOrigin, fade);
    if (!air) return nullptr;
    for (uint32_t ch = 0; ch < 2; ++ch) {
        Channel scan(air->starts[ch]);
        PowerSum power{scan, air->highpass, air->lowpass};
        const float total = power.sum(inputFrames);
        // _mean divides the Float scalar sum by an integer in Double, then stores
        // Float before sqrt. NumPy's weak Python scalar is cast before air *= gain.
        const float rms = std::sqrt(static_cast<float>(static_cast<double>(total) / inputFrames));
        air->gains[ch] = static_cast<float>(texture * .00065 / std::max(static_cast<double>(rms), 1e-9));
        if (!power.valid || !std::isfinite(air->gains[ch])) { delete air; return nullptr; }
        if (ch == 0) air->starts[1] = scan.random;
    }
    air->stream = Stream(air->starts[0], air->starts[1]);
    return air;
}
void ll_air_destroy(LLAir *air) { delete air; }
void ll_air_reset(LLAir *air) {
    if (air) air->stream = Stream(air->starts[0], air->starts[1]);
}
bool ll_air_add(LLAir *air, float *stereo, uint32_t frames) {
    lowlight::FloatingPointMode mode;
    if (!air || frames > air->frames - air->stream.position || (frames && !stereo)) {
        clear(stereo, frames); return false;
    }
    for (uint64_t i = 0; i < uint64_t{frames} * 2; ++i)
        if (!std::isfinite(stereo[i])) { clear(stereo, frames); return false; }
    const Stream checkpoint = air->stream;
    for (uint32_t offset = 0; offset < frames;) {
        const uint32_t end = offset + std::min(256u, frames - offset);
        for (; offset < end; ++offset, ++air->stream.position) {
            const double time = static_cast<double>(air->stream.position) / 32000;
            const double fade = air->fades.tonalGain(air->origin + air->stream.position);
            for (uint32_t ch = 0; ch < 2; ++ch) {
                float sample;
                if (!air->stream.channels[ch].next(air->highpass, air->lowpass, sample)) {
                    air->stream = checkpoint; clear(stereo, frames); return false;
                }
                sample *= air->gains[ch];
                const double modulation = .8 + .12 * std::sin(2 * pi * time / 19 + ch) +
                                          .08 * std::sin(2 * pi * time / 7.1 + 2 * ch);
                const uint64_t i = uint64_t{offset} * 2 + ch;
                const float result = static_cast<float>(stereo[i] + static_cast<double>(sample) * modulation * fade);
                if (!std::isfinite(result)) { air->stream = checkpoint; clear(stereo, frames); return false; }
                stereo[i] = normal(result);
            }
        }
    }
    return true;
}
