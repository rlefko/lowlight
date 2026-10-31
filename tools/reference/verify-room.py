#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare the stereo room with unchanged accepted v9 functions and song order."""
import argparse
import copy
import importlib
import json
import math
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
GLUE = runpy.run_path(str(HERE / "verify-glue.py"))
HELPERS, VOICES, ROOT = GLUE["HELPERS"], GLUE["VOICES"], GLUE["ROOT"]
FIXTURES = ROOT / "tests/fixtures/room-v9"
CHANNELS = GLUE["CHANNELS"]
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
SYNTHETIC_LIMITS = {"maximum_absolute_error": 2e-6, "rms_error": 2e-7}
TAIL_LIMITS = {"maximum_absolute_error": 1e-8, "rms_error": 1e-9}
IMPULSES = [(0, [.5, 0, .03125, -.0625, .015625, -.0078125, .9375]),
            (4096, [0, -.25, -.125, .0625, .0078125, 0, .875]),
            (8192, [.125, -.125, 0, 0, .015625, -.015625, 1]),
            (12288, [.0625, .0625, .0625, .0625, 0, 0, .96875]),
            (255999, [0, 0, .125, -.125, .00390625, .001953125, 1])]


def source_inputs():
    provenance, song, events, _ = GLUE["source_inputs"]()
    if song["parameters"]["space"] != .44 or song["parameters"]["warmth"] != .78:
        raise ValueError("Changed accepted room controls")
    cases = [dict(id=f"room-tiny-{count}", frames=count, space=.44, warmth=.78,
                  expected_file=f"room-tiny-{count}-expected.f32") for count in (1, 618, 719)]
    cases += [dict(id=f"room-space{space}-warmth{warmth}", frames=256000, space=space,
                   warmth=warmth, tail_start_frame=64000) for space in (0, 1) for warmth in (0, 1)]
    for case in cases:
        case.update(input_frames=case["frames"], input_events=[dict(frame=frame, values=values)
                    for frame, values in IMPULSES if frame < case["frames"]])
    cases += [dict(id="room-score-" + focus, frames=416000, input_frames=3711911,
                   focus=focus, space=.44, warmth=.78, events_file="events.json",
                   energy=song["energy"], prepared_bytes=17546740) for focus in ("guitar", "piano")]
    return provenance, song, events, cases


def synthetic(case):
    """Sparse exact dyadic records, independent of the room implementation."""
    import numpy as np
    samples = np.zeros((case["frames"], 7), dtype=np.float32)
    samples[:, 6] = 1
    for event in case["input_events"]:
        samples[event["frame"]] = event["values"]
    return samples


