#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original percussion output; never invoked by CI."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-percussion.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    import numpy as np
    import soundfile as sf
    provenance, scores = ORACLE["source_inputs"]()
    manifest = {"schema_version": 1, "sample_rate": 32000, "tolerances": ORACLE["LIMITS"],
                "source": "Unmodified v9 instruments.pitched/add_note; dry one-shot percussion before bus processing",
                "bodies": [], "clips": []}
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance) as renderer:
        directory = Path(temporary)
        for definition in ORACLE["BODIES"]:
            samples = ORACLE["prepared"](renderer, definition)
            manifest["bodies"].append({**definition, "frames": len(samples), "channels": 1,
                                       "full_float32_sha256": hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
                                       "peak": float(np.max(np.abs(samples))), "rms": float(np.sqrt(np.mean(samples.astype(np.float64) ** 2)))})
        for (name, frames, tail, events_file), events in zip(ORACLE["CONFIGS"], scores):
            samples = ORACLE["render"](renderer, events, frames)
            if np.any(samples[tail:]):
                raise ValueError("Unexpected original percussion tail")
            (directory / events_file).write_text(json.dumps(events, indent=2) + "\n")
            sf.write(directory / (name + ".flac"), samples, 32000, subtype="PCM_24")
            manifest["clips"].append({"id": name, "frames": frames, "channels": 2, "event_count": len(events),
                                      "tail_silence_start_frame": tail, "prepared_bytes": 345600 if name.endswith("prefix") else 441152,
                                      "events_file": events_file, "events_sha256": ORACLE["HELPERS"]["digest"](directory / events_file),
                                      "fixture_file": name + ".flac", "fixture_sha256": ORACLE["HELPERS"]["digest"](directory / (name + ".flac")),
                                      "full_float32_sha256": hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
                                      "reference": ORACLE["VOICES"]["measures"](samples)})
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze 12 percussion preparations and two original-renderer clips; review changes before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace a previously reviewed fixture")
    freeze(parser.parse_args().replace)
