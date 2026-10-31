#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare linked harmonic compression with the unchanged accepted v9 glue."""
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
RHYTHM = runpy.run_path(str(HERE / "verify-rhythm.py"))
HELPERS, VOICES, ROOT = RHYTHM["HELPERS"], RHYTHM["VOICES"], RHYTHM["ROOT"]
FIXTURES = ROOT / "tests/fixtures/glue-v9"
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
SYNTHETIC_LIMITS = {"maximum_absolute_error": 2e-6, "rms_error": 2e-7}
CHANNELS = ["tonal_l", "tonal_r", "bass_l", "bass_r", "drums_l", "drums_r", "duck"]
LENGTHS = (1, 2, 3, 17, 399, 400, 401, 799, 800, 801, 4097)


def source_inputs():
    provenance, song, scores, _ = RHYTHM["source_inputs"]()
    cases = [dict(id=f"boundary-{frames}", focus="piano" if index % 2 else "guitar",
                  frames=frames, input_frames=frames, input_file=f"boundary-{frames}-input.f32",
                  expected_file=f"boundary-{frames}-expected.f32") for index, frames in enumerate(LENGTHS)]
    cases += [dict(id="dynamics-" + focus, focus=focus, frames=48000, input_frames=48000,
                   input_file="dynamics-input.f32") for focus in ("guitar", "piano")]
    cases += [dict(id="score-" + focus, focus=focus, frames=416000, input_frames=3711911,
                   events_file="events.json", energy=song["energy"], prepared_bytes=17546740)
              for focus in ("guitar", "piano")]
    if round((song["duration_seconds"] + 5) * 32000) != 3711911:
        raise ValueError("Changed original song allocation")
    return provenance, song, scores[0], cases