def probes(case):
    count = case["frames"]
    edges = {0, 1, 383, 384, 385, 618, 718, count - 1, count - 2}
    for channel in (0, 1):
        combs = [round((ms + channel * 1.39) * 32) for ms in (29.7, 34.7, 37.1, 41.1, 43.7, 47.9, 53.3, 59.3)]
        allpasses = [round((ms + channel * .19) * 32) for ms in (5, 1.7, .73)]
        edges.update(384 + delay for delay in combs)
        edges.update(384 + combs[0] + delay for delay in [*allpasses, sum(allpasses)])
        edges.update(round((ms + channel * 3.13) * 32) for ms in (19.3, 37.1, 61.9))
    edges.update(frame for frame, _ in IMPULSES)
    edges.update((32000, 64000, 96000, 128000, 192000, 224000, 255999, 375010, 400000))
    positions = {frame + offset for frame in edges for offset in (-1, 0, 1)}
    positions.update(range(0, count, max(1, count // 64)))
    return sorted(frame for frame in positions if 0 <= frame < count)


def fingerprints(samples, case):
    import numpy as np
    return {"full_float32_sha256": GLUE["digest_samples"](samples),
            "channel_peak": np.max(np.abs(samples), axis=0).astype(float).tolist(),
            "channel_rms": np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
            "probes": [{"frame": frame, "values": samples[frame].astype(float).tolist()} for frame in probes(case)]}


def load_manifest():
    provenance, song, events, definitions = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, latency_frames=0, channel_order=CHANNELS,
                    tolerances=LIMITS, synthetic_tolerances=SYNTHETIC_LIMITS, tail_tolerances=TAIL_LIMITS)
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != 9:
        raise ValueError("Changed room format or tolerances")
    names = {"README.md", "manifest.json"}
    for case, definition in zip(manifest["cases"], definitions):
        definition = dict(definition, file=definition["id"] + ".f32", channels=7, bytes=definition["frames"] * 28)
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed room case definition")
        for kind in ("expected", "events"):
            if kind + "_file" in definition:
                filename = case[kind + "_file"]
                names.add(filename)
                if HELPERS["digest"](FIXTURES / filename) != case[kind + "_sha256"]:
                    raise ValueError("Changed frozen room " + kind)
                if kind == "expected" and (FIXTURES / filename).stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect frozen room output dimensions")
                if kind == "events" and json.loads((FIXTURES / filename).read_text()) != events:
                    raise ValueError("Changed accepted room events")
        if [probe.get("frame") for probe in case["probes"]] != probes(case):
            raise ValueError("Changed room fingerprint positions")
        if len(case["channel_peak"]) != 7 or len(case["channel_rms"]) != 7 or any(len(p["values"]) != 7 for p in case["probes"]):
            raise ValueError("Incorrect room fingerprint dimensions")
        values = case["channel_peak"] + case["channel_rms"] + [v for p in case["probes"] for v in p["values"]]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite room fingerprint")
        for key in ("full_float32_sha256", "input_float32_sha256"):
            if len(case[key]) != 64 or any(c not in "0123456789abcdef" for c in case[key]):
                raise ValueError("Invalid frozen room PCM hash")
    if {path.name for path in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing room fixture file")
    return manifest, provenance, song, events


def render_score(song, events, case):
    """Observe original pre-room and post-room locals, with full original N."""
    import numpy as np
    session = importlib.import_module("session_render")
    source = Path(session.__file__).read_text().splitlines()
    wet_line = next(i for i, line in enumerate(source, 1) if line.startswith("    wet=tone.room(tonal,"))
    bus_line = next(i for i, line in enumerate(source, 1) if line.startswith("    mix=(tonal+bass)*duck"))
    captured = {}

    class Captured(Exception):
        pass

    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event == "line" and frame.f_lineno in (wet_line, bus_line):
            if frame.f_locals["n"] != case["input_frames"]:
                raise ValueError("Original room allocation changed")
            length = case["frames"]
            if frame.f_lineno == wet_line:
                captured["input"] = frame.f_locals["tonal"][:length].copy()
            else:
                fields = [frame.f_locals[name][:length] for name in ("bass", "drums", "duck")]
                captured["expected"] = np.column_stack([frame.f_locals["tonal"][:length], *fields])
                captured["input"] = np.column_stack([captured["input"], *fields])
                raise Captured
        return trace

    previous_events, previous_trace = session.make_events, sys.gettrace()
    session.make_events = lambda _: copy.deepcopy(events)
    try:
        sys.settrace(trace)
        try:
            session.render_song(dict(song, focus=case["focus"]))
        except Captured:
            pass
    finally:
        sys.settrace(previous_trace)
        session.make_events = previous_events
    if "expected" not in captured:
        raise ValueError("Original room capture failed")
    return captured["expected"], captured["input"]


def render(renderer, song, events, case):
    if "events_file" in case:
        return render_score(song, events, case)
    inputs = synthetic(case)
    wet = renderer.room(inputs[:, :2], 1.65 + .85 * case["space"], case["warmth"]) * (.60 + .8 * case["space"])
    expected = inputs.copy()
    expected[:, :2] = inputs[:, :2] * .92 + wet
    return expected, inputs


def verify(manifest, provenance, song, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native room candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    results = []
    with HELPERS["reference"](provenance) as renderer:
        for case in manifest["cases"]:
            expected, inputs = render(renderer, song, events, case)
            limits = LIMITS if "events_file" in case else SYNTHETIC_LIMITS
            if expected.shape != (case["frames"], 7) or not np.isfinite(expected).all():
                raise ValueError("Incorrect room oracle dimensions or values")
            if "input_events" in case and GLUE["digest_samples"](inputs) != case["input_float32_sha256"]:
                raise ValueError("Synthetic room inputs differ from their independent definition")
            if "expected_file" in case:
                frozen = np.fromfile(FIXTURES / case["expected_file"], dtype="<f4").reshape(expected.shape)
                if not np.isfinite(frozen).all():
                    raise ValueError("Nonfinite frozen room waveform")
                HELPERS["compare"](expected, frozen, limits, "frozen room waveform")
            frozen = np.asarray([p["values"] for p in case["probes"]], dtype=np.float32)
            HELPERS["compare"](expected[probes(case)], frozen, limits, "frozen room fingerprints")
            measured = fingerprints(expected, case)
            for key, tolerance in (("channel_peak", limits["maximum_absolute_error"]), ("channel_rms", limits["rms_error"])):
                if max(abs(a - b) for a, b in zip(case[key], measured[key])) > tolerance:
                    raise ValueError("Changed frozen room channel metrics")
            item = dict(id=case["id"], frames=case["frames"], channels=7,
                        frozen_float32_sha256=case["full_float32_sha256"], regenerated_float32_sha256=GLUE["digest_samples"](expected))
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native room candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                item.update(HELPERS["compare"](actual, expected, limits, case["id"]), sha256=HELPERS["digest"](path))
                item["tonal"] = HELPERS["compare"](actual[:, :2], expected[:, :2], limits, case["id"] + " tonal")
                if not np.array_equal(actual[:, 6], inputs[:, 6]):
                    raise ValueError("Room did not preserve duck values exactly")
                if "input_events" in case and not np.array_equal(actual[:, 2:], inputs[:, 2:]):
                    raise ValueError("Synthetic room pass-through fields changed")
                if "tail_start_frame" in case:
                    start = case["tail_start_frame"]
                    item["tail"] = HELPERS["compare"](actual[start:, :2], expected[start:, :2], TAIL_LIMITS, case["id"] + " tail")
                if evidence is not None and "events_file" in case:
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        path = evidence / (case["id"] + "-unmastered-post-room-" + label + ".wav")
                        sf.write(path, samples[:, :2], 32000, subtype="FLOAT")
                        item["audition"].append({"file": path.name, "sha256": HELPERS["digest"](path), **VOICES["measures"](samples[:, :2])})
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified nine frozen stereo-room cases" + (" against every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--compare", type=Path, help="Exactly nine aligned seven-channel Float32 room candidates")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, song, events = load_manifest()
        if args.integrity:
            print("Frozen room integrity passed: three tiny cases, four control corners, and both accepted focus settings")
        else:
            verify(manifest, provenance, song, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
