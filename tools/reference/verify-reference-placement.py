#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Verify explicit reference placement from unchanged local-time expressions."""
import argparse
import ast
import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
TIMING = runpy.run_path(str(HERE / "verify-reference-timing.py"))
HELPERS, ROOT = TIMING["HELPERS"], TIMING["ROOT"]
PLANNER = runpy.run_path(str(HERE / "native-plan-vectors.py"))["reference"]
BODY = runpy.run_path(str(HERE / "verify-song-body.py"))
FIXTURES = ROOT / "tests/fixtures/reference-placement-v9"
MAXIMUM = 1 << 52
MANIFEST_SHA256 = "d179e22ea4ec21d1706582a100448217bdd407c8463f9a02d8d89c218c2588c7"
DURATION_REGENERATION_SECONDS = 2e-15


def source_song():
    planner = PLANNER.SessionPlanner(91031, PLANNER.PRESETS["Focus"], True)
    planner.next_song()
    return planner.next_song()


def expressions():
    path = HERE / "v9/session_render.py"
    source = path.read_text()
    function = next(node for node in ast.parse(source).body
                    if isinstance(node, ast.FunctionDef) and node.name == "render_song")
    calls = [node for node in ast.walk(function) if isinstance(node, ast.Call)
             and isinstance(node.func, ast.Attribute)]
    arguments = [node.args[2] for node in calls if node.func.attr == "place"]
    arguments += [node.args[3] for node in calls if node.func.attr == "add_note"]
    assert len(arguments) == 3
    return dict(song_origin=BODY["expressions"]()[0]["origin"],
                voice_placement_arguments=[ast.get_source_segment(source, node) for node in arguments],
                local_onset="round(seconds*FS)",
                percussion_metadata="origin + round((local_time + duration [+ release])*FS)")


def endpoints(event, origin):
    # Original voice duration expressions are retained; only their placement clock
    # comes from render_song's local_time argument rather than the event's time.
    local = TIMING["endpoints"](dict(event, time=event["local_time"]))
    return {key: value + origin for key, value in local.items()}


def definitions():
    result = []
    def add(name, instrument, local, duration, release, origin=37, rejected=False):
        harmonic = instrument in ("guitar", "piano")
        event = dict(instrument=instrument, role="chord" if harmonic else "bass" if instrument == "bass" else "drum",
                     articulation="normal", note=dict(guitar=64, piano=60, bass=41, kick=0, snare=1, hat=0, shaker=0)[instrument],
                     round_robin=0, beat=0, velocity=.5, pan=0, time=(4096.75 + local) / 32000,
                     local_time=local / 32000, duration=duration / 32000, release=release / 32000)
        result.append(dict(id=name, events=[event], frame_origin=origin, rejected=rejected))
    add("guitar-even-onset", "guitar", 100.5, 2.5, .5)
    add("piano-odd-onset", "piano", 101.5, 1.5, 1.5)
    add("bass-combined-span", "bass", 100.25, 1.5, 1.5)
    add("zero-placement", "guitar", 100.25, 2.5, .5, origin=0)
    add("large-placement", "piano", 100.25, 3.5, 0, origin=1 << 40)
    for instrument in ("kick", "snare", "hat", "shaker"):
        add(instrument + "-local-metadata", instrument, 100.25, 2.5, .5)
    add("exact-frame-limit", "guitar", 100.5, 3.5, 0, origin=MAXIMUM - 104)
    add("endpoint-overflow", "guitar", 100.5, 3.5, 0, origin=MAXIMUM - 103, rejected=True)
    add("negative-origin", "guitar", 0, 1, 0, origin=-1, rejected=True)
    add("origin-overflow", "guitar", 0, 1, 0, origin=MAXIMUM + 1, rejected=True)
    add("zero-rounded-hold", "guitar", 100.25, .5, 1.5, rejected=True)
    first = dict(result[0]["events"][0], time=1e12, local_time=100.75 / 32000)
    second = dict(first, local_time=100.25 / 32000)
    result.append(dict(id="rounded-local-order", events=[first, second], frame_origin=37, rejected=True))
    return result


def original_observations(renderer):
    """Observe the actual unchanged placement functions at bounded local offsets."""
    import numpy as np
    observations = []
    for instrument in ("guitar", "piano", "bass", "kick", "snare", "hat", "shaker"):
        event = next(row["events"][0] for row in definitions() if row["events"][0]["instrument"] == instrument)
        function = renderer.place if instrument in ("guitar", "piano", "bass") else renderer.ins.add_note
        found = {}
        def trace(frame, kind, _argument):
            if frame.f_code is not function.__code__:
                return None
            if kind == "return":
                found.update(local_start_frame=frame.f_locals["a"], placed_frames=frame.f_locals["n"])
            return trace
        previous = sys.gettrace()
        buffer = np.zeros((32768, 2), np.float32)
        try:
            sys.settrace(trace)
            if function is renderer.place:
                function(buffer, np.array([[.25, -.5], [.125, -.25]], np.float32), event["local_time"])
            else:
                function(buffer, instrument, event["note"], event["local_time"], event["duration"],
                         event["velocity"], event["pan"], event["round_robin"], release_seconds=event["release"])
        finally:
            sys.settrace(previous)
        assert found["local_start_frame"] == endpoints(event, 0)["start_frame"] and np.any(buffer)
        observations.append(dict(instrument=instrument, **found))
    return observations


