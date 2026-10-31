#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze accepted bass voices and preparation provenance; never called by CI."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-bass.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    import numpy as np
    import soundfile as sf
    provenance, events = ORACLE["source_inputs"]()
    with ORACLE["HELPERS"]["reference"](provenance) as renderer:
        samples = ORACLE["render"](renderer, events)
        canonical = ORACLE["render"](renderer, events, absolute_endpoints=True)
        cases = []
        for note, rr in ORACLE["KEYS"]:
            body = ORACLE["prepared"](renderer, note, rr)
            cases.append({"note": note, "round_robin": rr, "file": f"body-{note}-{rr}.f32",
                          "frames": len(body), "channels": 1,
                          "full_float32_sha256": hashlib.sha256(np.asarray(body, dtype="<f4").tobytes()).hexdigest(),
                          "peak": float(np.max(np.abs(body))), "rms": float(np.sqrt(np.mean(body.astype(np.float64) ** 2)))})
        keys = {(event["note"], event["round_robin"] % 2) for event in events}
        prepared_bytes = sum(case["frames"] * 4 for case in cases if (case["note"], case["round_robin"]) in keys)
        endpoints = [(round(event["time"] * 32000), 1) for event in events]
        endpoints += [(round(event["time"] * 32000) + len(renderer.bass_voice(event)), -1) for event in events]
        active = peak = 0
        for _, change in sorted(endpoints):
            active += change
            peak = max(peak, active)
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary:
        directory = Path(temporary)
        (directory / "events.json").write_text(json.dumps(events, indent=2) + "\n")
        sf.write(directory / "bass-prefix.flac", samples, 32000, subtype="PCM_24")
        manifest = {"schema_version": 1, "source": "Unmodified v9 render_room.bass_voice and place; bass note-ons before 12 seconds plus tails",
                    "sample_rate": 32000, "frames": ORACLE["FRAMES"], "channels": 2, "event_count": len(events),
                    "tolerances": ORACLE["LIMITS"], "prepared_sample_count": len(keys), "prepared_bytes": prepared_bytes,
                    "peak_active_voices": peak, "tail_silence_start_frame": max(frame for frame, _ in endpoints),
                    "events_file": "events.json", "events_sha256": ORACLE["HELPERS"]["digest"](directory / "events.json"),
                    "fixture_file": "bass-prefix.flac", "fixture_sha256": ORACLE["HELPERS"]["digest"](directory / "bass-prefix.flac"),
                    "full_float32_sha256": hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
                    "reference": ORACLE["VOICES"]["measures"](samples),
                    "absolute_endpoint_rounding_difference": ORACLE["HELPERS"]["compare"](canonical, samples, ORACLE["LIMITS"], "bass endpoint quantization"),
                    "cases": cases}
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze six bass events, a 13-second dry reference, and 54 preparation cases; review before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace a previously reviewed oracle")
    freeze(parser.parse_args().replace)
