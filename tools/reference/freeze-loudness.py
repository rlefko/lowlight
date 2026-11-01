#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze pinned original body loudness measurements; never run by CI."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-loudness.py")))
FIXTURES = ORACLE["FIXTURES"]


def freeze(replace):
    if (FIXTURES / "manifest.json").exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle; --replace requires explicit fixture review")
    import numpy as np
    provenance = json.loads((ORACLE["HERE"] / "provenance.json").read_text())
    manifest = dict(schema_version=1, sample_rate=32000, channels=2, maximum_lufs_error=ORACLE["LUFS_ERROR"],
                    minimum_frames=12800, maximum_frames=5792000, maximum_input_magnitude=1e6, cases=[])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=FIXTURES) as temporary, ORACLE["HELPERS"]["reference"](provenance):
        directory = Path(temporary)
        manifest["reference"] = ORACLE["source_metadata"]()
        music, manifest["musical_source"] = ORACLE["musical_input"]()
        for definition in ORACLE["definitions"]():
            samples = music if "input_file" in definition else ORACLE["synthetic"](definition)
            expected, diagnostics = ORACLE["measure"](samples)
            ORACLE["validate_result"](expected)
            case = dict(definition, expected=expected, diagnostics=diagnostics,
                        input_float32_sha256=ORACLE["digest_samples"](samples))
            if "input_file" in case:
                np.asarray(samples, dtype="<f4").tofile(directory / case["input_file"])
            manifest["cases"].append(case)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
        for path in directory.iterdir():
            path.replace(FIXTURES / path.name)
    print(f"Froze {len(manifest['cases'])} independent original loudness cases")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true")
    freeze(parser.parse_args().replace)
