#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Capture unchanged v9 song-renderer buses and compare every native sample."""
import argparse
import copy
import hashlib
import importlib
import json
import math
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
PERCUSSION = runpy.run_path(str(HERE / "verify-percussion.py"))
HELPERS, VOICES, ROOT = PERCUSSION["HELPERS"], PERCUSSION["VOICES"], PERCUSSION["ROOT"]
FIXTURES = ROOT / "tests/fixtures/rhythm-v9"
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
DUCK_LIMITS = {"maximum_absolute_error": 1e-7, "rms_error": 1e-8}
CHANNELS = ["guitar_l", "guitar_r", "piano_l", "piano_r", "bass_l", "bass_r", "drums_l", "drums_r", "duck"]
CONFIGS = [("rhythm-prefix", 416000, 400000, "events-prefix.json", 17546740),
           ("rhythm-controls-low", 160000, 144000, "events-controls.json", 663684),
           ("rhythm-controls-high", 160000, 144000, "events-controls.json", 663684)]


def source_inputs():
    provenance, percussion = PERCUSSION["source_inputs"]()
    song = json.loads((ROOT / "tests/fixtures/v9/song.json").read_text())
    original = json.loads((ROOT / "tests/fixtures/v9/events.json").read_text())
    prefix = [event for event in original if event["time"] < (8 if event["instrument"] in ("guitar", "piano") else 12)]
    controls = copy.deepcopy(percussion[1])
    bass = dict(instrument="bass", note=36, time=0, local_time=0, beat=0, duration=3.75,
                release=.5, velocity=.7, pan=0, round_robin=0, role="bass", articulation="normal")
    silent = dict(controls[0], time=1 / 32000, local_time=1 / 32000, beat=1 / 32000 * 1.3, velocity=0)
    controls = sorted([*controls, bass, silent], key=lambda event: event["time"])
    if len(prefix) != 63 or len(controls) != 22 or song["energy"] != .3795510689640131:
        raise ValueError("Changed accepted rhythm score or controls")
    return provenance, song, [prefix, controls, controls], [song["energy"], 0, 1]


def probe_frames(events, frames):
    result = set(range(0, frames, 4093)) | {frames - 1}
    for event in events:
        start = round(event["time"] * 32000)
        result.update(start + offset for offset in (-1, 0, 1, 17, 256))
        if event["instrument"] == "kick":
            result.update(start + offset for offset in (8959, 8960, 8961))
        elif event["instrument"] in ("guitar", "piano", "bass"):
            for seconds in (event["duration"], event["duration"] + event["release"]):
                end = round((event["time"] + seconds) * 32000)
                result.update((end - 1, end, end + 1))
    return sorted(frame for frame in result if 0 <= frame < frames)


