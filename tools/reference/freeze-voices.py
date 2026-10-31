#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze the accepted tonal score prefix; never called by CI."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import tempfile

HELPERS = runpy.run_path(str(Path(__file__).with_name("verify-voices.py")))
FIXTURES = HELPERS["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    provenance, events, warmth = HELPERS["source_inputs"]()
    import numpy as np
    import soundfile as sf
    with HELPERS["HELPERS"]["reference"](provenance) as renderer:
        samples = HELPERS["render"](renderer, events, warmth)
        quantized = HELPERS["render"](renderer, events, warmth, absolute_endpoints=True)
        keys = {(e["instrument"], e["note"], e["round_robin"] % 4 if e["instrument"] == "guitar" else 0) for e in events}
        prepared_bytes = sum((renderer.guitar(note, rr, warmth) if instrument == "guitar" else renderer.piano(note, warmth)).nbytes
                             for instrument, note, rr in keys)
        endpoints = []
        for event in events:
            start = round(event["time"] * 32000)
            end = start + len(renderer.voice(event, {"warmth": warmth}))
            endpoints.extend(((start, 1), (end, -1)))
        active = peak = 0
        for _, change in sorted(endpoints):
            active += change
            peak = max(peak, active)
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary:
        directory = Path(temporary)
        (directory / "events.json").write_text(json.dumps(events, indent=2) + "\n")
        sf.write(directory / "voice-prefix.flac", samples, 32000, subtype="PCM_24")
        manifest = {"schema_version": 1, "source": "Unmodified v9 render_room.voice and place; first eight seconds of tonal note-ons plus tails",
                    "sample_rate": 32000, "frames": 384000, "channels": 2, "warmth": warmth, "event_count": len(events),
                    "tolerances": HELPERS["LIMITS"], "prepared_sample_count": len(keys), "prepared_bytes": prepared_bytes,
                    "peak_active_voices": peak, "tail_silence_start_frame": max(frame for frame, _ in endpoints),
                    "events_file": "events.json", "events_sha256": HELPERS["HELPERS"]["digest"](directory / "events.json"),
                    "fixture_file": "voice-prefix.flac", "fixture_sha256": HELPERS["HELPERS"]["digest"](directory / "voice-prefix.flac"),
                    "full_float32_sha256": hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
                    "reference": HELPERS["measures"](samples),
                    "absolute_endpoint_rounding_difference": HELPERS["HELPERS"]["compare"](quantized, samples, HELPERS["LIMITS"], "endpoint quantization")}
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze 21 tonal events and a 12-second dry reference; review fixture changes before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace a previously reviewed oracle")
    freeze(parser.parse_args().replace)
