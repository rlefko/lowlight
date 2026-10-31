#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original linked-peak outputs; never invoked by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-peak.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    import numpy as np
    provenance, song, events, definitions = ORACLE["source_inputs"]()
    manifest = dict(schema_version=1, sample_rate=32000, latency_frames=160, channels=2,
                    tolerances=ORACLE["LIMITS"], cases=[])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance):
        directory = Path(temporary)
        cache = {}
        for definition in definitions:
            expected, inputs, _ = ORACLE["render"](song, events, definition, cache)
            case = dict(definition, file=definition["id"] + ".f32", channels=2, bytes=len(expected) * 8,
                        input_float32_sha256=ORACLE["digest_samples"](inputs),
                        **ORACLE["fingerprints"](expected, definition))
            for kind, samples in (("input", cache.get("song", {}).get("input")), ("expected", expected)):
                if kind + "_file" in case:
                    np.asarray(samples, dtype="<f4").tofile(directory / case[kind + "_file"])
                    case[kind + "_sha256"] = ORACLE["HELPERS"]["digest"](directory / case[kind + "_file"])
            manifest["cases"].append(case)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze 14 original linked-peak cases; review changes before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace previously reviewed fixtures")
    freeze(parser.parse_args().replace)
