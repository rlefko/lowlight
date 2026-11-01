// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "FloatingPointMode.h"
#include "LowlightDSP.h"

bool ll_with_preparation_mode(LLPreparationCallback callback, void *context) {
    if (!callback) return false;
    lowlight::FloatingPointMode mode(lowlight::UnderflowMode::gradual);
    callback(context);
    return true;
}
