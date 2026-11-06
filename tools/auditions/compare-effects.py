#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Turn the six production audition renders into matched Float32 WAV pairs."""
import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys


def measure(path, input_options=()):
    result = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", *input_options, "-i", str(path),
         "-af", "loudnorm=print_format=json", "-f", "null", "-"],
        capture_output=True, text=True, check=True)
    start = result.stderr.rfind("{")
    result, _ = json.JSONDecoder().raw_decode(result.stderr[start:])
    loudness, peak = float(result["input_i"]), float(result["input_tp"])
    if not (math.isfinite(loudness) and math.isfinite(peak)):
        raise ValueError(f"invalid level in {path}")
    return {"lufs": loudness, "true_peak_dbtp": peak}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(directory):
    raw_options = ("-f", "f32le", "-ar", "32000", "-ac", "2")
    prefix = None
    pairs = {}
    for effect in ("warmth", "space", "texture"):
        paths = [directory / f"{effect}-{value}.f32" for value in (0, 1)]
        levels = [measure(path, raw_options) for path in paths]
        target = min(level["lufs"] for level in levels)
        records = []
        for value, (path, level) in enumerate(zip(paths, levels)):
            if path.stat().st_size != 24 * 32000 * 8:
                raise ValueError(f"wrong duration: {path}")
            with path.open("rb") as stream:
                current = stream.read(4 * 32000 * 8)
            if prefix is not None and current != prefix:
                raise ValueError(f"performance prefix differs: {path}")
            prefix = current
            gain = target - level["lufs"]
            wav = path.with_suffix(".wav")
            # A single attenuation preserves the dynamics of each pass.
            subprocess.run(
                ["ffmpeg", "-nostdin", "-v", "error", "-y", *raw_options, "-i", str(path),
                 "-af", f"volume={gain:.4f}dB:precision=double", "-c:a", "pcm_f32le", str(wav)],
                check=True)
            matched = measure(wav)
            if abs(matched["lufs"] - target) > 0.11 or matched["true_peak_dbtp"] > -1:
                raise ValueError(f"unmatched loudness or excessive peak: {wav}")
            records.append({"effect": effect, "value": value, "file": wav.name,
                            "raw_sha256": sha(path), "wav_sha256": sha(wav), "raw": level,
                            "gain_db": gain, "matched": matched})
        # Revisions alone cannot prove audibility. Compare the isolated raw stereo
        # difference after the target has settled and before restoration.
        channels = []
        for path in paths:
            samples = array.array("f")
            with path.open("rb") as stream:
                stream.seek(5 * 32000 * 8)
                samples.fromfile(stream, 10 * 32000 * 2)
            if sys.byteorder != "little":
                samples.byteswap()
            channels.append(samples)
        differences = [a - b for a, b in zip(*channels)]
        delta_rms = math.sqrt(sum(x * x for x in differences) / len(differences))
        delta_peak = max(map(abs, differences))
        if not (math.isfinite(delta_rms) and delta_rms > 0 and math.isfinite(delta_peak)):
            raise ValueError(f"no finite effect difference: {effect}")
        pairs[effect] = {"clips": records, "held_delta_rms": delta_rms,
                         "held_delta_peak": delta_peak}
    receipt = {"sample_rate": 32000, "channels": 2, "seed": 1, "initial": "Focus",
               "excerpt_seconds": [24, 48], "request_seconds_in_clip": 4,
               "return_seconds_in_clip": 16, "duration_seconds": 24,
               "raw_prefix_sha256": hashlib.sha256(prefix).hexdigest(), "pairs": pairs}
    (directory / "comparison.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 tools/auditions/compare-effects.py AUDITION_DIRECTORY")
    main(Path(sys.argv[1]).resolve(strict=True))
