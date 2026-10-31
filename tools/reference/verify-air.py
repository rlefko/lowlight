#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Verify quiet air against unchanged NumPy and accepted v9 render_song."""
import argparse
import copy
import ctypes
import hashlib
import importlib
import json
import math
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
FADES = runpy.run_path(str(HERE / "verify-fades.py"))
HELPERS, VOICES, ROOT = FADES["HELPERS"], FADES["VOICES"], FADES["ROOT"]
FIXTURES = ROOT / "tests/fixtures/air-v9"
LIMITS = {"maximum_absolute_error": 2e-9, "rms_error": 2e-10}
CARRIER_LIMITS = {"maximum_absolute_error": 1e-8, "rms_error": 1e-9}
LENGTHS = (1, 7, 8, 127, 128, 129, 8191, 8192, 8193, 16385)
FADE_KEYS = ("tonal_in_start_frame", "tonal_in_end_frame", "tonal_out_start_frame",
             "tonal_out_end_frame", "rhythm_in_frame", "rhythm_out_frame")


def source_inputs():
    provenance, song, _, _ = FADES["source_inputs"]()
    songs = json.loads((ROOT / "tests/fixtures/fades-v9/timing-songs.json").read_text())
    if songs[0] != {key: value for key, value in song.items() if key != "render_stats"}:
        raise ValueError("Changed accepted air song")
    definitions = []
    for index, count in enumerate(LENGTHS):
        origin = 1099511627776 if count == 8193 else (4096 if index % 2 else 0)
        incoming = min(count, max(1, count // 3 + .375)) if count > 1 else 0
        out_start, out_end = (0, 1) if count == 1 else (count // 4 + .25, count - 1.25)
        fades = dict(zip(FADE_KEYS, (origin if incoming else 0, origin + incoming if incoming else 0,
                                     origin + out_start, origin + out_end, origin, origin + out_end)))
        definitions.append(dict(id="air-n" + str(count), frames=count, seed=(0, 2147483647, 1278560406)[index % 3],
                                texture=0 if count == 128 else 1, frame_origin=origin, fades=fades,
                                carrier="dyadic31" if index % 2 == 0 else "zero", windows=[dict(start=0, count=count)]))
    for index, original in enumerate(songs):
        count = round((original["duration_seconds"] + 5) * 32000)
        origin = round(original["start_seconds"] * 32000)
        # Timing values are frozen original captures, not a second tempo-clock implementation.
        timing = json.loads((ROOT / "tests/fixtures/fades-v9/manifest.json").read_text())["timing_cases"][index]
        incoming = timing["incoming_end_seconds"] * 32000
        fades = dict(zip(FADE_KEYS, (origin if incoming else 0, origin + incoming if incoming else 0,
                         origin + timing["outgoing_start_seconds"] * 32000,
                         origin + timing["outgoing_end_seconds"] * 32000, origin,
                         origin + timing["rhythm_handoff_seconds"] * 32000)))
        definitions.append(dict(id="air-song-" + str(index), frames=count, seed=original["take_seed"],
                                texture=original["parameters"]["texture"], frame_origin=origin, fades=fades,
                                carrier="zero", song_index=index, windows=[dict(start=0, count=16000),
                                dict(start=512000, count=32000),
                                dict(start=round((original["duration_seconds"] - .75) * 32000), count=32000),
                                dict(start=count - 64, count=64)]))
    for case in definitions:
        case.update(file=case["id"] + ".f32", output_frames=sum(w["count"] for w in case["windows"]), channels=2)
        case["bytes"] = case["output_frames"] * 8
    return provenance, songs, definitions


def carrier(case):
    import numpy as np
    frame = np.arange(case["frames"], dtype=np.int64)[:, None]
    return (np.zeros((case["frames"], 2), np.float32) if case["carrier"] == "zero" else
            (((frame * 17 + np.arange(2) * 11) % 31) - 15).astype(np.float32) / np.float32(256))


def positions(case):
    return [index for window in case["windows"] for index in range(window["start"], window["start"] + window["count"])]


def probes(case):
    result = set(range(0, case["output_frames"], max(1, case["output_frames"] // 96)))
    offset = 0
    edges = [value - case["frame_origin"] for key, value in case["fades"].items() if key.startswith("tonal_")]
    for window in case["windows"]:
        result.update(offset + x for x in (0, 1, 2, window["count"] - 2, window["count"] - 1) if 0 <= x < window["count"])
        for edge in edges:
            result.update(offset + math.floor(edge) + delta - window["start"] for delta in (-1, 0, 1, 2)
                          if window["start"] <= math.floor(edge) + delta < window["start"] + window["count"])
        offset += window["count"]
    return sorted(result)


def random_vectors():
    """Original NumPy entry points, including its compiled normal with a word callback."""
    import numpy as np
    def fnv(data):
        result = 14695981039346656037
        for byte in data:
            result = ((result ^ byte) * 1099511628211) & ((1 << 64) - 1)
        return f"{result:016x}"
    vectors = []
    for seed in (0, 1, 1278560406, 2147483647):
        generator = np.random.default_rng(seed + 91)
        initial = copy.deepcopy(generator.bit_generator.state)
        raw = np.random.PCG64(seed + 91).random_raw(8)
        left = generator.standard_normal(16385).astype("<f4")
        right_start = copy.deepcopy(generator.bit_generator.state)
        right = generator.standard_normal(16385).astype("<f4")
        vectors.append(dict(seed=seed, seed_sequence_uint32=np.random.SeedSequence(seed + 91).generate_state(8).tolist(),
                            initial_state=initial, raw64=[f"{int(v):016x}" for v in raw], frames_per_channel=16385,
                            left_first_bits=[f"{int(v):08x}" for v in left[:16].view("<u4")],
                            right_first_bits=[f"{int(v):08x}" for v in right[:16].view("<u4")],
                            left_fnv1a64=fnv(left.tobytes()), right_fnv1a64=fnv(right.tobytes()),
                            right_start_state=right_start, final_state=generator.bit_generator.state))
    next64 = ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_void_p)
    next32 = ctypes.CFUNCTYPE(ctypes.c_uint32, ctypes.c_void_p)
    next_double = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_void_p)
    class BitGenerator(ctypes.Structure):
        _fields_ = [("state", ctypes.c_void_p), ("next_uint64", next64), ("next_uint32", next32),
                    ("next_double", next_double), ("next_raw", next64)]
    normal = ctypes.CDLL(np.random._generator.__file__).random_standard_normal
    normal.argtypes, normal.restype = [ctypes.POINTER(BitGenerator)], ctypes.c_double
    largest = (1 << 52) - 1
    recipes = [("fast-positive", [(1 << 57) | 128]), ("fast-negative", [(1 << 57) | 384]),
               ("wedge-accept", [(1 << 60) | 1, 0]),
               ("wedge-reject-then-fast", [(largest << 9) | 1, (1 << 64) - 1, (1 << 57) | 128]),
               ("tail-negative", [largest << 9, 1 << 63, 1 << 63]),
               ("tail-retry-positive", [(largest ^ 256) << 9, 0, 0, 1 << 63, 1 << 63])]
    branches = []
    for name, words in recipes:
        consumed = []
        def draw(_):
            value = words[len(consumed)] if len(consumed) < len(words) else 1 << 63
            consumed.append(value)
            return value
        cb64, cb32 = next64(draw), next32(lambda state: draw(state) & 0xffffffff)
        cb_double = next_double(lambda state: (draw(state) >> 11) * (1.0 / 9007199254740992.0))
        state = BitGenerator(None, cb64, cb32, cb_double, cb64)
        value = normal(ctypes.byref(state))
        if consumed != words:
            raise ValueError("Original normal branch recipe consumed unexpected words")
        branches.append(dict(id=name, words=[f"{word:016x}" for word in words], raw_draws=len(consumed),
                             normal_double=value, normal_float32_bits=f"{np.float32(value).view(np.uint32).item():08x}"))
    return dict(numpy_version=np.__version__, normal_source="numpy.random._generator:random_standard_normal (unchanged compiled original)",
                seeds=vectors, branches=branches)


def render(songs, case):
    import numpy as np
    session = importlib.import_module("session_render")
    source = Path(session.__file__).read_text().splitlines()
    line = lambda prefix: next(index for index, value in enumerate(source, 1) if value.startswith(prefix))
    before_fade, before_air = line("    t=np.arange(n)/FS;out_start="), line("    rng=np.random.default_rng")
    before_filter, before_scale = line("        air=ins.filt"), line("        air*=p['texture']")
    done = line("    mix=ins.filt(mix,32")
    captured = {"channels": []}
    song = copy.deepcopy(songs[case.get("song_index", 0)])
    song["take_seed"], song["parameters"]["texture"] = case["seed"], case["texture"]
    original = "song_index" in case
    if not original:
        song["duration_seconds"] = case["frames"] / 32000 - 5
        song["in_bridge"] = {} if case["fades"]["tonal_in_end_frame"] else None
    inputs = carrier(case)
    indices = positions(case)
    class Captured(Exception):
        pass
    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event != "line":
            return trace
        if frame.f_lineno == before_fade and not original:
            # CPython's trace-local synchronization changes this clock without changing N.
            frame.f_locals["duration"] = (case["fades"]["tonal_out_end_frame"] - case["frame_origin"]) / 32000
        if frame.f_lineno == before_air:
            if frame.f_locals["n"] != case["frames"]:
                raise ValueError("Original air allocation length changed")
            frame.f_locals["mix"][:] = inputs
            captured["fade_probes"] = [float(frame.f_locals["tonal_fade"][indices[i]]) for i in probes(case)]
        if frame.f_lineno == before_filter:
            captured["channels"].append(dict(start_state=copy.deepcopy(frame.f_locals["rng"].bit_generator.state)))
        if frame.f_lineno == before_scale:
            air = frame.f_locals["air"]
            rms = float(np.sqrt(np.mean(air * air)))
            captured["channels"][-1].update(filtered_rms=rms, normalization_gain=float(np.float32(case["texture"] * .00065 / max(rms, 1e-9))),
                                           end_state=copy.deepcopy(frame.f_locals["rng"].bit_generator.state))
        if frame.f_lineno == done:
            captured["output"] = frame.f_locals["mix"][indices].copy()
            captured["full_stream_float32_sha256"] = hashlib.sha256(frame.f_locals["mix"].astype("<f4").tobytes()).hexdigest()
            raise Captured
        return trace
    previous_events, previous_clock, previous_trace = session.make_events, session.local_seconds, sys.gettrace()
    session.make_events = lambda _: []
    if not original:
        clocks = {16: (case["fades"]["tonal_in_end_frame"] - case["frame_origin"]) / 32000,
                  song["bars"] * 4 - 16: (case["fades"]["tonal_out_start_frame"] - case["frame_origin"]) / 32000,
                  song["bars"] * 4 - 8: (case["fades"]["rhythm_out_frame"] - case["frame_origin"]) / 32000}
        session.local_seconds = lambda value, beat: clocks[beat]
    try:
        sys.settrace(trace)
        try:
            session.render_song(song)
        except Captured:
            pass
    finally:
        sys.settrace(previous_trace)
        session.make_events, session.local_seconds = previous_events, previous_clock
    if "output" not in captured or len(captured["channels"]) != 2:
        raise ValueError("Original air capture failed")
    return captured, inputs[indices]


def fingerprint(samples, case):
    import numpy as np
    source = positions(case)
    return dict(full_float32_sha256=hashlib.sha256(samples.astype("<f4").tobytes()).hexdigest(),
                channel_peak=np.max(abs(samples), axis=0).astype(float).tolist(),
                channel_rms=np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
                probes=[dict(frame=index, source_frame=source[index], values=samples[index].astype(float).tolist()) for index in probes(case)])


def check_structure(samples, inputs, case):
    import numpy as np
    if samples.shape != (case["output_frames"], 2) or not np.isfinite(samples).all():
        raise ValueError("Incorrect air dimensions or nonfinite samples")
    silent = np.asarray(positions(case), dtype=np.float64) + case["frame_origin"] >= case["fades"]["tonal_out_end_frame"]
    if case["texture"] == 0:
        silent[:] = True
    if not np.array_equal(samples[silent], inputs[silent]):
        raise ValueError("Zero texture or completed fade changed the carrier")
    if case["texture"] and not np.any(samples != inputs):
        raise ValueError("Quiet air is missing")


def load_manifest():
    provenance, songs, definitions = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, channels=2, maximum_frames=5792000, maximum_raw_draws_per_normal=64,
                    tolerances=LIMITS, carrier_tolerances=CARRIER_LIMITS, random_vectors_file="random-vectors.json")
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != 12:
        raise ValueError("Changed air schema or tolerances")
    if {p.name for p in FIXTURES.iterdir()} != {"README.md", "manifest.json", "random-vectors.json"}:
        raise ValueError("Unexpected or missing air fixture file")
    if HELPERS["digest"](FIXTURES / "random-vectors.json") != manifest["random_vectors_sha256"]:
        raise ValueError("Changed original random vectors")
    if HELPERS["digest"](ROOT / "tests/fixtures/fades-v9/timing-songs.json") != manifest["timing_songs_sha256"]:
        raise ValueError("Changed original timing plans")
    for case, definition in zip(manifest["cases"], definitions):
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed air case definition")
        if [probe["frame"] for probe in case["probes"]] != probes(case):
            raise ValueError("Changed air probe positions")
        indices = positions(case)
        if any(probe.get("source_frame") != indices[probe["frame"]] or len(probe["values"]) != 2 for probe in case["probes"]):
            raise ValueError("Invalid air probe source/dimensions")
        if len(case["channel_peak"]) != 2 or len(case["channel_rms"]) != 2 or len(case["normalization"]) != 2:
            raise ValueError("Invalid air channel metadata")
        values = case["channel_peak"] + case["channel_rms"] + [v for probe in case["probes"] for v in probe["values"]]
        values += [channel[key] for channel in case["normalization"] for key in ("filtered_rms", "normalization_gain")]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite air fingerprint")
        if len(case["fade_probes"]) != len(case["probes"]) or any(not math.isfinite(v) or not 0 <= v <= 1 for v in case["fade_probes"]):
            raise ValueError("Invalid fade fingerprints")
        for key in ("full_float32_sha256", "full_stream_float32_sha256"):
            value = case[key]
            if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
                raise ValueError("Invalid frozen air hash")
    return manifest, provenance, songs


def verify(manifest, provenance, songs, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if random_vectors() != json.loads((FIXTURES / "random-vectors.json").read_text()):
        raise ValueError("Original SeedSequence/PCG64/normal vectors changed")
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {p.name for p in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native air candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    results = []
    with HELPERS["reference"](provenance):
        if FADES["timing_songs"](songs[0]) != songs:
            raise ValueError("Original planner air songs changed")
        for case in manifest["cases"]:
            captured, inputs = render(songs, case)
            expected = captured["output"]
            check_structure(expected, inputs, case)
            limits = LIMITS if case["carrier"] == "zero" else CARRIER_LIMITS
            frozen = np.asarray([probe["values"] for probe in case["probes"]], dtype=np.float32)
            HELPERS["compare"](expected[probes(case)], frozen, limits, "frozen air probes")
            measured = fingerprint(expected, case)
            for key, limit in (("channel_peak", limits["maximum_absolute_error"]), ("channel_rms", limits["rms_error"])):
                if max(abs(a - b) for a, b in zip(measured[key], case[key])) > limit:
                    raise ValueError("Changed air channel metrics")
            for actual, frozen_channel in zip(captured["channels"], case["normalization"]):
                if actual["start_state"] != frozen_channel["start_state"] or actual["end_state"] != frozen_channel["end_state"]:
                    raise ValueError("Original air channel RNG boundary changed")
                for key in ("filtered_rms", "normalization_gain"):
                    if abs(actual[key] - frozen_channel[key]) > abs(float(np.spacing(np.float32(frozen_channel[key])))):
                        raise ValueError("Changed original air normalization beyond one Float32 ULP")
            if max(abs(a - b) for a, b in zip(captured["fade_probes"], case["fade_probes"])) > 1e-12:
                raise ValueError("Changed original air fades")
            item = dict(id=case["id"], frames=case["frames"], output_frames=case["output_frames"], channels=2,
                        frozen_float32_sha256=case["full_float32_sha256"], regenerated_float32_sha256=measured["full_float32_sha256"],
                        frozen_full_stream_sha256=case["full_stream_float32_sha256"], regenerated_full_stream_sha256=captured["full_stream_float32_sha256"],
                        normalization=captured["channels"])
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native air candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                check_structure(actual, inputs, case)
                item.update(HELPERS["compare"](actual, expected, limits, case["id"]), sha256=HELPERS["digest"](path))
                if evidence is not None and "song_index" in case:
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        for gain_db in (0, 40):
                            audio = samples * np.float32(10 ** (gain_db / 20))
                            path = evidence / (case["id"] + "-isolated-plus" + str(gain_db) + "db-" + label + ".wav")
                            sf.write(path, audio, 32000, subtype="FLOAT")
                            levels = VOICES["measures"](audio)
                            if not math.isfinite(levels["integrated_lufs"]):
                                levels["integrated_lufs"] = None
                                levels["integrated_lufs_status"] = "below absolute loudness gate"
                            item["audition"].append(dict(file=path.name, gain_db=gain_db,
                                label="Isolated air; ordered windows; common diagnostic gain; unmastered",
                                sha256=HELPERS["digest"](path), **levels))
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified 12 original quiet-air cases, RNG branches, normalization and full-length channel boundaries" + (" against native windows" if candidates else ""))


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
        manifest, provenance, songs = load_manifest()
        if args.integrity:
            print("Frozen air integrity passed: 12 cases and independent random vectors")
        else:
            verify(manifest, provenance, songs, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        sys.exit(str(error))
