#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original song timing and fresh-body measurements; never run by CI."""
import argparse
import json
from pathlib import Path
import runpy

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-song-body.py")))


def freeze(replace):
    directory = ORACLE["FIXTURES"]
    path = directory / "manifest.json"
    if path.exists() and not replace:
        raise ValueError("Refusing to replace the reviewed oracle without explicit --replace")
    old = ORACLE["read_json"](ORACLE["ROOT"] / "tests/fixtures/loudness-v9/manifest.json")
    if ORACLE["METER"]["source_metadata"]() != old["reference"]:
        raise ValueError("Changed pinned original meter")
    manifest = dict(schema_version=1, sample_rate=32000, channels=2, frame_tolerance=0,
        maximum_lufs_error=ORACLE["LUFS_ERROR"], maximum_input_frames=5792000,
        source_sha256=ORACLE["sources"](), expressions=ORACLE["expressions"]()[0],
        layouts=ORACLE["layouts"](), pyloudnorm_source_sha256=ORACLE["METER"]["SOURCE_HASHES"],
        cases=[dict(case, **ORACLE["measure"](case)) for case in ORACLE["definitions"]()])
    directory.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    print("Froze 78 exact song layouts and four independent fresh-body measurements")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true")
    freeze(parser.parse_args().replace)
