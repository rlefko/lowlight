#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare bounded stereo body measurements with pinned, unchanged pyloudnorm."""
import argparse
import hashlib
import importlib
import json
import math
from pathlib import Path
import runpy
import sys
import warnings

HERE = Path(__file__).resolve().parent
MIX = runpy.run_path(str(HERE / "verify-mix.py"))
HELPERS, ROOT = MIX["HELPERS"], MIX["ROOT"]
FIXTURES = ROOT / "tests/fixtures/loudness-v9"
LUFS_ERROR = 1e-5
SOURCE_HASHES = {
    "meter.py": "97566b9bc402c43e1c5ce0ca788930c01d40326ed5dc48f0c6f79c489366d823",
    "iirfilter.py": "4e20bb7c0a1b75eedee0dfefad1f5a238488551a82677fac6f7311d3ccdf56e3",
    "util.py": "38554a8fda0ff773504735d6d5533378a0ab699bf6a7e4f748dd2e10cc32b947",
}
RESULT_KEYS = {"input_frames", "block_count", "absolute_gate_count", "relative_gate_count", "measurable", "lufs"}


def definitions():
    segment = lambda start, count, pattern, hold=1: dict(start=start, count=count, pattern=pattern, hold_frames=hold)
    wave = [[.125, -.0625], [-.125, .0625]]
    cases = [dict(id="loudness-silence", input_frames=12800, input_segments=[]),
             dict(id="loudness-impulse", input_frames=12800, input_segments=[
                 segment(0, 1, [[1, -.5]]), segment(12799, 1, [[-.25, .125]])]),
             dict(id="loudness-low-25", input_frames=48000, input_segments=[segment(0, 48000, wave, 640)]),
             dict(id="loudness-high-8000", input_frames=48000, input_segments=[segment(0, 48000, wave, 2)]),
             dict(id="loudness-asymmetric", input_frames=64000, input_segments=[
                 segment(0, 32000, [[.125, 0], [-.125, 0]], 64),
                 segment(32000, 32000, [[0, .03125], [0, -.03125]], 2)])]
    for count in (14400, 14401, 17600, 20800, 24000, 24001, 59200):
        cases.append(dict(id=f"loudness-length-{count}", input_frames=count,
                          input_segments=[segment(0, count, wave, 16)]))
    cases.append(dict(id="loudness-relative-gate", input_frames=160000, input_segments=[
        segment(0, 32000, [[.5, -.25], [-.5, .25]], 16),
        segment(32000, 32000, [[.0009765625, 0], [-.0009765625, 0]], 16),
        segment(64000, 32000, [[.03125, .015625], [-.03125, -.015625]], 16)]))
    for label, amplitude in (("below", .0002160775038646534), ("above", .00021612727141473442)):
        cases.append(dict(id="loudness-absolute-" + label, input_frames=12800,
                          input_segments=[segment(0, 12800, [[amplitude, 0], [-amplitude, 0]], 2)]))
    cases.append(dict(id="loudness-maximum", input_frames=5792000, input_segments=[
        segment(0, 5792000, wave, 16), segment(1600000, 320000, [[0, 0]]),
        segment(4000000, 640000, [[.0009765625, 0], [-.0009765625, 0]], 16)]))
    cases.append(dict(id="loudness-song-body", input_frames=32000, input_file="song-body.f32"))
    for case in cases:
        case["file"] = case["id"] + ".json"
    return cases


