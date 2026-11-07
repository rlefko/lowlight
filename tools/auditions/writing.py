#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Capture the fixed native writing audit and continuous reference performances."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / ".build"
SECONDS = {"focus": 600, "reflective": 120, "commute": 120}


def fingerprint(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def summarize(scores):
    presets = ("Focus", "Relax", "Commute", "Workout", "Reflective")
    if len(scores) != 320:
        raise ValueError("incomplete 320-song audit")
    result = {}
    for preset in presets:
        rows = [r for r in scores if r["preset"] == preset]
        expected = {(seed, index) for seed in (91031, 17, 509, 8731) for index in range(16)}
        if {(r["seed"], r["index"]) for r in rows} != expected:
            raise ValueError(f"incomplete {preset} audit")
        result[preset] = {
            "pieces": len(rows),
            "distinct_lead_rhythms_per_piece_median": statistics.median(r["distinctLeadRhythms"] for r in rows),
            "comparable_bars": sum(r["comparisons"] for r in rows),
            "repeated_lead_bars": sum(r["sameLeadAtEightBars"] for r in rows),
            "repeated_bass_bars": sum(r["sameBassAtEightBars"] for r in rows),
            "lead_bars_at_rest": sum(r["silentLeadBars"] for r in rows),
            "instrument_entrances_after_bar_of_rest": sum(r["returningPlayers"] for r in rows),
            "ascending_second_notes": sum(r["ascendingSecondNotes"] for r in rows),
            "bars_with_multiple_lead_notes": sum(r["multiNoteBars"] for r in rows),
            "max_events": max(r["events"] for r in rows),
        }
    return result


def capture(destination, classic):
    if BUILD not in destination.parents or destination.exists():
        raise ValueError("use a new output directory under this checkout's .build")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        result = Path(temp) / "capture"
        result.mkdir()
        env = dict(os.environ, LOWLIGHT_WRITING_CAPTURE=str(result), LOWLIGHT_WRITING_EDITION="1" if classic else "2",
                   TOOLCHAINS="com.apple.dt.toolchain.Xcode")
        subprocess.run(["xcrun", "swift", "test", "-c", "release", "--package-path", "Packages/LowlightAudio",
                        "--scratch-path", ".build/WritingAudio", "--filter", "WritingEvidenceTests/capture"],
                       cwd=ROOT, env=env, check=True)
        scores = result / "scores.json"
        records = summarize(json.loads(scores.read_text()))
        audio = {}
        durations = SECONDS if classic else {**SECONDS, "original-palette": 105}
        for name, seconds in durations.items():
            path = result / (name + ".f32")
            if path.stat().st_size != seconds * 32000 * 2 * 4:
                raise ValueError(f"incomplete {name} PCM")
            audio[name] = {"seconds": seconds, "pcm_sha256": fingerprint(path)}
        manifest = {"edition": 1 if classic else 2, "format": "32 kHz stereo interleaved Float32 little-endian", "audio": audio,
                    "scores_sha256": fingerprint(scores), "by_preset": records}
        (result / "capture.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        result.rename(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--classic", action="store_true", help="Capture the original arrangement and instruments")
    args = parser.parse_args()
    capture(args.directory.resolve(), args.classic)
