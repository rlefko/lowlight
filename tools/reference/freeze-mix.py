#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original pre-normalization song mixes; never invoked by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-mix.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    import numpy as np
    provenance, song, events, definitions = ORACLE["source_inputs"]()
    manifest = dict(schema_version=1, sample_rate=32000, latency_frames=0, channels=2,
                    input_channel_order=ORACLE["ROOM"]["CHANNELS"], tolerances=ORACLE["LIMITS"],
                    synthetic_tolerances=ORACLE["SYNTHETIC_LIMITS"], air_tolerances=ORACLE["AIR_LIMITS"],
                    tail_tolerances=ORACLE["TAIL_LIMITS"], cases=[])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance):
        directory = Path(temporary)
        (directory / "events.json").write_text(json.dumps(events, indent=2) + "\n")
        for definition in definitions:
            captured = ORACLE["render"](song, events, definition)
            expected = captured["output"]
            ORACLE["check_structure"](expected, definition)
            case = dict(definition, input_float32_sha256=ORACLE["ROOM"]["GLUE"]["digest_samples"](captured["inputs"]),
                        **ORACLE["fingerprints"](expected, definition),
                        **{key: captured[key] for key in ("pre_air_float32_sha256", "pre_highpass_float32_sha256")})
            if "expected_file" in case:
                np.asarray(expected, dtype="<f4").tofile(directory / case["expected_file"])
                case["expected_sha256"] = ORACLE["HELPERS"]["digest"](directory / case["expected_file"])
            if "events_file" in case:
                case["events_sha256"] = ORACLE["HELPERS"]["digest"](directory / case["events_file"])
            manifest["cases"].append(case)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze ten original pre-normalization song mixes; review changes before committing")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true", help="Explicitly replace previously reviewed fixtures")
    freeze(parser.parse_args().replace)