def synthetic(case):
    """Exact dyadic test inputs, independent of any compressor implementation."""
    import numpy as np
    count = case["input_frames"]
    index = np.arange(count)
    samples = np.zeros((count, 9), dtype=np.float32)
    samples[:, 4] = ((index % 13) - 6) / 128
    samples[:, 5] = ((index % 17) - 8) / 256
    samples[:, 6] = (index % 7) / 512
    samples[:, 7] = -(index % 11) / 512
    samples[:, 8] = 1 - (index % 5) / 128
    if case["id"].startswith("boundary-"):
        samples[:, :4] = [.00390625, -.001953125, .001953125, .00390625]
        samples[0, :4] = [.125, -.0625, .03125, .015625]
        samples[(count - 1) // 2, :4] = [1, -.5, .015625, -.03125]
        samples[-1, :4] = [-.5, .25, .0625, .03125]
    else:
        levels = [[.00390625, -.001953125, 0, 0], [.015625, .015625, 0, 0],
                  [.0234375, .0234375, 0, 0], [.03125, -.03125, 0, 0],
                  [.046875, -.046875, 0, 0], [.125, -.125, 0, 0],
                  [.125, 0, 0, 0], [0, .125, 0, 0],
                  [.03125, -.03125, -.03125, .03125], [0, 0, 0, 0],
                  [.0078125, -.0078125, 0, 0], [.03125, -.015625, .015625, .03125]]
        for block, values in enumerate(levels):
            samples[block * 4000:(block + 1) * 4000, :4] = values
        samples[-1, :4] = [1, -.5, .125, -.0625]
    return samples


def probes(case):
    count = case["frames"]
    result = set(range(0, count, max(1, count // 64))) | {0, 1, 17, 398, 399, 400, 401, count - 2, count - 1}
    if case["id"].startswith("boundary-"):
        middle = (count - 1) // 2
        result.update((middle - 1, middle, middle + 1))
    elif case["id"].startswith("dynamics-"):
        result.update(edge + offset for edge in range(0, count, 4000) for offset in (-400, -399, -1, 0, 1, 399, 400))
    return sorted(frame for frame in result if 0 <= frame < count)


def digest_samples(samples):
    import numpy as np
    return hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest()


def fingerprints(samples, case):
    import numpy as np
    return {"full_float32_sha256": digest_samples(samples),
            "channel_peak": np.max(np.abs(samples), axis=0).astype(float).tolist(),
            "channel_rms": np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
            "probes": [{"frame": frame, "values": samples[frame].astype(float).tolist()} for frame in probes(case)]}


def load_manifest():
    provenance, song, events, definitions = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, latency_frames=399, warmth=.78,
                    channel_order=CHANNELS, input_channel_order=RHYTHM["CHANNELS"],
                    tolerances=LIMITS, synthetic_tolerances=SYNTHETIC_LIMITS)
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != 15:
        raise ValueError("Changed glue fixture format or tolerances")
    names = {"README.md", "manifest.json"}
    for case, definition in zip(manifest["cases"], definitions):
        definition = dict(definition, file=definition["id"] + ".f32", channels=7, bytes=definition["frames"] * 7 * 4)
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed glue case definition")
        for kind in ("input", "events", "expected"):
            if kind + "_file" in definition:
                name = case[kind + "_file"]
                names.add(name)
                if HELPERS["digest"](FIXTURES / name) != case[kind + "_sha256"]:
                    raise ValueError("Changed frozen glue " + kind)
                if kind == "input" and (FIXTURES / name).stat().st_size != case["input_frames"] * 9 * 4:
                    raise ValueError("Incorrect synthetic input dimensions")
                if kind == "expected" and (FIXTURES / name).stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect frozen output dimensions")
                if kind == "events" and json.loads((FIXTURES / name).read_text()) != events:
                    raise ValueError("Changed accepted glue events")
        if [probe.get("frame") for probe in case["probes"]] != probes(case):
            raise ValueError("Changed glue fingerprint positions")
        values = case["channel_peak"] + case["channel_rms"] + [case["maximum_gain_reduction_db"]]
        if len(case["channel_peak"]) != 7 or len(case["channel_rms"]) != 7 or any(len(probe["values"]) != 7 for probe in case["probes"]):
            raise ValueError("Incorrect glue fingerprint dimensions")
        values += [value for probe in case["probes"] for value in probe["values"]]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite glue fingerprint")
        if len(case["full_float32_sha256"]) != 64 or any(c not in "0123456789abcdef" for c in case["full_float32_sha256"]):
            raise ValueError("Invalid frozen glue PCM hash")
    if {path.name for path in FIXTURES.iterdir()} != names:
        raise ValueError("Unexpected or missing glue fixture file")
    return manifest, provenance, song, events


def render_score(renderer, song, events, case):
    """Capture original post-glue locals with the full original allocation/fades."""
    import numpy as np
    session = importlib.import_module("session_render")
    source = Path(session.__file__).read_text().splitlines()
    line = next(i for i, text in enumerate(source, 1) if text.startswith("    wet=tone.room(tonal,"))
    captured = {}

    class Captured(Exception):
        pass

    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event == "line" and frame.f_lineno == line:
            if frame.f_locals["n"] != case["input_frames"]:
                raise ValueError("Original glue allocation changed")
            captured["tonal"] = frame.f_locals["tonal"][:case["frames"]].copy()
            captured["reduction"] = frame.f_locals["compression"]
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
    if "tonal" not in captured:
        raise ValueError("Original glue capture failed")
    # The already independent rhythm capture is valid before its deferred handoff.
    inputs = RHYTHM["render"](renderer, song, events, case["frames"], case["energy"])
    return np.concatenate([captured["tonal"], inputs[:, 4:]], axis=1), inputs, captured["reduction"]


def render(renderer, song, events, case):
    import numpy as np
    if "events_file" in case:
        return render_score(renderer, song, events, case)
    inputs = synthetic(case)
    # These are the two accepted focus multiplications, before the unchanged glue.
    guitar = inputs[:, :2] * (1 if case["focus"] == "guitar" else .85)
    piano = inputs[:, 2:4] * (.94 if case["focus"] == "guitar" else 1.08)
    tonal, reduction = renderer.glue(guitar + piano)
    return np.concatenate([tonal, inputs[:, 4:]], axis=1), inputs, reduction


def verify(manifest, provenance, song, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native glue candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    results = []
    with HELPERS["reference"](provenance) as renderer:
        for case in manifest["cases"]:
            expected, inputs, reduction = render(renderer, song, events, case)
            limits = LIMITS if "events_file" in case else SYNTHETIC_LIMITS
            if expected.shape != (case["frames"], 7) or not np.isfinite(expected).all():
                raise ValueError("Incorrect glue oracle dimensions or values")
            if "input_file" in case and digest_samples(inputs) != case["input_sha256"]:
                raise ValueError("Synthetic inputs differ from their independent definition")
            if "expected_file" in case:
                frozen = np.fromfile(FIXTURES / case["expected_file"], dtype="<f4").reshape(expected.shape)
                if not np.isfinite(frozen).all():
                    raise ValueError("Nonfinite frozen glue waveform")
                HELPERS["compare"](expected, frozen, limits, "frozen glue waveform")
            frozen = np.asarray([probe["values"] for probe in case["probes"]], dtype=np.float32)
            HELPERS["compare"](expected[probes(case)], frozen, limits, "frozen glue fingerprints")
            measured = fingerprints(expected, case)
            for key, tolerance in (("channel_peak", limits["maximum_absolute_error"]), ("channel_rms", limits["rms_error"])):
                if max(abs(a - b) for a, b in zip(case[key], measured[key])) > tolerance:
                    raise ValueError("Changed frozen glue channel metrics")
            if abs(reduction - case["maximum_gain_reduction_db"]) > 1e-5:
                raise ValueError("Changed reference compression depth")
            item = dict(id=case["id"], frames=case["frames"], channels=7, maximum_gain_reduction_db=reduction,
                        frozen_float32_sha256=case["full_float32_sha256"], regenerated_float32_sha256=digest_samples(expected))
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native glue candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                item.update(HELPERS["compare"](actual, expected, limits, case["id"]), sha256=HELPERS["digest"](path))
                item["tonal"] = HELPERS["compare"](actual[:, :2], expected[:, :2], limits, case["id"] + " tonal")
                if not np.array_equal(actual[:, 6], inputs[:, 8]):
                    raise ValueError("Glue did not preserve aligned duck values exactly")
                if "input_file" in case and not np.array_equal(actual[:, 2:], inputs[:, 4:]):
                    raise ValueError("Synthetic bass/drums/duck did not retain exact delay alignment")
                if "events_file" in case and np.any(actual[400000:, :6]):
                    raise ValueError("Realistic glue prefix did not retire to exact silence")
                if evidence is not None and case["frames"] >= 48000:
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        path = evidence / (case["id"] + "-unmastered-pre-room-" + label + ".wav")
                        sf.write(path, samples[:, :2], 32000, subtype="FLOAT")
                        item["audition"].append({"file": path.name, "sha256": HELPERS["digest"](path), **VOICES["measures"](samples[:, :2])})
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified 15 frozen linked-glue cases" + (" against every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--compare", type=Path, help="Exactly 15 latency-aligned seven-channel Float32 candidates")
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, song, events = load_manifest()
        if args.integrity:
            print("Frozen glue integrity passed: 11 boundaries, two dynamics cases, and both accepted focus settings")
        else:
            verify(manifest, provenance, song, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
