#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare one fixed song gain with the unchanged original normalization statement."""
import argparse
import ast
import copy
import importlib
import json
import math
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
LOUDNESS = runpy.run_path(str(HERE / "verify-loudness.py"))
MIX, HELPERS, ROOT = LOUDNESS["MIX"], LOUDNESS["HELPERS"], LOUDNESS["ROOT"]
FIXTURES = ROOT / "tests/fixtures/gain-v9"
LIMITS = dict(maximum_absolute_error=6e-8, rms_error=1e-8)
SCALAR_LIMITS = dict(gain_db_absolute_error=1e-12, linear_gain_relative_error=2e-15)
BOUNDARIES = [0, 1, 160, 12799, 12800, 393845, 393846, 393847, 425845,
              3150768, 3150769, 3150770, 3349493, 3551910, 3551911, 3551912, 3711909, 3711910]


def definitions():
    previous, _ = LOUDNESS["load_manifest"]()
    levels = {case["id"]: case["expected"]["lufs"] for case in previous["cases"]}
    samples = [[0, -0.0], [1, -1], [.1, -.1], [.00021612727141473442, -.00021612727141473442],
               [2, -2], [1e-12, -1e-12], [.14713357388973236, -.03125],
               [1.0000001192092896, .9999999403953552]]
    cases = [dict(id="gain-" + name, measured_lufs=level, input_samples=samples, frames=len(samples), exact_pcm=True)
             for name, level in [("floor", -70), ("unity", -20.5), ("zero-lufs", 0), ("high-level", 120),
                                 ("quiet-body", levels["loudness-absolute-above"]),
                                 ("relative-body", levels["loudness-relative-gate"]),
                                 ("low-body", levels["loudness-low-25"]),
                                 ("impulse-body", levels["loudness-impulse"])]]
    original = previous["musical_source"]["full_body_reference"]["lufs"]
    cases.extend([dict(id="gain-original-body", measured_lufs=original, frames=32000,
                       input_fixture="loudness-v9/song-body.f32", exact_pcm=False),
                  dict(id="gain-original-boundaries", measured_lufs=original, frames=len(BOUNDARIES),
                       input_file="original-boundaries.f32", source_frames=BOUNDARIES, exact_pcm=True)])
    for case in cases:
        case.update(file=case["id"] + ".f32", scalar_file=case["id"] + ".json",
                    expected_file=case["id"] + "-expected.f32", channels=2, bytes=case["frames"] * 8)
    return cases


def capture(song, events, samples=None, measured=None):
    """Execute original gain statement; injected meter returns a strong NumPy Float64."""
    import numpy as np
    session = importlib.import_module("session_render")
    source = Path(session.__file__).read_text()
    lines = source.splitlines()
    before = next(i for i, line in enumerate(lines, 1) if line.startswith("    measured=METER."))
    after = next(i for i, line in enumerate(lines, 1) if line.startswith("    peak=np.max(abs(mix)"))
    expression = next(node.value for node in ast.walk(ast.parse(source))
                      if isinstance(node, ast.AugAssign) and node.lineno == after - 1)
    power = compile(ast.Expression(expression), session.__file__, "eval")
    copied = copy.deepcopy(song)
    if samples is not None:
        copied["duration_seconds"] = len(samples) / 32000 - 5
    captured = {}
    class Captured(Exception):
        pass
    class SuppliedMeter:
        def integrated_loudness(self, _body):
            return np.float64(measured)
    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event == "line" and frame.f_lineno == before:
            if samples is not None:
                frame.f_locals["mix"][:] = samples
            captured["input"] = frame.f_locals["mix"].copy()
        if event == "line" and frame.f_lineno == after:
            gain = frame.f_locals["gain"]
            factor = eval(power, frame.f_globals, frame.f_locals)
            if type(gain) is not np.float64 or type(factor) is not np.float64:
                raise ValueError("Changed original strong Float64 gain arithmetic")
            captured.update(output=frame.f_locals["mix"].copy(),
                            scalars=dict(measured_lufs=float(frame.f_locals["measured"]),
                                         gain_db=float(gain), linear_gain=float(factor)))
            raise Captured
        return trace
    previous = session.make_events, session.METER, sys.gettrace()
    session.make_events = lambda _: copy.deepcopy(events) if samples is None else []
    if measured is not None:
        session.METER = SuppliedMeter()
    try:
        sys.settrace(trace)
        try:
            session.render_song(copied)
        except Captured:
            pass
    finally:
        session.make_events, session.METER = previous[:2]
        sys.settrace(previous[2])
    if "output" not in captured:
        raise ValueError("Original fixed-gain capture failed")
    return captured


def inputs(case):
    import numpy as np
    if "input_samples" in case:
        return np.asarray(case["input_samples"], np.float32)
    path = ROOT / "tests/fixtures" / case["input_fixture"] if "input_fixture" in case else FIXTURES / case["input_file"]
    return np.fromfile(path, dtype="<f4").reshape(case["frames"], 2)


def compare_scalars(actual, expected):
    if set(actual) != {"measured_lufs", "gain_db", "linear_gain"} or any(type(value) not in (int, float) or not math.isfinite(value) for value in actual.values()):
        raise ValueError("Incorrect or nonfinite gain scalar schema")
    if actual["measured_lufs"] != expected["measured_lufs"] or actual["linear_gain"] <= 0:
        raise ValueError("Changed gain input or invalid factor")
    db = abs(actual["gain_db"] - expected["gain_db"])
    relative = abs(actual["linear_gain"] / expected["linear_gain"] - 1)
    if db > SCALAR_LIMITS["gain_db_absolute_error"] or relative > SCALAR_LIMITS["linear_gain_relative_error"]:
        raise ValueError("Gain scalar tolerance exceeded")
    return dict(gain_db_absolute_error=db, linear_gain_relative_error=relative)


