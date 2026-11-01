#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original reference-import timing before native comparisons."""
import argparse
import json
from pathlib import Path
import runpy

ORACLE = runpy.run_path(str(Path(__file__).with_name("verify-reference-timing.py")))


def freeze(replace):
    directory = ORACLE["FIXTURES"]
    path = directory / "manifest.json"
    if path.exists() and not replace:
        raise ValueError("Refusing to replace reviewed timing expectations without explicit --replace")
    provenance = json.loads((ORACLE["HERE"] / "provenance.json").read_text())
    with ORACLE["HELPERS"]["reference"](provenance) as renderer:
        result = ORACLE["derive"](renderer)
    manifest = dict(schema_version=1, sample_rate=32000, frame_tolerance=0,
                    source_sha256=ORACLE["source_hashes"](), **result)
    directory.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    print(f"Froze 621 imported endpoint records; {len(result['changed_from_absolute_endpoints'])} differ from absolute-endpoint spans")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace", action="store_true")
    freeze(parser.parse_args().replace)
