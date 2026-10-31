#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare linked peak protection with unchanged accepted v9 functions."""
import argparse
import copy
import hashlib
import importlib
import json
import math
from pathlib import Path
import runpy
import struct
import sys
import tempfile

HERE = Path(__file__).resolve().parent
VOICES = runpy.run_path(str(HERE / "verify-voices.py"))
HELPERS, ROOT = VOICES["HELPERS"], VOICES["ROOT"]
FIXTURES = ROOT / "tests/fixtures/peak-v9"
LIMITS = {"maximum_absolute_error": 2e-6, "rms_error": 2e-7}
CEILINGS = {"song": -5, "session": -2.2}


def source_inputs():
    provenance, _, _ = VOICES["source_inputs"]()
    song = json.loads((ROOT / "tests/fixtures/v9/song.json").read_text())
    events = json.loads((ROOT / "tests/fixtures/v9/events.json").read_text())
    if len(events) != 621 or round((song["duration_seconds"] + 5) * 32000) != 3711911:
        raise ValueError("Changed accepted full song")
    cases = []
    for index, count in enumerate((1, 2, 159, 160, 161, 162)):
        cases.append(dict(id=f"peak-tiny-{count}", mode="song" if index % 2 == 0 else "session",
                          frames=count, expected_file=f"peak-tiny-{count}-expected.f32",
                          input_events=[dict(frame=frame, values=values) for frame, values in
                                        [(0, [1, -.5]), (count // 2, [-.25, .75]), (count - 1, [2, -1])]]))
    for mode, ceiling in CEILINGS.items():
        threshold = struct.unpack("<f", struct.pack("<f", 10 ** (ceiling / 20)))[0]
        controls = [(0, [.125, -.0625]), (8000, [1, 0]), (8161, [0, -1]),
                    (16000, [threshold * .875, -threshold * .25]), (24000, [threshold, -threshold]),
                    (40000, [threshold * 1.125, -threshold * .25]), (48000, [4, -2]),
                    (64000, [0, .5]), (80000, [.03125, -.03125])]
        cases.append(dict(id="peak-controls-" + mode, mode=mode, frames=96000,
                          input_events=[dict(frame=frame, values=values) for frame, values in controls]))
    for mode in CEILINGS:
        ramps = [(index, [(index + 1) / 128, -(index + 1) / 256]) for index in range(161)]
        ramps += [(161 + index, [(161 - index) / 128, -(161 - index) / 256]) for index in range(161)]
        ramps += [(322 + index, [1, -.5]) for index in range(162)]
        ramps += [(1023, [.125, -.0625])]
        cases.append(dict(id="peak-ramps-" + mode, mode=mode, frames=1024,
                          input_events=[dict(frame=frame, values=values) for frame, values in ramps]))
    for mode in CEILINGS:
        chunks = [(0, [.5, -.25]), (160, [2, -1]), (32768, [.125, .25]),
                  (63840, [1.5, -.75]), (63999, [.5, -1]), (64000, [-2, .5]),
                  (64159, [.125, 4]), (64160, [-1, .5]), (64162, [.25, -.125])]
        cases.append(dict(id="peak-chunks-" + mode, mode=mode, frames=64163,
                          input_events=[dict(frame=frame, values=values) for frame, values in chunks]))
    for case in cases:
        case.update(input_frames=case["frames"], input_gain=1, complete=True)
    cases += [dict(id="peak-song-prefix", mode="song", input_gain=1),
              dict(id="peak-driven-session", mode="session", input_gain=4)]
    for case in cases[-2:]:
        case.update(frames=128000, input_frames=128160, complete=False,
                    input_file="song-prefix-input.f32", original_song_frames=3711911)
    return provenance, song, events, cases


def digest_samples(samples):
    import numpy as np
    return hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest()


def synthetic(case):
    import numpy as np
    samples = np.zeros((case["input_frames"], 2), dtype=np.float32)
    for event in case["input_events"]:
        samples[event["frame"]] = event["values"]
    return samples


def probes(case):
    count = case["frames"]
    if count <= 162:
        return list(range(count))
    positions = set(range(0, count, max(1, count // 64))) | {0, 1, 159, 160, 161, count - 1}
    for event in case.get("input_events", []):
        if "ramps" not in case["id"] or event["frame"] in (0, 160, 161, 321, 322, 483, 1023):
            positions.update(event["frame"] + offset for offset in (-161, -160, -159, -1, 0, 1, 159, 160, 161))
    return sorted(frame for frame in positions if 0 <= frame < count)


def fingerprints(samples, case):
    import numpy as np
    return dict(full_float32_sha256=digest_samples(samples),
                channel_peak=np.max(np.abs(samples), axis=0).astype(float).tolist(),
                channel_rms=np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
                probes=[dict(frame=frame, values=samples[frame].astype(float).tolist()) for frame in probes(case)])


def load_manifest():
    provenance, song, events, definitions = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, latency_frames=160, channels=2, tolerances=LIMITS)
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != 14:
        raise ValueError("Changed peak fixture format or tolerances")
    names = {"README.md", "manifest.json"}
    for case, definition in zip(manifest["cases"], definitions):
        definition = dict(definition, file=definition["id"] + ".f32", channels=2, bytes=definition["frames"] * 8)
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed peak case definition")
        for kind in ("input", "expected"):
            if kind + "_file" in definition:
                filename = case[kind + "_file"]
                names.add(filename)
                if HELPERS["digest"](FIXTURES / filename) != case[kind + "_sha256"]:
                    raise ValueError("Changed frozen peak " + kind)
                frames = case["input_frames"] if kind == "input" else case["frames"]
                if (FIXTURES / filename).stat().st_size != frames * 8:
                    raise ValueError("Incorrect frozen peak file dimensions")
        if [p.get("frame") for p in case["probes"]] != probes(case):
            raise ValueError("Changed peak fingerprint positions")
        if len(case["channel_peak"]) != 2 or len(case["channel_rms"]) != 2 or any(len(p["values"]) != 2 for p in case["probes"]):
            raise ValueError("Incorrect peak fingerprint dimensions")
        values = case["channel_peak"] + case["channel_rms"] + [v for p in case["probes"] for v in p["values"]]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite peak fingerprint")
        for key in ("full_float32_sha256", "input_float32_sha256"):
            if len(case[key]) != 64 or any(c not in "0123456789abcdef" for c in case[key]):
                raise ValueError("Invalid frozen peak PCM hash")
    if {p.name for p in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing peak fixture file")
    return manifest, provenance, song, events


def capture_song(song, events):
    """Capture the original full-song normalization and per-song protector."""
    session = importlib.import_module("session_render")
    lines = Path(session.__file__).read_text().splitlines()
    before = next(i for i, line in enumerate(lines, 1) if line.startswith("    peak=np.max(abs(mix),axis=1);look="))
    after = next(i for i, line in enumerate(lines, 1) if line.startswith("    assert np.isfinite(mix).all()"))
    captured = {}

    class Captured(Exception):
        pass

    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event == "line" and frame.f_lineno in (before, after):
            if frame.f_locals["n"] != 3711911 or len(frame.f_locals["events"]) != 621:
                raise ValueError("Changed original peak song allocation or score")
            if frame.f_lineno == before:
                captured.update(input=frame.f_locals["mix"][:128160].copy(),
                                source_body_lufs=frame.f_locals["measured"], fixed_gain_db=frame.f_locals["gain"])
            else:
                captured["output"] = frame.f_locals["mix"][:128000].copy()
                raise Captured
        return trace

    previous_events, previous_trace = session.make_events, sys.gettrace()
    session.make_events = lambda _: copy.deepcopy(events)
    try:
        sys.settrace(trace)
        try:
            session.render_song(song)
        except Captured:
            pass
    finally:
        sys.settrace(previous_trace)
        session.make_events = previous_events
    if "output" not in captured:
        raise ValueError("Original song peak capture failed")
    return captured


def protect(samples, mode):
    """Run original protector, observing y before PCM24 and final-level policy."""
    import numpy as np
    import soundfile as sf
    master = importlib.import_module("master_stream")
    lines = Path(master.__file__).read_text().splitlines()
    capture = next(i for i, line in enumerate(lines, 1) if "assert np.isfinite(y).all();dst.write(y)" in line)
    stop = next(i for i, line in enumerate(lines, 1) if line.startswith("    assert written==info.frames"))
    chunks = []

    class Captured(Exception):
        pass

    def trace(frame, event, _argument):
        if frame.f_code is not master.protect.__code__:
            return None
        if event == "line" and frame.f_lineno == capture:
            chunks.append(frame.f_locals["y"].copy())
        if event == "line" and frame.f_lineno == stop:
            if frame.f_locals["written"] != len(samples):
                raise ValueError("Original protector dropped frames")
            raise Captured
        return trace

    with tempfile.TemporaryDirectory(prefix="peak-v9-", dir=ROOT / ".build") as temporary:
        path = Path(temporary) / "input.wav"
        sf.write(path, samples, 32000, subtype="FLOAT")
        previous = sys.gettrace()
        try:
            sys.settrace(trace)
            try:
                master.protect(path, ceiling_dB=CEILINGS[mode])
            except Captured:
                pass
        finally:
            sys.settrace(previous)
    result = np.concatenate(chunks) if chunks else np.empty((0, 2), np.float32)
    if result.shape != samples.shape:
        raise ValueError("Incorrect original protector capture dimensions")
    return result


def render(song, events, case, cache):
    if "input_events" in case:
        inputs = synthetic(case)
    else:
        if "song" not in cache:
            cache["song"] = capture_song(song, events)
        inputs = cache.get("frozen_input", cache["song"]["input"]) * case["input_gain"]
    expected = protect(inputs, case["mode"])[:case["frames"]]
    capture_error = None
    if case["id"] == "peak-song-prefix":
        HELPERS["compare"](inputs, cache["song"]["input"], LIMITS, "frozen full-song peak input")
        capture_error = HELPERS["compare"](expected, cache["song"]["output"], LIMITS, "original per-song peak output")
    return expected, inputs, capture_error


def verify(manifest, provenance, song, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {p.name for p in candidates.iterdir()} != {c["file"] for c in manifest["cases"]}:
            raise ValueError("Unexpected or missing native peak candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    cache = {"frozen_input": np.fromfile(FIXTURES / "song-prefix-input.f32", dtype="<f4").reshape(-1, 2)}
    if not np.isfinite(cache["frozen_input"]).all():
        raise ValueError("Nonfinite frozen peak input")
    results = []
    with HELPERS["reference"](provenance):
        for case in manifest["cases"]:
            expected, inputs, capture_error = render(song, events, case, cache)
            if expected.shape != (case["frames"], 2) or not np.isfinite(expected).all():
                raise ValueError("Incorrect peak oracle dimensions or values")
            if digest_samples(inputs) != case["input_float32_sha256"]:
                raise ValueError("Peak inputs differ from their independent definition")
            if "expected_file" in case:
                frozen = np.fromfile(FIXTURES / case["expected_file"], dtype="<f4").reshape(expected.shape)
                if not np.isfinite(frozen).all():
                    raise ValueError("Nonfinite frozen peak waveform")
                HELPERS["compare"](expected, frozen, LIMITS, "frozen peak waveform")
            HELPERS["compare"](expected[probes(case)], np.asarray([p["values"] for p in case["probes"]], np.float32), LIMITS, "frozen peak fingerprints")
            measured = fingerprints(expected, case)
            for key, tolerance in (("channel_peak", LIMITS["maximum_absolute_error"]), ("channel_rms", LIMITS["rms_error"])):
                if max(abs(a - b) for a, b in zip(case[key], measured[key])) > tolerance:
                    raise ValueError("Changed frozen peak channel metrics")
            item = dict(id=case["id"], frames=case["frames"], channels=2,
                        frozen_float32_sha256=case["full_float32_sha256"], regenerated_float32_sha256=digest_samples(expected))
            if capture_error is not None:
                item.update(session_capture=capture_error, source_body_lufs=cache["song"]["source_body_lufs"],
                            fixed_gain_db=cache["song"]["fixed_gain_db"])
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native peak candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                item.update(HELPERS["compare"](actual, expected, LIMITS, case["id"]), sha256=HELPERS["digest"](path))
                if evidence is not None and "input_file" in case:
                    item["audition"] = []
                    variants = [("reference", expected), ("native", actual)]
                    if case["id"] == "peak-driven-session":
                        variants.insert(0, ("unprotected", inputs[:case["frames"]]))
                    for label, samples in variants:
                        path = evidence / (case["id"] + "-pre-pcm24-" + label + ".wav")
                        sf.write(path, samples, 32000, subtype="FLOAT")
                        item["audition"].append(dict(file=path.name, sha256=HELPERS["digest"](path), **VOICES["measures"](samples)))
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified 14 frozen linked-peak cases" + (" against every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--compare", type=Path, help="Exactly 14 latency-aligned stereo Float32 peak candidates")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, song, events = load_manifest()
        if args.integrity:
            print("Frozen peak integrity passed: six tiny cases, six control cases, and two musical cases")
        else:
            verify(manifest, provenance, song, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