def load_manifest():
    provenance, song, scores, energies = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    if (manifest.get("schema_version"), manifest.get("sample_rate"), manifest.get("channel_order"), manifest.get("warmth"),
            manifest.get("tolerances"), manifest.get("duck_tolerances")) != (1, 32000, CHANNELS, .78, LIMITS, DUCK_LIMITS):
        raise ValueError("Changed rhythm format or tolerances")
    cases = manifest.get("cases", [])
    if len(cases) != 3:
        raise ValueError("Unexpected rhythm case count")
    names = {"README.md", "manifest.json"}
    for case, (name, frames, tail, filename, prepared), events, energy in zip(cases, CONFIGS, scores, energies):
        required = dict(id=name, frames=frames, channels=9, energy=energy, event_count=len(events),
                        prepared_bytes=prepared, events_file=filename, tail_silence_start_frame=tail,
                        file=name + ".f32", bytes=frames * 9 * 4)
        if any(case.get(key) != value for key, value in required.items()):
            raise ValueError("Changed rhythm case definition")
        names.add(filename)
        if HELPERS["digest"](FIXTURES / filename) != case["events_sha256"] or json.loads((FIXTURES / filename).read_text()) != events:
            raise ValueError("Changed accepted or curated rhythm events")
        if [probe.get("frame") for probe in case["probes"]] != probe_frames(events, frames):
            raise ValueError("Changed rhythm fingerprint positions")
        if len(case["channel_peak"]) != 9 or len(case["channel_rms"]) != 9 or any(len(probe["values"]) != 9 for probe in case["probes"]):
            raise ValueError("Invalid rhythm fingerprints")
        values = case["channel_peak"] + case["channel_rms"] + [value for probe in case["probes"] for value in probe["values"]]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite rhythm fingerprint")
        if len(case["full_float32_sha256"]) != 64 or any(c not in "0123456789abcdef" for c in case["full_float32_sha256"]):
            raise ValueError("Invalid frozen rhythm PCM hash")
    if {path.name for path in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing rhythm fixture file")
    return manifest, provenance, song, scores


def render(renderer, song, events, frames, energy):
    """Observe original function locals; do not reproduce its bus DSP equations."""
    import numpy as np
    session = importlib.import_module("session_render")
    source = Path(session.__file__).read_text().splitlines()
    raw_line = next(i for i, line in enumerate(source, 1) if line.startswith("    t=np.arange(n)/FS;out_start="))
    bus_line = next(i for i, line in enumerate(source, 1) if line.startswith("    mix=(tonal+bass)*duck"))
    captured = {}

    class Captured(Exception):
        pass

    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event == "line" and frame.f_lineno == raw_line:
            captured["tonal"] = np.concatenate([frame.f_locals["stems"][key].copy() for key in ("guitar", "piano")], axis=1)
        if event == "line" and frame.f_lineno == bus_line:
            captured["output"] = np.concatenate([captured["tonal"], frame.f_locals["bass"],
                                                   frame.f_locals["drums"], frame.f_locals["duck"][:, None]], axis=1)
            raise Captured
        return trace

    # Only shorten the allocation. All cases end before the original rhythm fade;
    # raw tonal stems are captured before fades, so the duration change cannot alter them.
    bounded = dict(song, duration_seconds=frames / 32000 - 5, energy=energy)
    if frames / 32000 >= session.local_seconds(song, song["bars"] * 4 - 8) - .075:
        raise ValueError("Rhythm fixture enters the deferred rack fade")
    previous_events, previous_trace = session.make_events, sys.gettrace()
    session.make_events = lambda _: copy.deepcopy(events)
    try:
        sys.settrace(trace)
        try:
            session.render_song(bounded)
        except Captured:
            pass
    finally:
        sys.settrace(previous_trace)
        session.make_events = previous_events
    output = captured.get("output")
    if output is None or output.shape != (frames, 9) or output.dtype != np.float32 or not np.isfinite(output).all():
        raise ValueError("Original song bus capture failed")
    return output


def fingerprints(samples, events):
    import numpy as np
    return {"full_float32_sha256": hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
            "channel_peak": np.max(np.abs(samples), axis=0).astype(float).tolist(),
            "channel_rms": np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
            "probes": [{"frame": frame, "values": samples[frame].astype(float).tolist()} for frame in probe_frames(events, len(samples))]}


def check_structure(samples, case, events):
    import numpy as np
    if np.any(samples[case["tail_silence_start_frame"]:, :8]) or np.any(samples[case["tail_silence_start_frame"]:, 8] != 1):
        raise ValueError("Rhythm buses did not retire to exact silence/unity")
    if np.any(samples[:, 8] < np.float32(.945)) or np.any(samples[:, 8] > 1):
        raise ValueError("Duck envelope exceeded its fixed bounds")
    starts = sorted({round(event["time"] * 32000) for event in events if event["instrument"] == "kick"})
    for index, start in enumerate(starts):
        if start < len(samples) and samples[start, 8] != np.float32(.945):
            raise ValueError("Kick did not trigger the exact duck attack")
        end = start + 8960
        if end < len(samples) and (index + 1 == len(starts) or starts[index + 1] > end) and samples[end, 8] != 1:
            raise ValueError("Duck did not end at exactly 8960 frames")
    if np.any(samples[:starts[0] if starts else len(samples), 8] != 1):
        raise ValueError("Duck was not unity before the first kick")


def verify(manifest, provenance, song, scores, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native rhythm candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    results = []
    with HELPERS["reference"](provenance) as renderer:
        for case, events in zip(manifest["cases"], scores):
            expected = render(renderer, song, events, case["frames"], case["energy"])
            check_structure(expected, case, events)
            frozen = np.asarray([probe["values"] for probe in case["probes"]], dtype=np.float32)
            indices = [probe["frame"] for probe in case["probes"]]
            HELPERS["compare"](expected[indices], frozen, LIMITS, "frozen rhythm fingerprints")
            HELPERS["compare"](expected[indices, 8], frozen[:, 8], DUCK_LIMITS, "frozen duck fingerprints")
            measured = fingerprints(expected, events)
            for key, tolerance in (("channel_peak", 1e-5), ("channel_rms", 1e-6)):
                if not np.isfinite(case[key]).all() or max(abs(a - b) for a, b in zip(case[key], measured[key])) > tolerance:
                    raise ValueError("Changed frozen rhythm channel metrics")
            item = {"id": case["id"], "frames": case["frames"], "channels": 9,
                    "frozen_float32_sha256": case["full_float32_sha256"],
                    "regenerated_float32_sha256": measured["full_float32_sha256"]}
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native rhythm candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                item.update(HELPERS["compare"](actual, expected, LIMITS, case["id"]), sha256=HELPERS["digest"](path))
                item["duck"] = HELPERS["compare"](actual[:, 8], expected[:, 8], DUCK_LIMITS, case["id"] + " duck")
                check_structure(actual, case, events)
                item["components"] = {name: HELPERS["compare"](actual[:, start:start + 2], expected[:, start:start + 2], LIMITS, name)
                                      for name, start in (("guitar", 0), ("piano", 2), ("bass", 4), ("drums", 6))}
                if evidence is not None:
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        # A rhythm-only diagnostic; no uncompressed tonal signal is presented as final audio.
                        rhythm = samples[:, 4:6] * samples[:, 8, None] + samples[:, 6:8]
                        path = evidence / (case["id"] + "-" + label + ".wav")
                        sf.write(path, rhythm, 32000, subtype="FLOAT")
                        item["audition"].append({"file": path.name, "sha256": HELPERS["digest"](path), **VOICES["measures"](rhythm)})
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified three frozen rhythm-bus cases" + (" against every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--compare", type=Path, help="Directory with exactly three interleaved nine-channel Float32 candidates")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, song, scores = load_manifest()
        if args.integrity:
            print("Frozen rhythm integrity passed: mixed accepted prefix and two energy/duck controls")
        else:
            verify(manifest, provenance, song, scores, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
