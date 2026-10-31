#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare native bass preparation/voices with the unchanged accepted v9 functions."""
import argparse
import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
VOICES = runpy.run_path(str(HERE / "verify-voices.py"))
HELPERS = VOICES["HELPERS"]
ROOT = HELPERS["ROOT"]
FIXTURES = ROOT / "tests/fixtures/bass-v9"
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
FRAMES, TAIL = 416000, 385743
KEYS = [(note, rr) for note in range(31, 58) for rr in range(2)]


def source_inputs():
    provenance = json.loads((HERE / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if HELPERS["digest"](ROOT / name) != expected:
            raise ValueError(f"Changed frozen v9 input: {name}")
    events = json.loads((ROOT / "tests/fixtures/v9/events.json").read_text())
    events = [event for event in events if event["instrument"] == "bass" and event["time"] < 12]
    if len(events) != 6:
        raise ValueError("Unexpected accepted bass prefix")
    return provenance, events


def load_manifest():
    provenance, accepted = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    controls = (manifest.get("schema_version"), manifest.get("sample_rate"), manifest.get("frames"),
                manifest.get("channels"), manifest.get("event_count"), manifest.get("tail_silence_start_frame"))
    if controls != (1, 32000, FRAMES, 2, 6, TAIL) or manifest.get("tolerances") != LIMITS:
        raise ValueError("Changed bass fixture dimensions/controls/tolerances")
    for kind, name in (("events", "events.json"), ("fixture", "bass-prefix.flac")):
        if manifest[kind + "_file"] != name or HELPERS["digest"](FIXTURES / name) != manifest[kind + "_sha256"]:
            raise ValueError(f"Changed frozen bass {kind}")
    if json.loads((FIXTURES / "events.json").read_text()) != accepted:
        raise ValueError("Bass events differ from the accepted score prefix")
    cases = manifest.get("cases", [])
    if [(case.get("note"), case.get("round_robin")) for case in cases] != KEYS:
        raise ValueError("Unexpected bass preparation case inventory")
    for case in cases:
        if (case.get("file") != f"body-{case['note']}-{case['round_robin']}.f32" or
                case.get("channels") != 1 or not 1 <= case.get("frames", 0) <= 89797):
            raise ValueError("Invalid bass preparation case")
    if {path.name for path in FIXTURES.iterdir() if path.is_file()} != {"README.md", "manifest.json", "events.json", "bass-prefix.flac"}:
        raise ValueError("Unexpected or missing bass fixture file")
    return manifest, provenance, accepted


def prepared(renderer, note, rr):
    natural = renderer.ins.pitched("bass", note, 1, rr).mean(1)
    return renderer.ins.filt(renderer.ins.filt(natural, 180, "highpass"), 650) * .08


def render(renderer, events, absolute_endpoints=False):
    import numpy as np
    output = np.zeros((FRAMES, 2), dtype=np.float32)
    for original in events:
        event = dict(original)
        if absolute_endpoints:
            start = round(event["time"] * 32000)
            gate = round((event["time"] + event["duration"]) * 32000)
            end = round((event["time"] + event["duration"] + event["release"]) * 32000)
            event["duration"], event["release"] = (gate - start) / 32000, (end - gate) / 32000
        renderer.place(output, renderer.bass_voice(event), event["time"])
    return output


def candidate(directory, name, expected):
    import numpy as np
    path = directory / name
    if path.stat().st_size != expected.size * 4:
        raise ValueError(f"Incorrect native bass candidate length: {name}")
    actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
    result = HELPERS["compare"](actual, expected, LIMITS, name)
    result.update(file=name, sha256=HELPERS["digest"](path))
    return actual, result


def verify(manifest, provenance, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        names = {"bass-prefix.f32"} | {case["file"] for case in manifest["cases"]}
        if {path.name for path in candidates.iterdir()} != names:
            raise ValueError("Unexpected or missing native bass candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
    result = {"frames": FRAMES, "channels": 2, "events": 6, "prepared_bodies": []}
    with HELPERS["reference"](provenance) as renderer:
        expected = render(renderer, events)
        for case in manifest["cases"]:
            body = prepared(renderer, case["note"], case["round_robin"])
            if body.shape != (case["frames"],) or not np.isfinite(body).all():
                raise ValueError(f"Changed prepared bass body: {case['file']}")
            peak, rms = float(np.max(np.abs(body))), float(np.sqrt(np.mean(body.astype(np.float64) ** 2)))
            if abs(peak - case["peak"]) > 1e-5 or abs(rms - case["rms"]) > 1e-6:
                raise ValueError(f"Changed prepared bass metrics: {case['file']}")
            comparison = {"file": case["file"], "frames": len(body), "channels": 1}
            if candidates is not None:
                _, measured = candidate(candidates, case["file"], body)
                comparison.update(measured)
            result["prepared_bodies"].append(comparison)
    frozen, rate = sf.read(FIXTURES / "bass-prefix.flac", dtype="float32", always_2d=True)
    if rate != 32000:
        raise ValueError("Incorrect bass fixture sample rate")
    HELPERS["compare"](expected, frozen, LIMITS, "frozen bass reproduction")
    if np.any(expected[TAIL:]) or not np.array_equal(expected[:, 0], expected[:, 1]):
        raise ValueError("Changed reference bass tail or centered output")
    result["reference"] = VOICES["measures"](expected)
    if candidates is not None:
        actual, measured = candidate(candidates, "bass-prefix.f32", expected)
        result.update(measured)
        if np.any(actual[TAIL:]) or not np.array_equal(actual[:, 0], actual[:, 1]):
            raise ValueError("Native bass did not retain exact silence/centered output")
        result["native"] = VOICES["measures"](actual)
        if evidence is not None:
            evidence.mkdir(parents=True, exist_ok=True)
            result["audition"] = []
            for label, samples in (("reference", expected), ("native", actual)):
                path = evidence / ("bass-prefix-" + label + ".wav")
                sf.write(path, samples, 32000, subtype="FLOAT")
                result["audition"].append({"file": path.name, "sha256": HELPERS["digest"](path)})
            (evidence / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    print("Verified 54 prepared bass bodies and the frozen 13-second bass prefix" + (" against every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true", help="Check source/event/audio hashes without DSP dependencies")
    mode.add_argument("--compare", type=Path, help="Directory containing 54 native bodies and bass-prefix.f32")
    parser.add_argument("--evidence", type=Path, help="Write labeled full-length dry A/B clips and measurements")
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, events = load_manifest()
        if args.integrity:
            print("Frozen bass integrity passed: six accepted events and 54 preparation cases")
        else:
            verify(manifest, provenance, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
