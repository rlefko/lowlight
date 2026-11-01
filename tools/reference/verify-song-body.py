#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Verify finite song layouts and fresh-body loudness against unchanged sources."""
import argparse
import ast
import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
METER = runpy.run_path(str(HERE / "verify-loudness.py"))
HELPERS, ROOT = METER["HELPERS"], METER["ROOT"]
PLANNER = runpy.run_path(str(HERE / "native-plan-vectors.py"))["reference"]
FIXTURES = ROOT / "tests/fixtures/song-body-v9"
LUFS_ERROR = 1e-5
LAYOUT_KEYS = {"origin_frame", "input_frames", "body_start_frame", "body_end_frame"}
MUSIC = ROOT / "tests/fixtures/loudness-v9/song-body.f32"


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result
    def constant(_value):
        raise ValueError("Nonfinite JSON constant")
    return json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=constant)


def same(left, right):
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def expressions():
    source = (HERE / "v9/session_render.py").read_text()
    functions = {node.name: node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef)}
    def value(function, name):
        return next(node.value for node in ast.walk(functions[function]) if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == name for target in node.targets))
    nodes = {name: value("render_song", name) for name in ("n", "lo", "hi", "out_start")}
    nodes["origin"] = value("render_session", "start")
    nodes["body_slice"] = value("render_song", "measured").args[0]
    return ({key: ast.get_source_segment(source, node) for key, node in nodes.items()},
            {key: compile(ast.Expression(node), "unchanged session_render.py", "eval") for key, node in nodes.items()})


def original_layout(song):
    _, code = expressions()
    scope = dict(song=song, duration=song["duration_seconds"], FS=32000, local_seconds=PLANNER.local_seconds)
    scope["out_start"] = eval(code["out_start"], scope)
    return {field: eval(code[name], scope) for field, name in (
        ("origin_frame", "origin"), ("input_frames", "n"),
        ("body_start_frame", "lo"), ("body_end_frame", "hi"))}


def layouts():
    result = []
    planner = PLANNER.SessionPlanner(91031, PLANNER.PRESETS["Focus"], True)
    timing_keys = ("id", "bars", "tempo", "previous_tempo", "next_tempo", "start_seconds", "duration_seconds")
    for index in range(72):
        song = planner.next_song()
        result.append(dict(id=f"reference-{index:02}", kind="reference",
                           timing={key: song[key] for key in timing_keys}, expected=original_layout(song)))
    timing = dict(result[0]["timing"], duration_seconds=123.000078125)
    result.append(dict(id="reference-tail-half", kind="reference-expression", timing=timing,
                       expected=original_layout(timing)))
    chains = read_json(ROOT / "tests/fixtures/planning-v1/events.json")["chains"]
    selections = [(0, 0, None), (1, 1, None), (1, 2, None),
                  (1, 1, 96 + .25 / 32000), (1, 1, 96 + .5 / 32000)]
    for number, (chain_index, selected, override) in enumerate(selections):
        plans = chains[chain_index]["plans"]
        origin = 0.
        for index in range(selected + 1):
            song, successor = plans[index:index + 2]
            if index == selected and override is not None:
                origin = override
            previous = plans[index - 1]["tempo"] if index else song["tempo"]
            # Native-v1 keeps absolute shared ramps; original integration supplies
            # each ramp's elapsed seconds, without re-rounding local durations.
            lo = origin + PLANNER.ramp_seconds(16, previous, song["tempo"])
            hi = lo + (song["bars"] * 4 - 32) * 60 / song["tempo"]
            end = hi + PLANNER.ramp_seconds(16, song["tempo"], successor["tempo"])
            if index == selected:
                start = round(origin * 32000)
                expected = dict(origin_frame=start, input_frames=round(end * 32000) - start + 160000,
                                body_start_frame=round(lo * 32000) - start,
                                body_end_frame=round(hi * 32000) - start)
                row = dict(id=f"native-{number}", kind="native", chain_index=chain_index,
                           schedule_index=selected, expected=expected)
                if override is not None:
                    row["incoming_origin_seconds"] = override
                result.append(row)
            origin = hi
    return result


def definitions():
    def case(name, frames, lo, hi, outside, recipe):
        return dict(id=name, file=name + ".json", layout=dict(origin_frame=0, input_frames=frames,
            body_start_frame=lo, body_end_frame=hi), outside=outside, recipe=recipe)
    return [case("body-fresh-silence", 20001, 4097, 16897, [3.5, -2.75], dict(kind="silence")),
            case("body-half-tie", 24369, 257, 24257, [-.75, .625], dict(kind="pattern")),
            case("body-levels", 64163, 1, 64001, [1.5, -1.25], dict(kind="levels", levels=[
                dict(start=0, scale=1), dict(start=16000, scale=1 / 512),
                dict(start=32000, scale=1 / 16), dict(start=48000, scale=0)])),
            case("body-original-excerpt", 36610, 4097, 36097, [.875, -.5],
                 dict(kind="file", file=str(MUSIC.relative_to(ROOT)), sha256=HELPERS["digest"](MUSIC)))]


def samples(case):
    import numpy as np
    layout, recipe = case["layout"], case["recipe"]
    lo, hi = layout["body_start_frame"], layout["body_end_frame"]
    data = np.empty((layout["input_frames"], 2), np.float32)
    data[:] = case["outside"]
    body = data[lo:hi]
    if recipe["kind"] == "file":
        body[:] = np.fromfile(ROOT / recipe["file"], dtype="<f4").reshape(-1, 2)
    elif recipe["kind"] == "silence":
        body[:] = 0
    else:
        indices = np.arange(len(body))
        body[:, 0] = ((indices % 31) - 15).astype(np.float32) / np.float32(64)
        body[:, 1] = ((indices % 17) - 8).astype(np.float32) / np.float32(32)
        if recipe["kind"] == "levels":
            for level, end in zip(recipe["levels"], [row["start"] for row in recipe["levels"][1:]] + [len(body)]):
                body[level["start"]:end] *= np.float32(level["scale"])
    return data


