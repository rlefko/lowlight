#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Rederive imported note spans from unchanged original voice expressions."""
import argparse
import ast
import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
HELPERS = runpy.run_path(str(HERE / "verify-tonal.py"))
ROOT = HELPERS["ROOT"]
FIXTURES = ROOT / "tests/fixtures/reference-timing-v9"
EVENTS = ROOT / "tests/fixtures/v9/events.json"


def original_expressions():
    path = HERE / "v9/render_room.py"
    module = ast.parse(path.read_text())
    functions = {node.name: node for node in module.body if isinstance(node, ast.FunctionDef)}
    def assignment(function, name):
        return next(node.value for node in functions[function].body if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == name for target in node.targets))
    expressions = {"onset": assignment("place", "a"), "harmonic_hold": assignment("voice", "hold"),
                   "harmonic_span": assignment("voice", "n").args[1],
                   "bass_hold": assignment("bass_voice", "hold"), "bass_span": assignment("bass_voice", "n")}
    return {name: compile(ast.Expression(value), str(path), "eval") for name, value in expressions.items()}


def endpoints(event):
    expressions = original_expressions()
    scope = dict(FS=32000, e=event, seconds=event["time"])
    start = eval(expressions["onset"], scope)
    if event["instrument"] in ("guitar", "piano", "bass"):
        kind = "bass" if event["instrument"] == "bass" else "harmonic"
        hold = eval(expressions[kind + "_hold"], scope)
        scope["hold"] = hold
        span = eval(expressions[kind + "_span"], scope)
        return dict(start_frame=start, gate_end_frame=start + hold, release_end_frame=start + span)
    # Supported one-shots ignore gates; retain their established serialized spans.
    return dict(start_frame=start, gate_end_frame=round((event["time"] + event["duration"]) * 32000),
                release_end_frame=round((event["time"] + event["duration"] + event["release"]) * 32000))


def probe_definitions():
    probes = []
    def add(name, instrument, start, duration, release, origin=0, rejected=False):
        role = "chord" if instrument in ("guitar", "piano") else "bass" if instrument == "bass" else "drum"
        note = dict(guitar=64, piano=60, bass=41, kick=0, snare=1, hat=0, shaker=0)[instrument]
        probes.append(dict(id=name, rejected=rejected, event=dict(instrument=instrument, role=role,
            articulation="normal", note=note, round_robin=0, beat=0, velocity=.5, pan=0,
            time=(origin + start) / 32000, local_time=start / 32000,
            duration=duration / 32000, release=release / 32000)))
    add("guitar-even-half", "guitar", 100.25, 2.5, .5)
    add("piano-odd-halves", "piano", 100.5, 1.5, 1.5)
    add("guitar-release-half", "guitar", 200.75, 100.5, 2.5)
    add("piano-zero-release", "piano", 300.5, 3.5, 0)
    add("guitar-sample-clamp", "guitar", 1.25, 320000, 6400)
    add("bass-even-half-combined", "bass", 100.25, 2.5, .5)
    add("bass-odd-halves-combined", "bass", 100.5, 1.5, 1.5)
    add("bass-zero-release", "bass", 300.5, 3.5, 0)
    add("bass-oscillator-beyond-sample", "bass", 1.25, 128000, 3200)
    for instrument in ("kick", "snare", "hat", "shaker"):
        add(instrument + "-unused-gates", instrument, 100.25, 2.5, .5)
    add("absolute-onset-preserved", "guitar", 100.25, 2.5, .5, origin=1048576.5)
    add("zero-rounded-hold-rejected", "guitar", 100.25, .5, 1.5, rejected=True)
    return probes


