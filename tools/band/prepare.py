#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Build the band/ folder from matching original VCSL WAV files, using tools/reference/setup."""
import argparse
import hashlib
import json
import math
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen

import numpy as np
from scipy import signal
import soundfile as sf


SOURCES = Path(__file__).with_name("sources-v1.json")
RATE = 32000
# Trim lengths, high-pass cutoff, reference RMS. Retain the original recorded attacks.
PROFILES = {
    "electricSoft": (3.6, 75, 0.115), "electricAccent": (3.6, 75, 0.145),
    "vibraphone": (3.1, 70, 0.125), "tenorLong": (2.9, 95, 0.095),
    "tenorShort": (0.75, 95, 0.09),
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def original(row, source_dir, revision, download):
    source = source_dir / row["source"]
    if not source.exists() and download:
        url = f"https://raw.githubusercontent.com/sgossner/VCSL/{revision}/" + quote(row["source"])
        with urlopen(url, timeout=30) as response:
            raw = response.read(8_000_001)
        if len(raw) > 8_000_000 or sha(raw) != row["source_sha256"]:
            raise ValueError(f"downloaded recording does not match pinned source: {source.name}")
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(raw)
    raw = source.read_bytes()
    git_object = b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw
    if sha(raw) != row["source_sha256"] or hashlib.sha1(git_object).hexdigest() != row["git_blob"]:
        raise ValueError(f"original recording changed: {source.name}")
    return source


def prepare(row, source, output):
    wave, src_rate = sf.read(source, always_2d=True, dtype="float64")
    divisor = math.gcd(RATE, src_rate)
    mono = signal.resample_poly(wave.mean(axis=1), RATE // divisor, src_rate // divisor)
    duration, cutoff, target = PROFILES[row["voice"]]
    # Trim only leading silence. Keep 8 ms of the breath/mallet before the attack.
    attack = np.flatnonzero(abs(mono) >= 0.012 * np.max(abs(mono)))
    start = max(0, int(attack[0]) - 256)
    mono = mono[start:start + round(RATE * duration)].copy()
    mono = signal.sosfilt(signal.butter(2, cutoff, fs=RATE, btype="highpass", output="sos"), mono)

    # Confirm the expected concert pitch on audio, independent of octave naming conventions.
    window = mono[:12800]
    spectrum = abs(np.fft.rfft(window * np.hanning(len(window)), n=64000))
    f0 = 440 * 2 ** ((row["root_midi"] - 69) / 12)
    lo, hi = round(2 * f0 * 0.95), round(2 * f0 * 1.05)
    fundamental = lo + np.argmax(spectrum[lo:hi + 1])
    cents = 1200 * math.log2(fundamental * 0.5 / f0)
    if abs(cents) > 35 or spectrum[fundamental] < 0.01 * max(spectrum):
        raise ValueError(f"verify concert pitch of {source.name}: {cents:.1f} cents")

    # Level-match at default Focus tone. Preserve dynamic distinctions between note layers.
    reference = signal.sosfilt(signal.butter(4, 4200 - 2500 * .78, fs=RATE, output="sos"), window)
    gain = min(target / np.sqrt(np.mean(reference ** 2)), .82 / max(abs(mono)))
    mono *= gain
    mono[:32] *= np.linspace(0, 1, 32)
    tail = min(round(.12 * RATE), len(mono) // 4)
    mono[-tail:] *= np.linspace(1, 0, tail)
    pcm = np.rint(mono * 32768).astype("<i2")
    filename = f"{row['voice']}-{row['root_midi']}.flac"
    dest = output / filename
    sf.write(dest, pcm, RATE, subtype="PCM_16")
    return dict(asset="band/" + filename, voice=row["voice"], root_midi=row["root_midi"],
                frames=len(pcm), channels=1, sample_rate=RATE, asset_sha256=sha(dest.read_bytes()),
                bytes=dest.stat().st_size, pcm_sha256=sha((pcm.astype("<f4") / 32768).tobytes()),
                root_cents=round(cents, 1), source_skip_frames=start)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path)
    parser.add_argument("output", type=Path, help="new output folder")
    parser.add_argument("--download", action="store_true", help="fetch missing pinned WAV files from VCSL")
    args = parser.parse_args()
    manifest = json.loads(SOURCES.read_text())
    args.output.mkdir(parents=True, exist_ok=False)
    entries = []
    for row in manifest["entries"]:
        source = original(row, args.sources, manifest["commit"], args.download)
        entries.append(prepare(row, source, args.output))
    result = {k: manifest[k] for k in ("schema_version", "repository", "commit", "license")}
    result.update(sources_sha256=sha(SOURCES.read_bytes()), entries=entries)
    (args.output / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
