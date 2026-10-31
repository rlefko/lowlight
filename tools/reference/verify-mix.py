#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare final song mixing with unchanged v9 before its fixed loudness gain."""
import argparse
import copy
import importlib
import json
import math
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
ROOM = runpy.run_path(str(HERE / "verify-room.py"))
AIR = runpy.run_path(str(HERE / "verify-air.py"))
HELPERS, VOICES, ROOT = ROOM["HELPERS"], ROOM["VOICES"], ROOM["ROOT"]
FIXTURES = ROOT / "tests/fixtures/mix-v9"
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
SYNTHETIC_LIMITS = {"maximum_absolute_error": 2e-7, "rms_error": 2e-8}
AIR_LIMITS = {"maximum_absolute_error": 2e-9, "rms_error": 2e-10}
TAIL_LIMITS = {"maximum_absolute_error": 1e-9, "rms_error": 1e-10}


def source_inputs():
    provenance, song, events, _ = ROOM["source_inputs"]()
    _, _, air_cases = AIR["source_inputs"]()
    segment = lambda start, count, values: dict(start=start, count=count, values=values)
    cases = [
        dict(id="mix-tiny-1", frames=1, input_segments=[segment(0, 1, [.5, -.25, .125, -.0625, .03125, .015625, .5])]),
        dict(id="mix-tiny-2", frames=2, texture=1, input_segments=[
            segment(0, 1, [.03125, -.015625, .0078125, 0, 0, .00390625, .9375]),
            segment(1, 1, [0, .03125, -.0078125, 0, .001953125, 0, .75])]),
        dict(id="mix-staging", frames=257, exact_silence=True, input_segments=[
            segment(0, 128, [16777216, -16777216, 1, -1, -8388608, 8388608, .5]),
            segment(128, 129, [512.0000610351562, -512.0000610351562, 0, 0, -512, 512, .9999999403953552])]),
        dict(id="mix-duck", frames=4097, input_segments=[
            segment(frame, 1, [.5, .25, .125, -.125, .03125, -.015625, duck])
            for frame, duck in ((0, 0), (256, .5), (257, 1), (1024, .25), (4096, 0))]),
        dict(id="mix-dc", frames=32000, tail_start_frame=16000, tail_end_frame=32000,
             input_segments=[segment(0, 16000, [.25, -.125, .0625, .03125, .015625, -.0078125, .75])]),
        dict(id="mix-impulse", frames=32000, tail_start_frame=512, tail_end_frame=31999, input_segments=[
            segment(0, 1, [.5, 0, 0, 0, 0, 0, 1]), segment(257, 1, [0, -.25, 0, 0, 0, 0, 1]),
            segment(31999, 1, [0, 0, 0, 0, .03125, -.015625, 1])]),
        dict(id="mix-air-tail", frames=8193, texture=1, frame_origin=4096, limits=AIR_LIMITS,
             tail_start_frame=4097, tail_end_frame=8193, input_segments=[]),
        dict(id="mix-air-carrier", frames=16385, texture=1, frame_origin=1099511627776,
             tail_start_frame=12289, tail_end_frame=16385,
             input_segments=[segment(0, 8192, [.03125, -.015625, .00390625, .0078125, -.0078125, .001953125, .9375])]),
    ]
    for index, case in enumerate(cases):
        case.setdefault("texture", 0)
        case.setdefault("frame_origin", 0)
        case.setdefault("limits", SYNTHETIC_LIMITS)
        count, origin = case["frames"], case["frame_origin"]
        incoming, start, end = (0, 0, count)
        if case["id"] == "mix-air-tail":
            incoming, start, end = 2048.375, 3072.25, 4096.75
        elif case["id"] == "mix-air-carrier":
            incoming, start, end = 2048.375, 8192.25, 12288.75
        case.update(input_frames=count, seed=(0, 2147483647, 1278560406)[index % 3],
                    fades=dict(zip(AIR["FADE_KEYS"], (origin if incoming else 0, origin + incoming if incoming else 0,
                         origin + start, origin + end, origin, origin + end))))
        if index < 3:
            case["expected_file"] = case["id"] + "-expected.f32"
        if "tail_start_frame" in case:
            case["tail_limits"] = TAIL_LIMITS
    original = next(case for case in air_cases if case["id"] == "air-song-0")
    for focus in ("guitar", "piano"):
        cases.append(dict(id="mix-score-" + focus, frames=416000, input_frames=3711911,
                          seed=original["seed"], texture=original["texture"], frame_origin=0, fades=original["fades"],
                          focus=focus, events_file="events.json", warmth=.78, space=.44,
                          energy=song["energy"], prepared_bytes=17546740, limits=LIMITS))
    for case in cases:
        case.update(file=case["id"] + ".f32", channels=2, bytes=case["frames"] * 8)
    return provenance, song, events, cases