def validate_regenerated_events(events, regenerated, origin):
    if len(events) != len(regenerated):
        raise ValueError("Changed original later-song event count")
    for frozen, actual in zip(events, regenerated):
        # Subtracting nearby log1p ramp times differs by 1.78e-15 seconds
        # between the frozen macOS and Linux libm. No other field may drift.
        if (type(frozen["duration"]) is not float or type(actual["duration"]) is not float
                or not abs(frozen["duration"] - actual["duration"]) <= DURATION_REGENERATION_SECONDS
                or not BODY["same"](frozen, dict(actual, duration=frozen["duration"]))):
            raise ValueError("Changed original later-song events")
    expected = [endpoints(event, origin) for event in events]
    if expected != [endpoints(event, origin) for event in regenerated]:
        raise ValueError("Changed regenerated exact placement endpoints")
    def disagreements(rows):
        return [index for index, event in enumerate(rows)
                if round(event["time"] * 32000) != expected[index]["start_frame"]]
    if disagreements(events) != disagreements(regenerated):
        raise ValueError("Changed regenerated absolute/local disagreements")


def derive(events):
    song = source_song()
    origin = BODY["original_layout"](song)["origin_frame"]
    validate_regenerated_events(events, PLANNER.make_events(song), origin)
    cases = [dict(id="original-song-1", events_file="events.json", frame_origin=origin,
                  expected=[endpoints(event, origin) for event in events])]
    probes = [dict(row, expected=None if row["rejected"] else [endpoints(event, row["frame_origin"]) for event in row["events"]])
              for row in definitions()]
    differences = [index for index, event in enumerate(events)
                   if round(event["time"] * 32000) != cases[0]["expected"][index]["start_frame"]]
    return dict(source_song=song, layout=BODY["original_layout"](song), cases=cases, probes=probes,
                absolute_onset_difference_indices=differences)


def sources():
    paths = ["session_render.py", "session_planner.py", "room_composer.py", "render_room.py", "instruments.py"]
    return {"tools/reference/v9/" + name: HELPERS["digest"](HERE / "v9" / name) for name in paths}


def load_manifest():
    read = BODY["read_json"]
    if HELPERS["digest"](FIXTURES / "manifest.json") != MANIFEST_SHA256:
        raise ValueError("Changed frozen placement manifest")
    manifest, events = read(FIXTURES / "manifest.json"), read(FIXTURES / "events.json")
    expected = dict(schema_version=1, sample_rate=32000, frame_tolerance=0, maximum_frame=MAXIMUM,
                    source_sha256=sources(), events_sha256=HELPERS["digest"](FIXTURES / "events.json"),
                    expressions=expressions(), **derive(events))
    if set(manifest) != set(expected) | {"original_call_observations"} or any(
            not BODY["same"](manifest[key], value) for key, value in expected.items()):
        raise ValueError("Changed reference placement schema, source, events, or exact endpoints")
    provenance = read(HERE / "provenance.json")
    for path, digest in provenance["files"].items():
        if path.startswith("tools/reference/v9/") and HELPERS["digest"](ROOT / path) != digest:
            raise ValueError("Changed original v9 source")
    for case in manifest["cases"] + [p for p in manifest["probes"] if not p["rejected"]]:
        for row in case["expected"]:
            if set(row) != {"start_frame", "gate_end_frame", "release_end_frame"} or any(type(x) is not int for x in row.values()):
                raise ValueError("Invalid endpoint schema")
            if not 0 <= row["start_frame"] < row["gate_end_frame"] <= row["release_end_frame"] <= MAXIMUM:
                raise ValueError("Invalid endpoint bounds")
    if {p.name for p in FIXTURES.iterdir()} != {"README.md", "manifest.json", "events.json"}:
        raise ValueError("Unexpected placement fixture inventory")
    return manifest, provenance


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integrity", action="store_true")
    args = parser.parse_args()
    try:
        manifest, provenance = load_manifest()
        if not args.integrity:
            with HELPERS["reference"](provenance) as renderer:
                if original_observations(renderer) != manifest["original_call_observations"]:
                    raise ValueError("Changed original placement function observations")
        print("Verified 738 exact later-song placements, 15 boundary probes, and original local-time provenance" +
              (" (integrity)" if args.integrity else " with seven original function observations"))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        sys.exit(str(error))
