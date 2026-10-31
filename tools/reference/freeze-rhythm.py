#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original rhythm bus fingerprints; never invoked by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-rhythm.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    provenance, song, scores, energies = ORACLE["source_inputs"]()
    manifest = {"schema_version": 1, "sample_rate": 32000, "channel_order": ORACLE["CHANNELS"],
                "tolerances": ORACLE["LIMITS"], "duck_tolerances": ORACLE["DUCK_LIMITS"],
                "source": "Unchanged session_render.render_song: raw tonal stems before rack fades; bass/drums/duck before final mixing",
                "warmth": song["parameters"]["warmth"], "cases": []}
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance) as renderer:
        directory = Path(temporary)
        for (name, frames, tail, filename, prepared), events, energy in zip(ORACLE["CONFIGS"], scores, energies):
            samples = ORACLE["render"](renderer, song, events, frames, energy)
            (directory / filename).write_text(json.dumps(events, indent=2) + "\n")
            case = dict(id=name, file=name + ".f32", frames=frames, channels=9, bytes=frames * 9 * 4,
                        energy=energy, event_count=len(events), prepared_bytes=prepared,
                        events_file=filename, events_sha256=ORACLE["HELPERS"]["digest"](directory / filename),
                        tail_silence_start_frame=tail, **ORACLE["fingerprints"](samples, events))
            ORACLE["check_structure"](samples, case, events)
            manifest["cases"].append(case)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze three original-renderer bus fingerprints; review changes before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace previously reviewed fixtures")
    freeze(parser.parse_args().replace)
