// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "LowlightDSP.h"

// One bounded, precomputed 0...100 bin position for each 32 kHz mixer input frame.
// The caller maps the session ramp onto this rack's physical clock before rendering.
bool ll_mixer_render_effect_buses(LLMixer *, LLBusFrame *, uint32_t, const double *warmthBins);
