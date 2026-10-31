#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Verify native-v1 event fixtures against frozen Python logic and a separate RNG."""
import argparse
from collections import deque
from dataclasses import replace
import hashlib
import json
import math
from pathlib import Path
import runpy
import sys
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DESTINATION = ROOT / "tests/fixtures/planning-v1"
FRAME_TOLERANCE = 1
SCALAR_TOLERANCE = 1e-12
SOURCES = ["v9/session_planner.py", "v9/room_composer.py", "native-plan-vectors.py"]
sys.dont_write_bytecode = True
adapter = runpy.run_path(str(HERE / "native-plan-vectors.py"))
reference = adapter["reference"]
SplitMix = adapter["SplitMix"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_plan(song):
    names = {
        "id": "id", "family": "family", "mode": "mode", "focus": "focus",
        "key": "key", "shift": "shift", "bars": "bars", "controls": "controls",
        "energy": "energy", "tempo": "tempo", "chords": "chords", "melody": "melody",
        "melodyTimes": "melody_times", "takeSeed": "take_seed", "drumCell": "drum_cell",
        "bassCell": "bass_cell", "phraseArc": "phrase_arc",
    }
    result = {native: song[old] for native, old in names.items()}
    result["melodyTimes"] = [[int(beat) for beat in bar] for bar in result["melodyTimes"]]
    return result


def note_event(event):
    result = {key: event[key] for key in
              ["instrument", "role", "articulation", "note", "beat", "velocity", "pan"]}
    result.update(roundRobin=event["round_robin"], startFrame=round(event["time"] * 32000),
                  gateEndFrame=round((event["time"] + event["duration"]) * 32000),
                  releaseEndFrame=round((event["time"] + event["duration"] + event["release"]) * 32000))
    return result


def chain(seed, controls, selected):
    planner = reference.SessionPlanner.__new__(reference.SessionPlanner)
    planner.rng = SplitMix(seed)
    planner.seed = seed
    planner.recent_families = deque(maxlen=4)
    planner.recent_signatures = deque(maxlen=64)
    planner.index = 0
    planner.baseline_first = False
    songs = []
    for setting in controls:
        planner.controls = setting
        songs.append(planner._draft(songs[-1] if songs else None))
    songs[0].update(start_seconds=0.0, previous_tempo=songs[0]["tempo"], in_bridge=None)
    cases = []
    for index, (song, successor) in enumerate(zip(songs, songs[1:])):
        pivot = reference.bridge_between(song, successor)
        song.update(out_bridge=pivot, next_tempo=successor["tempo"])
        origin = song["start_seconds"] + reference.local_seconds(song, song["bars"] * 4 - 16)
        successor.update(start_seconds=origin, previous_tempo=song["tempo"], in_bridge=pivot)
        if index in selected:
            cases.append({
                "index": index,
                "events": [note_event(event) for event in reference.make_events(song)],
                "pivot": pivot,
                "bridgeFrames": [round((song["start_seconds"] + reference.local_seconds(
                    song, song["bars"] * 4 - 16 + quarter / 4)) * 32000) for quarter in range(65)],
            })
    return {"plans": [native_plan(song) for song in songs], "cases": cases}


def expected():
    # Only the event take selector changes; the frozen algorithm stays untouched.
    original_random = reference.random
    reference.random = SimpleNamespace(Random=SplitMix)
    try:
        focus = reference.PRESETS["Focus"]
        reflective = replace(focus, energy=0.9, mood=-0.8, tempo=60)
        bright = replace(reflective, mood=0.8, tempo=100)
        return {
            "schemaVersion": 1,
            "chains": [chain(91031, [focus, focus], [0]),
                       chain(92017, [reflective, bright, reflective, reflective], [1, 2])],
        }
    finally:
        reference.random = original_random


def compare(actual, frozen, path="fixture"):
    if isinstance(frozen, dict):
        if actual.keys() != frozen.keys():
            raise ValueError(f"Different keys: {path}")
        for key in frozen:
            compare(actual[key], frozen[key], f"{path}.{key}")
    elif isinstance(frozen, list):
        if len(actual) != len(frozen):
            raise ValueError(f"Different count: {path}")
        for index, (left, right) in enumerate(zip(actual, frozen)):
            compare(left, right, f"{path}[{index}]")
    elif isinstance(frozen, (int, float)):
        if (isinstance(actual, bool) or not isinstance(actual, (int, float))
                or not math.isfinite(actual) or not math.isfinite(frozen)):
            raise ValueError(f"Invalid numeric value: {path}")
        tolerance = FRAME_TOLERANCE if "Frame" in path else SCALAR_TOLERANCE
        if abs(actual - frozen) > tolerance:
            raise ValueError(f"Reference changed: {path}")
    elif actual != frozen:
        raise ValueError(f"Reference changed: {path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initialize", action="store_true", help="Create absent fixtures once; never overwrite")
    args = parser.parse_args()
    path = DESTINATION / "events.json"
    manifest = DESTINATION / "manifest.json"
    candidate = expected()
    if args.initialize:
        if path.exists() or manifest.exists():
            raise SystemExit("Existing oracle cannot be overwritten")
        DESTINATION.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(candidate, indent=2, sort_keys=True) + "\n")
        evidence = {"schemaVersion": 1, "frameTolerance": FRAME_TOLERANCE,
                    "scalarTolerance": SCALAR_TOLERANCE, "fixtureSHA256": digest(path),
                    "sources": {name: digest(HERE / name) for name in SOURCES}}
        manifest.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    evidence = json.loads(manifest.read_text())
    if (evidence["schemaVersion"] != 1 or evidence["frameTolerance"] != FRAME_TOLERANCE
            or evidence["scalarTolerance"] != SCALAR_TOLERANCE
            or evidence["fixtureSHA256"] != digest(path)
            or evidence["sources"] != {name: digest(HERE / name) for name in SOURCES}):
        raise SystemExit("Frozen event provenance or tolerance changed")
    compare(candidate, json.loads(path.read_text()))
    events = [event for group in candidate["chains"] for case in group["cases"] for event in case["events"]]
    print(f"Verified three independent native event scores: {len(events)} events; "
          f"{len({event['instrument'] for event in events})} instruments")
