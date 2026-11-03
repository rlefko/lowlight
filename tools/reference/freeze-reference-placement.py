#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly freeze original reference placement; never run by CI."""
import argparse
import json
from pathlib import Path
import runpy

VERIFY = runpy.run_path(str(Path(__file__).with_name("verify-reference-placement.py")))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--replace", action="store_true")
parser.add_argument("--output", type=Path, default=VERIFY["FIXTURES"])
args = parser.parse_args()
output = args.output.resolve()
if output != VERIFY["FIXTURES"]:
    output = VERIFY["HELPERS"]["output_path"](output)
output.mkdir(parents=True, exist_ok=True)
if any((output / name).exists() for name in ("manifest.json", "events.json")) and not args.replace:
    parser.error("Refusing to replace frozen evidence without --replace")
events = VERIFY["PLANNER"].make_events(VERIFY["source_song"]())
(output / "events.json").write_text(json.dumps(events, indent=2, allow_nan=False) + "\n")
with VERIFY["HELPERS"]["reference"](json.loads((VERIFY["HERE"] / "provenance.json").read_text())) as renderer:
    observations = VERIFY["original_observations"](renderer)
manifest = dict(schema_version=1, sample_rate=32000, frame_tolerance=0, maximum_frame=VERIFY["MAXIMUM"],
                source_sha256=VERIFY["sources"](), events_sha256=VERIFY["HELPERS"]["digest"](output / "events.json"),
                expressions=VERIFY["expressions"](), original_call_observations=observations, **VERIFY["derive"](events))
(output / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
print("Frozen 738 original later-song placements and 15 boundary probes")
