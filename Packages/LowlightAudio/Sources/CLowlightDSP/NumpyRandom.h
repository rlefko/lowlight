// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOWLIGHT_NUMPY_RANDOM_H
#define LOWLIGHT_NUMPY_RANDOM_H
#include <cstdint>

namespace lowlight {
// Internal, value-copyable NumPy 2.3.5 PCG64/Double-normal subset. The caller
// validates takeSeed < 2^31 and establishes identical FP mode for setup/replay.
struct NumpyRandom {
    explicit NumpyRandom(uint32_t takeSeed);
    uint64_t nextRaw();
    bool nextDoubleNormal(double &output);
    bool nextFloat(float &output);
private:
    __uint128_t state = 0, increment = 0;
};
namespace detail {
constexpr uint32_t normalDrawLimit = 64;
using NextWord = uint64_t (*)(void *);
// Shared by the production generator and deterministic rejection-path tests.
// Every raw64 draw, including uniform draws, consumes the same fixed budget.
// Failure clears output; source state may have advanced and must be restored by its owner.
bool boundedDoubleNormal(void *state, NextWord next, double &output);
}
}
#endif
