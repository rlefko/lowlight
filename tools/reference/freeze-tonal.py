#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze short tonal oracle windows; never called by CI."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import runpy
import tempfile

HERE = Path(__file__).resolve().parent
HELPERS = runpy.run_path(str(HERE / "verify-tonal.py"))
ROOT, FIXTURES = HELPERS["ROOT"], HELPERS["FIXTURES"]
CASES = [
    ("guitar_root", "guitar", 55, 0, .78),
    ("guitar_rr_wrap", "guitar", 55, 7, .78),
    ("guitar_tie_up", "guitar", 57, 1, .78),
    ("guitar_down", "guitar", 54, 2, .78),
    ("guitar_high", "guitar", 69, 3, .78),
    ("guitar_low", "guitar", 50, 10, .78),
    ("guitar_bright", "guitar", 55, 0, 0.),
    ("guitar_warm", "guitar", 55, 0, 1.),
    ("piano_root", "piano", 60, 0, .78),
    ("piano_tie_upper", "piano", 58, 0, .78),
    ("piano_tie_lower", "piano", 54, 0, .78),
    ("piano_stereo", "piano", 64, 9, .78),
    ("piano_low", "piano", 50, 0, .78),
    ("piano_high", "piano", 69, 0, .78),
    ("piano_bright", "piano", 60, 0, 0.),
    ("piano_warm", "piano", 60, 0, 1.),
]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; use --replace only for an explicit fixture review")
    provenance = json.loads((HERE / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if name.startswith("tools/reference/v9/") and HELPERS["digest"](ROOT / name) != expected:
            raise ValueError(f"Changed frozen v9 source: {name}")
    import numpy as np
    import soundfile as sf
    FIXTURES.mkdir(parents=True, exist_ok=True)
    manifest = {"schema_version": 1, "sample_rate": 32000, "source": "Unmodified v9 render_room.guitar and render_room.piano",
                "python_version": "3.12.14", "libsndfile_version": sf.__libsndfile_version__,
                "tolerances": {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}, "cases": []}
    with HELPERS["reference"](provenance) as renderer, tempfile.TemporaryDirectory(dir=FIXTURES) as temporary:
        for name, instrument, note, rr, warmth in CASES:
            case = {"id": name, "instrument": instrument, "note": note, "round_robin": rr, "warmth": warmth}
            if instrument == "guitar":
                root = min({k[0] for k in renderer.BANK}, key=lambda r: abs(r - note))
                entry = next(e for e in renderer.ENTRIES if e["root_midi"] == root and e["round_robin"] == rr % 4)
            else:
                pool = renderer.ins.ASSETS["piano"]
                root = min((e["root_midi"] for e, _ in pool), key=lambda r: abs(r - note))
                entry = next(e for e, _ in pool if e["root_midi"] == root and e["velocity_layer"] == 1)
            samples = HELPERS["prepared"](renderer, case)
            ratio = Fraction(2 ** ((root - note) / 12)).limit_denominator(2048)
            windows = [{"start_frame": start, "frames": 1024} for start in (0, 3840, 27776, len(samples) - 1024)]
            clip = np.concatenate([samples[w["start_frame"]:w["start_frame"] + w["frames"]] for w in windows])
            path = Path(temporary) / (name + ".flac")
            sf.write(path, clip, 32000, subtype="PCM_24")
            case.update(root_midi=root, source_asset=entry["asset"], resample_numerator=ratio.numerator,
                        resample_denominator=ratio.denominator, frames=len(samples), channels=samples.shape[1],
                        full_float32_sha256=hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
                        peak=float(np.max(np.abs(samples))), rms=float(np.sqrt(np.mean(samples.astype(np.float64) ** 2))),
                        windows=windows, window_file=path.name, window_sha256=HELPERS["digest"](path))
            manifest["cases"].append(case)
        path = Path(temporary) / "manifest.json"
        path.write_text(json.dumps(manifest, indent=2) + "\n")
        for path in Path(temporary).iterdir():
            path.replace(FIXTURES / path.name)
    print(f"Froze {len(CASES)} tonal cases; review every fixture change before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace previously reviewed fixtures")
    args = parser.parse_args()
    freeze(args.replace)