def measure(case):
    data = samples(case)
    layout = case["layout"]
    crop = eval(expressions()[1]["body_slice"], dict(mix=data, lo=layout["body_start_frame"], hi=layout["body_end_frame"]))
    expected, details = METER["measure"](crop)
    return dict(expected=expected, input_sha256=METER["digest_samples"](data),
                body_sha256=METER["digest_samples"](crop),
                absolute_indices=details["absolute_indices"], relative_indices=details["relative_indices"])


def sources():
    paths = [HERE / "v9/session_render.py", HERE / "v9/session_planner.py", HERE / "v9/room_composer.py",
             ROOT / "tests/fixtures/planning-v1/events.json", ROOT / "tests/fixtures/loudness-v9/manifest.json", MUSIC]
    return {str(path.relative_to(ROOT)): HELPERS["digest"](path) for path in paths}


def validate_layout(value):
    if type(value) is not dict or set(value) != LAYOUT_KEYS or any(type(x) is not int for x in value.values()):
        raise ValueError("Invalid song layout schema")
    origin, frames, lo, hi = (value[key] for key in ("origin_frame", "input_frames", "body_start_frame", "body_end_frame"))
    if not 0 <= origin <= (1 << 52) - frames or not 1 <= frames <= 5792000 or not 0 <= lo < hi <= frames or hi - lo < 12800:
        raise ValueError("Invalid finite song layout bounds")


def load_manifest():
    manifest = read_json(FIXTURES / "manifest.json")
    required = dict(schema_version=1, sample_rate=32000, channels=2, frame_tolerance=0,
                    maximum_lufs_error=LUFS_ERROR, maximum_input_frames=5792000,
                    source_sha256=sources(), expressions=expressions()[0], layouts=layouts(),
                    pyloudnorm_source_sha256=METER["SOURCE_HASHES"])
    if set(manifest) != set(required) | {"cases"} or any(not same(manifest[key], value) for key, value in required.items()):
        raise ValueError("Changed song-body format, source, expression, or exact layout")
    provenance = read_json(HERE / "provenance.json")
    for path, digest in provenance["files"].items():
        if path.startswith("tools/reference/v9/") and HELPERS["digest"](ROOT / path) != digest:
            raise ValueError("Changed original v9 source")
    for row in manifest["layouts"]:
        validate_layout(row["expected"])
    if len(manifest["cases"]) != len(definitions()):
        raise ValueError("Changed song-body case inventory")
    for case, definition in zip(manifest["cases"], definitions()):
        if set(case) != set(definition) | {"expected", "input_sha256", "body_sha256", "absolute_indices", "relative_indices"} or any(not same(case.get(key), value) for key, value in definition.items()):
            raise ValueError("Changed song-body recipe")
        validate_layout(case["layout"])
        METER["validate_result"](case["expected"])
        if case["expected"]["input_frames"] != case["layout"]["body_end_frame"] - case["layout"]["body_start_frame"]:
            raise ValueError("Changed measured body length")
    if {path.name for path in FIXTURES.iterdir()} != {"README.md", "manifest.json"}:
        raise ValueError("Unexpected song-body fixture file")
    return manifest


def verify(manifest, candidates=None, evidence=None):
    if METER["source_metadata"]() != read_json(ROOT / "tests/fixtures/loudness-v9/manifest.json")["reference"]:
        raise ValueError("Changed original meter coefficients, rounding, or source")
    layout_records = [dict(id=row["id"], **row["expected"]) for row in manifest["layouts"]]
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {"layouts.json"} | {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing song-body candidate")
        actual = read_json(candidates / "layouts.json")
        if type(actual) is not list or len(actual) != len(layout_records):
            raise ValueError("Changed native layout inventory")
        for row in actual:
            validate_layout({key: value for key, value in row.items() if key != "id"})
        if actual != layout_records:
            raise ValueError("Native layout differs from exact frozen timing")
    results = []
    for case in manifest["cases"]:
        reference = measure(case)
        for key in set(reference) - {"expected"}:
            if reference[key] != case[key]:
                raise ValueError("Changed original crop samples or gate membership")
        row = dict(id=case["id"], reference=reference["expected"],
                   frozen_lufs_error=METER["compare"](reference["expected"], case["expected"]))
        if candidates is not None:
            path = candidates / case["file"]
            actual = read_json(path)
            row.update(native=actual, native_lufs_error=METER["compare"](actual, reference["expected"]), native_sha256=HELPERS["digest"](path))
        results.append(row)
    report = dict(maximum_lufs_error=LUFS_ERROR, exact_layout_count=len(layout_records),
                  layouts=layout_records, results=results)
    if candidates is not None:
        report["native_layouts_sha256"] = HELPERS["digest"](candidates / "layouts.json")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "comparison.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps(report, indent=2, allow_nan=False))
    print("Verified 78 exact song layouts and four fresh-body measurements" + (" against native results" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--compare", type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest = load_manifest()
        if args.integrity:
            print("Frozen song-body integrity passed: 78 exact layouts and four stream cases")
        else:
            with HELPERS["reference"](read_json(HERE / "provenance.json")):
                verify(manifest, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        sys.exit(str(error))