def synthetic(case):
    import numpy as np
    samples = np.zeros((case["input_frames"], 7), np.float32)
    samples[:, 6] = 1
    for segment in case["input_segments"]:
        samples[segment["start"]:segment["start"] + segment["count"]] = segment["values"]
    return samples


def probes(case):
    count = case["frames"]
    if "expected_file" in case:
        return list(range(count))
    edges = {0, 1, 2, 255, 256, 257, 399, 400, count - 2, count - 1}
    for segment in case.get("input_segments", []):
        edges.update((segment["start"], segment["start"] + segment["count"]))
    for key in ("tail_start_frame", "tail_end_frame"):
        if key in case:
            edges.add(case[key])
    for key, value in case["fades"].items():
        if key.startswith("tonal_"):
            edges.add(math.floor(value - case["frame_origin"]))
    positions = set(range(0, count, max(1, count // 96)))
    positions.update(edge + delta for edge in edges for delta in (-1, 0, 1, 2))
    return sorted(frame for frame in positions if 0 <= frame < count)


def fingerprints(samples, case):
    import numpy as np
    return dict(full_float32_sha256=ROOM["GLUE"]["digest_samples"](samples),
                channel_peak=np.max(abs(samples), axis=0).astype(float).tolist(),
                channel_rms=np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
                probes=[dict(frame=frame, values=samples[frame].astype(float).tolist()) for frame in probes(case)])


def render(song, events, case):
    """Observe original mix/air/HP32; substitute only synthetic bus inputs and clocks."""
    import numpy as np
    session = importlib.import_module("session_render")
    lines = Path(session.__file__).read_text().splitlines()
    line = lambda prefix: next(i for i, value in enumerate(lines, 1) if value.startswith(prefix))
    before_fade, before_mix = line("    t=np.arange(n)/FS;out_start="), line("    mix=(tonal+bass)*duck")
    before_air, before_hp, done = line("    rng=np.random.default_rng"), line("    mix=ins.filt(mix,32"), line("    lo=round(local_seconds")
    original = "events_file" in case
    inputs = None if original else synthetic(case)
    copied = copy.deepcopy(song)
    copied["take_seed"], copied["parameters"]["texture"] = case["seed"], case["texture"]
    if original:
        copied["focus"] = case["focus"]
    else:
        copied["duration_seconds"] = case["input_frames"] / 32000 - 5
        copied["in_bridge"] = {} if case["fades"]["tonal_in_end_frame"] else None
    captured = {}
    class Captured(Exception):
        pass
    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event != "line":
            return trace
        if frame.f_lineno == before_fade and not original:
            frame.f_locals["duration"] = (case["fades"]["tonal_out_end_frame"] - case["frame_origin"]) / 32000
        if frame.f_lineno == before_mix:
            if frame.f_locals["n"] != case["input_frames"]:
                raise ValueError("Changed original mix allocation")
            if inputs is not None:
                for name, values in (("tonal", inputs[:, :2]), ("bass", inputs[:, 2:4]),
                                     ("drums", inputs[:, 4:6]), ("duck", inputs[:, 6])):
                    frame.f_locals[name][:] = values
            captured["inputs"] = np.column_stack([frame.f_locals[name][:case["frames"]] for name in ("tonal", "bass", "drums", "duck")])
        if frame.f_lineno in (before_air, before_hp):
            name = "pre_air" if frame.f_lineno == before_air else "pre_highpass"
            captured[name + "_float32_sha256"] = ROOM["GLUE"]["digest_samples"](frame.f_locals["mix"][:case["frames"]])
            if case.get("exact_silence") and np.any(frame.f_locals["mix"]):
                raise ValueError("Original staged cancellation is not exact silence")
        if frame.f_lineno == done:
            captured["output"] = frame.f_locals["mix"][:case["frames"]].copy()
            raise Captured
        return trace
    previous_events, previous_clock, previous_trace = session.make_events, session.local_seconds, sys.gettrace()
    session.make_events = lambda _: copy.deepcopy(events) if original else []
    if not original:
        clocks = {16: (case["fades"]["tonal_in_end_frame"] - case["frame_origin"]) / 32000,
                  song["bars"] * 4 - 16: (case["fades"]["tonal_out_start_frame"] - case["frame_origin"]) / 32000,
                  song["bars"] * 4 - 8: (case["fades"]["rhythm_out_frame"] - case["frame_origin"]) / 32000}
        session.local_seconds = lambda value, beat: clocks[beat]
    try:
        sys.settrace(trace)
        try:
            session.render_song(copied)
        except Captured:
            pass
    finally:
        sys.settrace(previous_trace)
        session.make_events, session.local_seconds = previous_events, previous_clock
    if "output" not in captured:
        raise ValueError("Original pre-normalization mix capture failed")
    return captured


def load_manifest():
    provenance, song, events, definitions = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, latency_frames=0, channels=2,
                    input_channel_order=ROOM["CHANNELS"], tolerances=LIMITS, synthetic_tolerances=SYNTHETIC_LIMITS,
                    air_tolerances=AIR_LIMITS, tail_tolerances=TAIL_LIMITS)
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != 10:
        raise ValueError("Changed mix format or tolerances")
    names = {"README.md", "manifest.json"}
    for case, definition in zip(manifest["cases"], definitions):
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed mix case definition")
        for kind in ("expected", "events"):
            if kind + "_file" in definition:
                path = FIXTURES / case[kind + "_file"]
                names.add(path.name)
                if HELPERS["digest"](path) != case[kind + "_sha256"]:
                    raise ValueError("Changed frozen mix " + kind)
                if kind == "expected" and path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect frozen mix output length")
                if kind == "events" and json.loads(path.read_text()) != events:
                    raise ValueError("Changed accepted mix events")
        if [p.get("frame") for p in case["probes"]] != probes(case):
            raise ValueError("Changed mix fingerprint positions")
        if len(case["channel_peak"]) != 2 or len(case["channel_rms"]) != 2 or any(len(p["values"]) != 2 for p in case["probes"]):
            raise ValueError("Incorrect mix fingerprint dimensions")
        values = case["channel_peak"] + case["channel_rms"] + [v for p in case["probes"] for v in p["values"]]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite mix fingerprint")
        for key in ("full_float32_sha256", "input_float32_sha256", "pre_air_float32_sha256", "pre_highpass_float32_sha256"):
            if len(case[key]) != 64 or any(c not in "0123456789abcdef" for c in case[key]):
                raise ValueError("Invalid frozen mix hash")
    if {path.name for path in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing mix fixture file")
    return manifest, provenance, song, events


def check_structure(samples, case):
    import numpy as np
    if samples.shape != (case["frames"], 2) or not np.isfinite(samples).all():
        raise ValueError("Incorrect mix dimensions or nonfinite samples")
    if case.get("exact_silence") and np.any(samples):
        raise ValueError("Float mix cancellation is not exact silence")


def verify(manifest, provenance, song, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native mix candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    results = []
    with HELPERS["reference"](provenance):
        for case in manifest["cases"]:
            captured = render(song, events, case)
            expected, inputs = captured["output"], captured["inputs"]
            check_structure(expected, case)
            if "input_segments" in case and ROOM["GLUE"]["digest_samples"](inputs) != case["input_float32_sha256"]:
                raise ValueError("Changed independently defined synthetic mix inputs")
            if "expected_file" in case:
                frozen = np.fromfile(FIXTURES / case["expected_file"], dtype="<f4").reshape(expected.shape)
                check_structure(frozen, case)
                HELPERS["compare"](expected, frozen, case["limits"], "frozen mix waveform")
            frozen = np.asarray([p["values"] for p in case["probes"]], np.float32)
            HELPERS["compare"](expected[probes(case)], frozen, case["limits"], "frozen mix probes")
            measured = fingerprints(expected, case)
            for key, tolerance in (("channel_peak", case["limits"]["maximum_absolute_error"]), ("channel_rms", case["limits"]["rms_error"])):
                if max(abs(a - b) for a, b in zip(case[key], measured[key])) > tolerance:
                    raise ValueError("Changed frozen mix channel metrics")
            item = dict(id=case["id"], frames=case["frames"], input_frames=case["input_frames"], channels=2,
                        frozen_float32_sha256=case["full_float32_sha256"], regenerated_float32_sha256=measured["full_float32_sha256"],
                        input_float32_sha256=ROOM["GLUE"]["digest_samples"](inputs),
                        **{key: captured[key] for key in ("pre_air_float32_sha256", "pre_highpass_float32_sha256")})
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native mix candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                check_structure(actual, case)
                item.update(HELPERS["compare"](actual, expected, case["limits"], case["id"]), sha256=HELPERS["digest"](path))
                if "tail_start_frame" in case:
                    start, end = case["tail_start_frame"], case["tail_end_frame"]
                    if not np.any(expected[start:end]):
                        raise ValueError("Original HP32 tail control is empty")
                    item["tail"] = HELPERS["compare"](actual[start:end], expected[start:end], case["tail_limits"], case["id"] + " tail")
                if evidence is not None and "events_file" in case:
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        path = evidence / (case["id"] + "-pre-loudness-gain-" + label + ".wav")
                        sf.write(path, samples, 32000, subtype="FLOAT")
                        item["audition"].append(dict(file=path.name, label="Post-room, air and HP32; before whole-song loudness gain and peak protection",
                            sha256=HELPERS["digest"](path), **VOICES["measures"](samples)))
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified ten original pre-normalization song mixes" + (" against every native candidate sample" if candidates else ""))


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
        manifest, provenance, song, events = load_manifest()
        if args.integrity:
            print("Frozen mix integrity passed: eight synthetic controls and both score focus settings")
        else:
            verify(manifest, provenance, song, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        sys.exit(str(error))