def compare_pcm(actual, expected, case):
    import numpy as np
    if actual.shape != expected.shape or not np.isfinite(actual).all():
        raise ValueError("Incorrect gain PCM shape or nonfinite values")
    if case["exact_pcm"] and not np.array_equal(actual.view(np.uint32), expected.view(np.uint32)):
        raise ValueError("Exact original gain rounding probe differs")
    return HELPERS["compare"](actual, expected, LIMITS, case["id"])


def load_manifest():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    _, provenance = LOUDNESS["load_manifest"]()
    if any(manifest.get(key) != value for key, value in dict(schema_version=1, sample_rate=32000, channels=2,
            target_lufs=-20.5, minimum_measured_lufs=-70, maximum_input_magnitude=1e6,
            pcm_limits=LIMITS, scalar_limits=SCALAR_LIMITS).items()) or len(manifest.get("cases", [])) != 10:
        raise ValueError("Changed fixed-gain format or tolerance")
    original = manifest["original_source"]
    previous, _ = LOUDNESS["load_manifest"]()
    for key in ("events_count", "events_sha256", "body_start_frame", "body_end_frame"):
        if original[key] != previous["musical_source"][key]:
            raise ValueError("Changed original gain input provenance")
    if original["frames"] != previous["musical_source"]["full_input_frames"]:
        raise ValueError("Changed original finite allocation")
    names = {"README.md", "manifest.json"}
    for case, definition in zip(manifest["cases"], definitions()):
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed gain case definition")
        compare_scalars(case["expected_scalars"], case["expected_scalars"])
        for kind in ("input", "expected"):
            if kind + "_file" in case:
                path = FIXTURES / case[kind + "_file"]
                names.add(path.name)
                if path.stat().st_size != case["bytes"] or HELPERS["digest"](path) != case[kind + "_sha256"]:
                    raise ValueError("Changed gain fixture PCM")
        if "input_fixture" in case and HELPERS["digest"](ROOT / "tests/fixtures" / case["input_fixture"]) != case["input_sha256"]:
            raise ValueError("Changed reused musical body")
    if {path.name for path in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing gain fixture")
    return manifest, provenance


def verify(manifest, provenance, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case[key] for case in manifest["cases"] for key in ("file", "scalar_file")}:
            raise ValueError("Unexpected or missing native gain candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    _, song, _, _ = MIX["source_inputs"]()
    events = json.loads((ROOT / "tests/fixtures/v9/events.json").read_text())
    results = []
    with HELPERS["reference"](provenance):
        source = capture(song, events)
        if abs(source["scalars"]["measured_lufs"] - manifest["original_source"]["scalars"]["measured_lufs"]) > 1e-5:
            raise ValueError("Changed original whole-body loudness")
        original = manifest["original_source"]
        normalized, _ = LOUDNESS["measure"](source["output"][original["body_start_frame"]:original["body_end_frame"]])
        LOUDNESS["compare"](normalized, original["normalized_body"])
        for case in manifest["cases"]:
            supplied = inputs(case)
            if LOUDNESS["digest_samples"](supplied) != case["input_sha256"]:
                raise ValueError("Changed exact gain input")
            expected = capture(song, [], supplied, case["measured_lufs"])
            frozen = np.fromfile(FIXTURES / case["expected_file"], dtype="<f4").reshape(case["frames"], 2)
            compare_pcm(expected["output"], frozen, case)
            compare_scalars(expected["scalars"], case["expected_scalars"])
            result = dict(id=case["id"], frames=case["frames"], reference=expected["scalars"], input_sha256=case["input_sha256"])
            if "source_frames" in case:
                delta = float(np.max(abs(source["input"][case["source_frames"]].astype(np.float64) - supplied)))
                if delta > 2e-7:
                    raise ValueError("Changed original intro/body/outro source probes")
                result["regenerated_source_maximum_error"] = delta
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native gain PCM length")
                actual = np.fromfile(path, dtype="<f4").reshape(frozen.shape)
                scalars = json.loads((candidates / case["scalar_file"]).read_text())
                result.update(compare_pcm(actual, expected["output"], case), **compare_scalars(scalars, expected["scalars"]),
                              native_sha256=HELPERS["digest"](path), native_scalars_sha256=HELPERS["digest"](candidates / case["scalar_file"]))
                if evidence is not None and case["id"] == "gain-original-body":
                    result["audition"] = []
                    for label, audio in (("reference", expected["output"]), ("native", actual)):
                        path = evidence / f"{case['id']}-{label}.wav"
                        sf.write(path, audio, 32000, subtype="FLOAT")
                        result["audition"].append(dict(file=path.name, sha256=HELPERS["digest"](path),
                            label="One-second original body diagnostic, whole-song fixed gain, before peak protection",
                            **MIX["ROOM"]["VOICES"]["measures"](audio)))
            results.append(result)
    report = dict(pcm_limits=LIMITS, scalar_limits=SCALAR_LIMITS, results=results)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps(results, indent=2, allow_nan=False))
    print(f"Verified {len(results)} original fixed-gain cases" + (" and native candidates" if candidates else ""))


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
        manifest, provenance = load_manifest()
        if args.integrity:
            print("Frozen fixed-gain integrity passed: 10 cases")
        else:
            verify(manifest, provenance, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
