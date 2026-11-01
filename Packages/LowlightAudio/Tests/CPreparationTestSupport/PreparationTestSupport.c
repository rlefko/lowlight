// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#include "PreparationTestSupport.h"
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif
#pragma STDC FENV_ACCESS ON
LLTestFPState ll_test_fp_state(void) {
#if defined(__aarch64__)
    LLTestFPState value;
    __asm__ volatile("mrs %0, fpcr" : "=r"(value.control) : : "memory");
    __asm__ volatile("mrs %0, fpsr" : "=r"(value.status) : : "memory");
    return value;
#else
    return (LLTestFPState){_mm_getcsr(), 0};
#endif
}
static void install(LLTestFPState value) {
#if defined(__aarch64__)
    __asm__ volatile("msr fpcr, %0" : : "r"(value.control) : "memory");
    __asm__ volatile("msr fpsr, %0" : : "r"(value.status) : "memory");
#else
    _mm_setcsr((unsigned)value.control);
#endif
}
uint32_t ll_test_flush_modes(void) {
#if defined(__aarch64__)
    return 2;
#else
    return 4;
#endif
}
bool ll_test_preparation_mode(void) {
#if defined(__aarch64__)
    return !(ll_test_fp_state().control & ((UINT64_C(3) << 22) | (UINT64_C(1) << 24)));
#else
    return !(ll_test_fp_state().control & 0xe040u);
#endif
}
void ll_test_raise_flags(void) {
    volatile float one = 1, zero = 0, result = one / zero;
    (void)result;
}
LLTestFPAudit ll_test_environment(uint32_t rounding, uint32_t flush, bool flags,
                                void (*callback)(void *), void *context) {
    const LLTestFPState original = ll_test_fp_state();
#if defined(__aarch64__)
    const LLTestFPState expected = {
        (original.control & ~((UINT64_C(3) << 22) | (UINT64_C(1) << 24))) |
        ((uint64_t)rounding << 22) | ((uint64_t)flush << 24), flags ? 0x11u : 0};
#else
    const LLTestFPState expected = {
        (original.control & ~UINT64_C(0xe07f)) | ((uint64_t)rounding << 13) |
        ((flush & 1) ? 0x40u : 0u) | ((flush & 2) ? 0x8000u : 0u) | (flags ? 0x21u : 0), 0};
#endif
    install(expected);
    callback(context);
    const LLTestFPAudit result = {expected, ll_test_fp_state()};
    install(original);
    return result;
}