def synthetic(case):
    import numpy as np
    samples = np.zeros((case["input_frames"], 2), np.float32)
    for segment in case["input_segments"]:
        indices = (np.arange(segment["count"]) // segment["hold_frames"]) % len(segment["pattern"])
        samples[segment["start"]:segment["start"] + segment["count"]] = np.asarray(segment["pattern"], np.float32)[indices]
    return samples


def digest_samples(samples):
    import numpy as np
    return hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest()


def source_metadata():
    import numpy as np
    import pyloudnorm as pyln
    directory = Path(pyln.__file__).parent
    if any(HELPERS["digest"](directory / name) != value for name, value in SOURCE_HASHES.items()):
        raise ValueError("Changed pinned pyloudnorm source")
    meter = pyln.Meter(32000)
    endpoints = [(int(.4 * (j * .25) * 32000), int(.4 * (j * .25 + 1) * 32000)) for j in np.arange(1808)]
    if any(pair != (j * 3200, (j + 4) * 3200) for j, pair in enumerate(endpoints)):
        raise ValueError("Changed original floating block endpoints")
    half_counts = [int(np.round(((count / 32000 - .4) / (.4 * .25))) + 1)
                   for count in range(14400, 5792001, 3200)]
    return dict(pyloudnorm_version="0.1.1", source_sha256=SOURCE_HASHES,
                filters=[dict(name=name, b=stage.b.tolist(), a=stage.a.tolist()) for name, stage in meter._filters.items()],
                checked_endpoint_indices=[0, 1807], endpoint_mismatches=0,
                half_hop_first_frames=14400, half_hop_stride_frames=3200, half_hop_block_counts=half_counts)


def measure(samples):
    """Trace original locals; never replace its filters, reduction, rounding, or gates."""
    import numpy as np
    import pyloudnorm as pyln
    function = pyln.Meter.integrated_loudness
    lines = Path(function.__code__.co_filename).read_text().splitlines()
    relative = next(i for i, line in enumerate(lines, 1) if line.strip().startswith("Gamma_r ="))
    returned = next(i for i, line in enumerate(lines, 1) if line.strip() == "return LUFS")
    captured = {}
    def trace(frame, event, _argument):
        if frame.f_code is not function.__code__:
            return None
        if event == "line" and frame.f_lineno == relative:
            captured["absolute_indices"] = list(frame.f_locals["J_g"])
        if event == "line" and frame.f_lineno == returned:
            values = frame.f_locals
            captured.update(relative_indices=list(values["J_g"]), block_energies=values["z"].T.tolist(),
                            relative_threshold=float(values["Gamma_r"]) if math.isfinite(values["Gamma_r"]) else None,
                            filtered_probes=[dict(frame=i, values=values["input_data"][i].astype(float).tolist())
                                             for i in (0, 1, 2, 31, 127, 8191, len(samples) - 1)])
        return trace
    previous = sys.gettrace()
    try:
        sys.settrace(trace)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            lufs = float(pyln.Meter(32000).integrated_loudness(samples))
    finally:
        sys.settrace(previous)
    if "relative_indices" not in captured or math.isnan(lufs) or lufs == math.inf:
        raise ValueError("Original loudness capture failed")
    result = dict(input_frames=len(samples), block_count=len(captured["block_energies"]),
                  absolute_gate_count=len(captured["absolute_indices"]), relative_gate_count=len(captured["relative_indices"]),
                  measurable=math.isfinite(lufs), lufs=lufs if math.isfinite(lufs) else 0)
    return result, captured


def musical_input():
    """Regenerate all 621 accepted events/full N, then begin a fresh meter at the body slice."""
    provenance, song, _, cases = MIX["source_inputs"]()
    case = dict(next(case for case in cases if case["id"] == "mix-score-guitar"), frames=3711911)
    events_path = ROOT / "tests/fixtures/v9/events.json"
    events = json.loads(events_path.read_text())
    rendered = MIX["render"](song, events, case)["output"]
    session = importlib.import_module("session_render")
    lo = round(session.local_seconds(song, 16) * 32000)
    hi = round(session.local_seconds(song, song["bars"] * 4 - 16) * 32000)
    result, _ = measure(rendered[lo:hi])
    return rendered[lo:lo + 32000].copy(), dict(full_input_frames=len(rendered), events_count=len(events),
        events_sha256=HELPERS["digest"](events_path), body_start_frame=lo, body_end_frame=hi,
        excerpt_frames=32000, full_body_reference=result, full_pre_gain_float32_sha256=digest_samples(rendered))


def validate_result(result):
    if set(result) != RESULT_KEYS or type(result["measurable"]) is not bool:
        raise ValueError("Incorrect loudness result schema")
    if any(type(result[key]) is not int or result[key] < 0 for key in RESULT_KEYS - {"lufs", "measurable"}):
        raise ValueError("Invalid loudness count")
    if not 12800 <= result["input_frames"] <= 5792000 or not 0 <= result["relative_gate_count"] <= result["absolute_gate_count"] <= result["block_count"] <= 1807:
        raise ValueError("Out-of-range loudness counts")
    if type(result["lufs"]) not in (int, float) or not math.isfinite(result["lufs"]) or (not result["measurable"] and result["lufs"] != 0):
        raise ValueError("Invalid loudness scalar")
    if result["measurable"] != (result["relative_gate_count"] > 0):
        raise ValueError("Inconsistent loudness status")


def compare(actual, expected):
    validate_result(actual)
    if any(actual[key] != expected[key] for key in RESULT_KEYS - {"lufs"}):
        raise ValueError("Loudness status or block/gate count differs")
    error = abs(actual["lufs"] - expected["lufs"])
    if error > LUFS_ERROR:
        raise ValueError(f"Loudness error {error} exceeds {LUFS_ERROR} LU")
    return error


def load_manifest():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    provenance = json.loads((HERE / "provenance.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, channels=2, maximum_lufs_error=LUFS_ERROR,
                    minimum_frames=12800, maximum_frames=5792000, maximum_input_magnitude=1e6)
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != len(definitions()):
        raise ValueError("Changed loudness format or limits")
    if manifest["reference"]["source_sha256"] != SOURCE_HASHES:
        raise ValueError("Changed loudness source provenance")
    for name, expected in provenance["files"].items():
        if name.startswith("tools/reference/v9/") and HELPERS["digest"](ROOT / name) != expected:
            raise ValueError("Changed frozen v9 source")
    names = {"manifest.json", "README.md"}
    for case, definition in zip(manifest["cases"], definitions()):
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed loudness input recipe")
        validate_result(case["expected"])
        if case["expected"]["input_frames"] != case["input_frames"]:
            raise ValueError("Changed loudness input length")
        if "input_file" in case:
            path = FIXTURES / case["input_file"]
            names.add(path.name)
            if path.stat().st_size != case["input_frames"] * 8 or HELPERS["digest"](path) != case["input_float32_sha256"]:
                raise ValueError("Changed musical body excerpt")
    if {path.name for path in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing loudness fixture")
    return manifest, provenance


def verify(manifest, provenance, candidates=None, evidence=None):
    import numpy as np
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native loudness candidate")
    results = []
    with HELPERS["reference"](provenance):
        if source_metadata() != manifest["reference"]:
            raise ValueError("Changed loudness coefficients or endpoint/count rounding")
        regenerated_music, music_metadata = musical_input()
        for key in ("full_input_frames", "events_count", "events_sha256", "body_start_frame", "body_end_frame", "excerpt_frames"):
            if music_metadata[key] != manifest["musical_source"][key]:
                raise ValueError("Changed musical source timing or event provenance")
        compare(music_metadata["full_body_reference"], manifest["musical_source"]["full_body_reference"])
        for case in manifest["cases"]:
            samples = np.fromfile(FIXTURES / case["input_file"], dtype="<f4").reshape(-1, 2) if "input_file" in case else synthetic(case)
            if digest_samples(samples) != case["input_float32_sha256"]:
                raise ValueError("Changed exact loudness input samples")
            expected, details = measure(samples)
            frozen_error = compare(expected, case["expected"])
            if any(details[key] != case["diagnostics"][key] for key in ("absolute_indices", "relative_indices")):
                raise ValueError("Changed original loudness gate membership")
            result = dict(id=case["id"], reference=expected, frozen_lufs_error=frozen_error,
                          input_float32_sha256=case["input_float32_sha256"])
            if "input_file" in case:
                result["regenerated_music_maximum_error"] = float(np.max(abs(samples.astype(np.float64) - regenerated_music)))
                if result["regenerated_music_maximum_error"] > 2e-7:
                    raise ValueError("Changed original musical source excerpt")
            if candidates is not None:
                path = candidates / case["file"]
                actual = json.loads(path.read_text())
                result.update(native=actual, native_lufs_error=compare(actual, expected), native_sha256=HELPERS["digest"](path))
            results.append(result)
    report = dict(maximum_lufs_error=LUFS_ERROR, reference=manifest["reference"],
                  musical_source=music_metadata, results=results)
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "comparison.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps(results, indent=2, allow_nan=False))
    print(f"Verified {len(results)} original loudness measurements" + (" and native results" if candidates else ""))


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
            print(f"Frozen loudness integrity passed: {len(manifest['cases'])} cases")
        else:
            verify(manifest, provenance, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
