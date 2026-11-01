// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOWLIGHT_FLOATING_POINT_MODE_H
#define LOWLIGHT_FLOATING_POINT_MODE_H
#include <cstdint>
#include <cstring>
#if defined(__SSE2__)
#include <xmmintrin.h>
#endif

// Make environment changes observable to the compiler, not merely CPU register writes.
// Keep the target's existing -ffp-contract=off; no fast-math or global flags are added.
#if defined(__clang__)
#pragma STDC FENV_ACCESS ON
#endif

namespace lowlight {
// Float/Double DSP with masked exceptions and otherwise default platform controls.
// Nesting restores the enclosing mode; callers retain their exact control/status bits.
class FloatingPointMode {
#if defined(__aarch64__)
    uint64_t control, status;
public:
    FloatingPointMode() noexcept {
        asm volatile("mrs %0, fpcr" : "=r"(control) : : "memory");
        asm volatile("mrs %0, fpsr" : "=r"(status) : : "memory");
        const uint64_t next = (control | (uint64_t{1} << 24)) & ~(uint64_t{3} << 22);
        asm volatile("msr fpcr, %0" : : "r"(next) : "memory");
    }
    ~FloatingPointMode() {
        asm volatile("msr fpcr, %0" : : "r"(control) : "memory");
        asm volatile("msr fpsr, %0" : : "r"(status) : "memory");
    }
#elif defined(__SSE2__)
    unsigned previous;
public:
    FloatingPointMode() noexcept : previous(_mm_getcsr()) {
        _mm_setcsr((previous | 0x8040u) & ~0x6000u);
    }
    ~FloatingPointMode() { _mm_setcsr(previous); }
#else
#error Lowlight requires an ARM64 or SSE2 floating-point target
#endif
    FloatingPointMode(const FloatingPointMode &) = delete;
    FloatingPointMode &operator=(const FloatingPointMode &) = delete;
};
// Raw-bit range checks keep negative subnormals invalid under FTZ/DAZ. Permit -0.
inline bool unitInterval(float value) {
    uint32_t bits; std::memcpy(&bits, &value, sizeof(bits));
    return bits <= UINT32_C(0x3f800000) || bits == UINT32_C(0x80000000);
}
inline bool unitInterval(double value) {
    uint64_t bits; std::memcpy(&bits, &value, sizeof(bits));
    return bits <= UINT64_C(0x3ff0000000000000) || bits == UINT64_C(0x8000000000000000);
}
}
#endif
