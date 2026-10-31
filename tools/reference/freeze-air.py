#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze unchanged quiet-air output; never invoked by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-air.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    provenance, songs, definitions = ORACLE["source_inputs"]()
    manifest = dict(schema_version=1, sample_rate=32000, channels=2, maximum_frames=5792000,
                    maximum_raw_draws_per_normal=64, tolerances=ORACLE["LIMITS"], carrier_tolerances=ORACLE["CARRIER_LIMITS"],
                    random_vectors_file="random-vectors.json", source="Unchanged session_render.render_song air stage before HP32; unchanged NumPy 2.3.5 random entry points",
                    timing_songs_sha256=ORACLE["HELPERS"]["digest"](ORACLE["ROOT"] / "tests/fixtures/fades-v9/timing-songs.json"), cases=[])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance):
        directory = Path(temporary)
        (directory / "random-vectors.json").write_text(json.dumps(ORACLE["random_vectors"](), indent=2) + "\n")
        manifest["random_vectors_sha256"] = ORACLE["HELPERS"]["digest"](directory / "random-vectors.json")
        for case in definitions:
            captured, inputs = ORACLE["render"](songs, case)
            samples = captured.pop("output")
            ORACLE["check_structure"](samples, inputs, case)
            manifest["cases"].append(dict(case, normalization=captured.pop("channels"), **captured,
                                          **ORACLE["fingerprint"](samples, case)))
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze 12 independent quiet-air cases and original NumPy random vectors")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true")
    freeze(parser.parse_args().replace)
