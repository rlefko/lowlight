#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original fixed song gain; never invoked by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-gain.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace reviewed gain fixtures without explicit --replace")
    import numpy as np
    _, provenance = ORACLE["LOUDNESS"]["load_manifest"]()
    _, song, _, _ = ORACLE["MIX"]["source_inputs"]()
    events_path = ORACLE["ROOT"] / "tests/fixtures/v9/events.json"
    events = json.loads(events_path.read_text())
    manifest = dict(schema_version=1, sample_rate=32000, channels=2, target_lufs=-20.5,
                    minimum_measured_lufs=-70, maximum_input_magnitude=1e6, pcm_limits=ORACLE["LIMITS"],
                    scalar_limits=ORACLE["SCALAR_LIMITS"], cases=[])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance):
        directory = Path(temporary)
        source = ORACLE["capture"](song, events)
        lo, hi = 393846, 3150769
        normalized, _ = ORACLE["LOUDNESS"]["measure"](source["output"][lo:hi])
        manifest["original_source"] = dict(frames=len(source["input"]), events_count=len(events),
            events_sha256=ORACLE["HELPERS"]["digest"](events_path), body_start_frame=lo, body_end_frame=hi,
            scalars=source["scalars"], normalized_body=normalized,
            input_float32_sha256=ORACLE["LOUDNESS"]["digest_samples"](source["input"]),
            output_float32_sha256=ORACLE["LOUDNESS"]["digest_samples"](source["output"]))
        for definition in ORACLE["definitions"]():
            samples = source["input"][definition["source_frames"]] if "source_frames" in definition else ORACLE["inputs"](definition)
            captured = ORACLE["capture"](song, [], samples, definition["measured_lufs"])
            case = dict(definition, expected_scalars=captured["scalars"], input_sha256=ORACLE["LOUDNESS"]["digest_samples"](samples))
            if "input_file" in case:
                np.asarray(samples, dtype="<f4").tofile(directory / case["input_file"])
            np.asarray(captured["output"], dtype="<f4").tofile(directory / case["expected_file"])
            case["expected_sha256"] = ORACLE["HELPERS"]["digest"](directory / case["expected_file"])
            manifest["cases"].append(case)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print("Froze ten independent original fixed-gain cases")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true")
    freeze(parser.parse_args().replace)
