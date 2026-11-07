#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Validate the shipped gain rows, optionally comparing all bins to the frozen v9 renderer."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import struct
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).with_name('warmth-v1.json')
TABLE = ROOT / 'Packages/LowlightAudio/Sources/LowlightAudio/Resources/warmth-v1.f32'


def integrity():
    manifest = json.loads(MANIFEST.read_text())
    if (manifest['schema_version'], manifest['keys'], manifest['bins']) != (1, 100, 101):
        raise ValueError('Unsupported warmth calibration format')
    expected_inputs = {
        'Lowlight/SoundBank/electric_guitar_manifest.json', 'Lowlight/SoundBank/sample_manifest.json',
        str(TABLE.relative_to(ROOT)), 'config/toolchain.env', 'tools/calibration/Generate.swift',
        'tools/calibration/generate', 'Packages/LowlightAudio/Sources/LowlightAudio/TonalSamplePreparer.swift',
        'Packages/LowlightAudio/Sources/LowlightAudio/BandSampleBank.swift',
        'Packages/LowlightAudio/Sources/LowlightAudio/SampleProcessing.swift',
        'Packages/LowlightAudio/Sources/LowlightAudio/PreparationMode.swift',
        'Packages/LowlightAudio/Sources/CLowlightDSP/Preparation.cpp',
        'Packages/LowlightAudio/Sources/CLowlightDSP/FloatingPointMode.h',
    }
    if set(manifest['sha256']) != expected_inputs:
        raise ValueError('Incomplete or unexpected Warmth calibration provenance')
    for name, expected in manifest['sha256'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise ValueError('Changed calibration table, input, or generator: ' + name)
    gains = struct.unpack('<10100f', TABLE.read_bytes())
    for index, value in enumerate(gains):
        low, high = (.45, 3.2) if index // 101 < 80 else (.35, 4.)
        # The clamped Double endpoints are stored as Float32.
        low, high = struct.unpack('<ff', struct.pack('<ff', low, high))
        if not low <= value <= high:
            raise ValueError(f'Invalid calibration gain at {index}')
    return gains


def independent(gains):
    import numpy as np
    oracle = runpy.run_path(str(ROOT / 'tools/reference/verify-tonal.py'))
    manifest, provenance = oracle['load_manifest']()
    limits = manifest['tolerances']
    worst_peak = worst_rms = worst_gain = 0.
    with oracle['reference'](provenance) as renderer:
        filt = renderer.ins.filt
        for key in range(100):
            guitar = key < 80
            note = 50 + (key // 4 if guitar else key - 80)
            sources = []

            def capture(samples, frequency, kind='lowpass', order=2):
                if kind == 'lowpass' and order == 4:
                    sources.append(samples[:28800].copy())
                return filt(samples, frequency, kind, order)

            # Capture the actual v9 asset selection, transposition, and high-pass output.
            # Keep one bounded prefix per key; downstream filters are causal.
            with patch.object(renderer.ins, 'filt', capture):
                if guitar:
                    renderer.guitar(note, key % 4, .78)
                else:
                    renderer.piano(note, .78)
            if len(sources) != 1:
                raise ValueError('Missing independent pre-warm signal for key ' + str(key))
            for bin_index in range(101):
                warm = bin_index / 100
                cutoff = 1300 - 600 * warm if guitar else 1200 - 500 * warm
                samples = filt(sources[0], cutoff, order=4)
                rms = float(np.sqrt(np.mean(samples[3840:28800] ** 2)))
                expected = np.float32(np.clip((.13 if guitar else .14) / max(rms, 1e-8),
                                              .45 if guitar else .35, 3.2 if guitar else 4.))
                actual = np.float32(gains[key * 101 + bin_index])
                # Both comparisons use the same independent signal so the measured
                # difference isolates the native calibration, including its Float rounding.
                delta = (samples * actual).astype(np.float64) - (samples * expected)
                peak = float(np.max(np.abs(delta)))
                error = float(np.sqrt(np.mean(delta * delta)))
                if peak > limits['maximum_absolute_error'] or error > limits['rms_error']:
                    raise ValueError(f'Calibration mismatch for key {key}, bin {bin_index}: {peak}, {error}')
                worst_peak = max(worst_peak, peak)
                worst_rms = max(worst_rms, error)
                worst_gain = max(worst_gain, abs(float(actual) - float(expected)))
    return {'keys': 100, 'bins': 101, 'comparisons': 10100, 'worst_absolute_pcm_error': worst_peak,
            'worst_rms_pcm_error': worst_rms, 'worst_gain_error': worst_gain}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compare', action='store_true', help='Compare every gain with the pinned v9 oracle')
    options = parser.parse_args()
    values = integrity()
    if options.compare:
        print(json.dumps(independent(values), indent=2))
    else:
        print('Verified the 100-key, 101-bin Warmth calibration and its provenance')
