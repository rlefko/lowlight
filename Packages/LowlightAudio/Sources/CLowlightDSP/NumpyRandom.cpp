// Modifications Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only AND MIT AND BSD-3-Clause
// Adapted from NumPy 2.3.5, commit c3d60fc8393f3ca3306b8ce8b6453d43737e3d90.
// Sources: random/bit_generator.pyx, random/src/pcg64/pcg64.h and .c,
// random/src/distributions/distributions.c. Only the scalar-seed Double-normal path remains.
// Changes: fixed storage, validated take-seed contract, and one shared 64-word rejection budget.
/*
SeedSequence notice:
The MIT License (MIT)

Copyright (c) 2015 Melissa E. O'Neill
Copyright (c) 2019 NumPy Developers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

PCG64 notice (including upstream MIT relicense):

 * PCG64 Random Number Generation for C.
 *
 * Copyright 2014 Melissa O'Neill <oneill@pcg-random.org>
 * Copyright 2015 Robert Kern <robert.kern@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * For additional information about the PCG random number generation scheme,
 * including its license and other licensing options, visit
 *
 *     https://www.pcg-random.org
 *
 * Relicensed MIT in May 2019
 *
 * The MIT License
 *
 * PCG Random Number Generation for C.
 *
 * Copyright 2014 Melissa O'Neill <oneill@pcg-random.org>
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Distribution notices:
## NumPy

Copyright (c) 2005-2017, NumPy Developers.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above
   copyright notice, this list of conditions and the following
   disclaimer in the documentation and/or other materials provided
   with the distribution.

* Neither the name of the NumPy Developers nor the names of any
   contributors may be used to endorse or promote products derived
   from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


## Julia

The ziggurat methods were derived from Julia.

Copyright (c) 2009-2019: Jeff Bezanson, Stefan Karpinski, Viral B. Shah,
and other contributors:

https://github.com/JuliaLang/julia/contributors

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
NumPy random module notices:
**This software is dual-licensed under the The University of Illinois/NCSA
Open Source License (NCSA) and The 3-Clause BSD License**

# NCSA Open Source License
**Copyright (c) 2019 Kevin Sheppard. All rights reserved.**

Developed by: Kevin Sheppard (<kevin.sheppard@economics.ox.ac.uk>,
<kevin.k.sheppard@gmail.com>)
[http://www.kevinsheppard.com](http://www.kevinsheppard.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal with
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimers.

Redistributions in binary form must reproduce the above copyright notice, this
list of conditions and the following disclaimers in the documentation and/or
other materials provided with the distribution.

Neither the names of Kevin Sheppard, nor the names of any contributors may be
used to endorse or promote products derived from this Software without specific
prior written permission.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH
THE SOFTWARE.**


# 3-Clause BSD License
**Copyright (c) 2019 Kevin Sheppard. All rights reserved.**

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

**THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.**

# Components

Many parts of this module have been derived from original sources,
often the algorithm's designer. Component licenses are located with
the component code.

*/
#include "FloatingPointMode.h"
#include "NumpyRandom.h"
#include "NumpyZiggurat.h"
#include <cmath>

namespace lowlight {
namespace {
constexpr __uint128_t multiplier = (__uint128_t{2549297995355413924ULL} << 64) | 4865540595714422341ULL;
uint32_t hashMix(uint32_t value, uint32_t &constant) {
    value ^= constant; constant *= 0x931e8875u; value *= constant;
    return value ^ (value >> 16);
}
uint32_t mix(uint32_t x, uint32_t y) {
    const uint32_t value = 0xca01f9ddu * x - 0x4973f715u * y;
    return value ^ (value >> 16);
}
struct Words {
    void *state;
    detail::NextWord next;
    uint32_t remaining = detail::normalDrawLimit;
    bool raw(uint64_t &value) {
        if (!remaining) return false;
        --remaining; value = next(state); return true;
    }
    bool uniform(double &value) {
        uint64_t word;
        if (!raw(word)) return false;
        value = static_cast<double>(word >> 11) * (1.0 / 9007199254740992.0);
        return true;
    }
};
}

NumpyRandom::NumpyRandom(uint32_t takeSeed) {
    uint32_t pool[4], constant = 0x43b0d7e5u;
    for (uint32_t i = 0; i < 4; ++i) pool[i] = hashMix(i ? 0 : takeSeed + 91u, constant);
    for (uint32_t source = 0; source < 4; ++source)
        for (uint32_t destination = 0; destination < 4; ++destination)
            if (source != destination) pool[destination] = mix(pool[destination], hashMix(pool[source], constant));
    uint32_t generated[8]; constant = 0x8b51f9ddu;
    for (uint32_t i = 0; i < 8; ++i) {
        uint32_t value = pool[i % 4] ^ constant; constant *= 0x58f38dedu; value *= constant;
        generated[i] = value ^ (value >> 16);
    }
    uint64_t words[4];
    for (uint32_t i = 0; i < 4; ++i) words[i] = uint64_t{generated[2 * i]} | (uint64_t{generated[2 * i + 1]} << 32);
    const __uint128_t seed = (__uint128_t{words[0]} << 64) | words[1];
    increment = (((__uint128_t{words[2]} << 64) | words[3]) << 1) | 1;
    state = increment; state += seed; state = state * multiplier + increment;
}
uint64_t NumpyRandom::nextRaw() {
    state = state * multiplier + increment;
    const uint64_t value = static_cast<uint64_t>(state >> 64) ^ static_cast<uint64_t>(state);
    const uint32_t rotation = static_cast<uint32_t>(state >> 122);
    return (value >> rotation) | (value << ((-rotation) & 63));
}
bool detail::boundedDoubleNormal(void *state, NextWord next, double &output) {
    output = 0;
    if (!next) return false;
    Words words{state, next};
    for (uint32_t proposal = 0; proposal < normalDrawLimit; ++proposal) {
        uint64_t raw;
        if (!words.raw(raw)) return false;
        const uint32_t index = raw & 0xff;
        const uint64_t absolute = (raw >> 9) & 0x000fffffffffffffULL;
        double x = absolute * numpy::wi_double[index];
        if ((raw >> 8) & 1) x = -x;
        if (absolute < numpy::ki_double[index]) { output = x; return true; }
        if (index == 0) {
            for (uint32_t trial = 0; trial < normalDrawLimit; ++trial) {
                double first, second;
                if (!words.uniform(first) || !words.uniform(second)) return false;
                const double xx = -numpy::ziggurat_nor_inv_r * std::log1p(-first);
                const double yy = -std::log1p(-second);
                if (yy + yy > xx * xx) {
                    output = (absolute >> 8) & 1 ? -(numpy::ziggurat_nor_r + xx) : numpy::ziggurat_nor_r + xx;
                    return true;
                }
            }
            return false;
        }
        double uniform;
        if (!words.uniform(uniform)) return false;
        if ((numpy::fi_double[index - 1] - numpy::fi_double[index]) * uniform + numpy::fi_double[index] <
                std::exp(-.5 * x * x)) { output = x; return true; }
    }
    return false;
}
bool NumpyRandom::nextDoubleNormal(double &output) {
    return detail::boundedDoubleNormal(this, [](void *state) { return static_cast<NumpyRandom *>(state)->nextRaw(); }, output);
}
bool NumpyRandom::nextFloat(float &output) {
    double value;
    const bool result = nextDoubleNormal(value);
    output = static_cast<float>(value);
    return result;
}
}