def realized(renderer, event):
    """Observe actual unmodified functions, separately from the extracted expressions."""
    import numpy as np
    instrument = event["instrument"]
    observed = {}
    if instrument in ("guitar", "piano", "bass"):
        function = renderer.bass_voice if instrument == "bass" else renderer.voice
        lines = Path(function.__code__.co_filename).read_text().splitlines()
        before = next((i for i, line in enumerate(lines, 1) if line.startswith("    hold=round(e['duration']*FS);n=")), None)
        def trace(frame, kind, argument):
            if frame.f_code is not function.__code__:
                return None
            if kind == "line" and frame.f_lineno == before:
                observed["source_frames"] = len(frame.f_locals["x"])
            if kind == "return":
                observed.update(hold_frames=frame.f_locals["hold"], realized_frames=len(argument))
                if instrument == "bass":
                    observed["source_frames"] = len(frame.f_locals["natural"])
            return trace
        previous = sys.gettrace()
        try:
            sys.settrace(trace)
            output = function(event) if instrument == "bass" else function(event, dict(warmth=.78))
        finally:
            sys.settrace(previous)
        expected = endpoints(event)
        span = expected["release_end_frame"] - expected["start_frame"]
        assert observed["hold_frames"] == expected["gate_end_frame"] - expected["start_frame"]
        assert len(output) == (span if instrument == "bass" else min(observed["source_frames"], span))
        assert output.shape == (len(output), 2) and np.isfinite(output).all()
        observed["requested_frames"] = span
    else:
        def render(duration, release):
            buffer = np.zeros((262144, 2), np.float32)
            renderer.ins.add_note(buffer, instrument, event["note"], event["local_time"], duration,
                                  event["velocity"], event["pan"], event["round_robin"], release_seconds=release)
            return buffer
        short, long = render(event["duration"], event["release"]), render(16, 5)
        assert np.array_equal(short.view(np.uint32), long.view(np.uint32)) and np.any(short)
        observed["short_long_gate_pcm_bit_identical"] = True
    return observed


def derive(renderer):
    events = json.loads(EVENTS.read_text())
    expected = [endpoints(event) for event in events]
    changes = []
    for index, (event, output) in enumerate(zip(events, expected)):
        gate = round((event["time"] + event["duration"]) * 32000)
        end = round((event["time"] + event["duration"] + event["release"]) * 32000)
        if (gate, end) != (output["gate_end_frame"], output["release_end_frame"]):
            changes.append(dict(index=index, instrument=event["instrument"],
                gate_delta=output["gate_end_frame"] - gate, release_endpoint_delta=output["release_end_frame"] - end))
    probes = []
    for definition in probe_definitions():
        result = endpoints(definition["event"])
        if definition["rejected"]:
            assert result["gate_end_frame"] == result["start_frame"]
        probes.append(dict(definition, expected=None if definition["rejected"] else result,
                           observed=realized(renderer, definition["event"])))
    return dict(events=expected, changed_from_absolute_endpoints=changes, probes=probes)


def source_hashes():
    return {str(path.relative_to(ROOT)): HELPERS["digest"](path)
            for path in (EVENTS, HERE / "v9/render_room.py", HERE / "v9/instruments.py")}


def load_manifest():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    provenance = json.loads((HERE / "provenance.json").read_text())
    if any(manifest.get(key) != value for key, value in dict(schema_version=1, sample_rate=32000,
            frame_tolerance=0, source_sha256=source_hashes()).items()):
        raise ValueError("Changed reference timing schema or provenance")
    for name, expected in provenance["files"].items():
        if name.startswith("tools/reference/v9/") and HELPERS["digest"](ROOT / name) != expected:
            raise ValueError("Changed original v9 source")
    if len(manifest.get("events", [])) != 621 or len(manifest.get("probes", [])) != 15:
        raise ValueError("Changed reference timing inventory")
    if any(type(probe.get("rejected")) is not bool for probe in manifest["probes"]):
        raise ValueError("Invalid reference timing rejection flag")
    for row in manifest["events"] + [probe["expected"] for probe in manifest["probes"] if not probe["rejected"]]:
        if type(row) is not dict or set(row) != {"start_frame", "gate_end_frame", "release_end_frame"} or any(type(value) is not int for value in row.values()):
            raise ValueError("Incorrect reference endpoint schema")
        if not 0 <= row["start_frame"] < row["gate_end_frame"] <= row["release_end_frame"] <= 1 << 52:
            raise ValueError("Out-of-range reference endpoints")
    for probe, definition in zip(manifest["probes"], probe_definitions()):
        if any(probe.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed reference timing probe")
        if probe["rejected"] and probe["expected"] is not None:
            raise ValueError("Changed zero-hold rejection")
    if {path.name for path in FIXTURES.iterdir()} != {"README.md", "manifest.json"}:
        raise ValueError("Unexpected or missing reference timing fixture")
    return manifest, provenance


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integrity", action="store_true")
    args = parser.parse_args()
    try:
        manifest, provenance = load_manifest()
        if not args.integrity:
            with HELPERS["reference"](provenance) as renderer:
                expected = derive(renderer)
            if any(manifest[key] != value for key, value in expected.items()):
                raise ValueError("Original reference timing no longer matches the frozen oracle")
        print("Verified 621 exact imported endpoint records and 15 original timing probes" + (" (integrity)" if args.integrity else ""))
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
