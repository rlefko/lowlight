// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOWLIGHT_PREPARATION_TEST_SUPPORT_H
#define LOWLIGHT_PREPARATION_TEST_SUPPORT_H
#include <stdbool.h>
#include <stdint.h>
typedef struct { uint64_t control, status; } LLTestFPState;
typedef struct { LLTestFPState expected, actual; } LLTestFPAudit;
uint32_t ll_test_flush_modes(void);
LLTestFPState ll_test_fp_state(void);
bool ll_test_preparation_mode(void);
void ll_test_raise_flags(void);
LLTestFPAudit ll_test_environment(uint32_t rounding, uint32_t flush, bool flags,
                                void (*callback)(void *), void *context);
#endif
