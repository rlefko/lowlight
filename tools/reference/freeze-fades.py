#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original rack-fade fingerprints; never invoked by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-fades.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    provenance, song, events, definitions = ORACLE["source_inputs"]()
    manifest = dict(schema_version=1, sample_rate=32000, channel_order=ORACLE["CHANNELS"],
                    tolerances=ORACLE["LIMITS"], tail_tolerances=ORACLE["TAIL_LIMITS"], gain_tolerance=ORACLE["GAIN_TOLERANCE"],
                    source="Unchanged session_render.render_song: diagnostic clocks; post-fade raw tonal and processed rhythm buses",
                    timing_songs_file="timing-songs.json", timing_cases=[], cases=[])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance):
        directory = Path(temporary)
        songs = ORACLE["timing_songs"](song)
        (directory / "timing-songs.json").write_text(json.dumps(songs, indent=2) + "\n")
        manifest["timing_songs_sha256"] = ORACLE["HELPERS"]["digest"](directory / "timing-songs.json")
        manifest["timing_cases"] = [ORACLE["timing_case"](value) for value in songs]
        (directory / "events.json").write_text(json.dumps(events, indent=2) + "\n")
        for definition in definitions:
            captured = ORACLE["capture"](song, events, definition)
            samples = captured["output"]
            ORACLE["check_structure"](samples, definition, events)
            manifest["cases"].append(dict(definition, events_sha256=ORACLE["HELPERS"]["digest"](directory / "events.json"),
                                          gain_probes=captured["gain_probes"], **ORACLE["fingerprints"](samples, definition, events)))
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze two original rack-fade bus cases and two original full-song timing captures")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true")
    freeze(parser.parse_args().replace)
