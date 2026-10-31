#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare rack fades and retained bus tails with unchanged v9 render_song."""
import argparse
import copy
import importlib
import json
import math
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
RHYTHM = runpy.run_path(str(HERE / "verify-rhythm.py"))
HELPERS, VOICES, ROOT = RHYTHM["HELPERS"], RHYTHM["VOICES"], RHYTHM["ROOT"]
FIXTURES = ROOT / "tests/fixtures/fades-v9"
CHANNELS = RHYTHM["CHANNELS"]
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
TAIL_LIMITS = {"maximum_absolute_error": 1e-8, "rms_error": 1e-9}
GAIN_TOLERANCE = 1e-12


def source_inputs():
    provenance, song, scores, _ = RHYTHM["source_inputs"]()
    events = copy.deepcopy(scores[0])
    for event in events:
        event["time"] = event["local_time"]
    cases = [dict(id="fades-" + name, frames=416000, channels=9, bytes=416000 * 36,
                  file="fades-" + name + ".f32", warmth=.78, energy=song["energy"],
                  events_file="events.json", event_count=63, prepared_bytes=17546740,
                  incoming_start_seconds=0, incoming_end_seconds=incoming,
                  outgoing_start_seconds=1.6000078125, outgoing_end_seconds=10.3000234375,
                  rhythm_handoff_seconds=5.900015625, rhythm_start_frame=0,
                  tonal_silence_start_frame=329601, bass_silence_start_frame=188801,
                  tail_silence_start_frame=400000, drum_tail_start_frame=188801, drum_tail_frames=3200)
             for name, incoming in (("outgoing", 0), ("incoming", 3.25001171875))]
    return provenance, song, events, cases


def gain_frames(case):
    edges = [case[key] * 32000 for key in ("incoming_start_seconds", "incoming_end_seconds",
             "outgoing_start_seconds", "outgoing_end_seconds", "rhythm_handoff_seconds")]
    edges += [case["rhythm_handoff_seconds"] * 32000 - 2400]
    positions = {math.floor(edge) + offset for edge in edges for offset in (-1, 0, 1, 2)}
    positions.update(range(0, case["frames"], max(1, case["frames"] // 32)))
    return sorted(frame for frame in positions | {case["frames"] - 1} if 0 <= frame < case["frames"])


def probes(case, events):
    positions = set(RHYTHM["probe_frames"](events, case["frames"])) | set(gain_frames(case))
    positions.update(188801 + offset for offset in (0, 1, 2, 3, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 3199))
    return sorted(positions)


def capture(song, events, case, timing_only=False, injected_stems=None):
    """Trace original locals; only the diagnostic score/clocks may be substituted."""
    import numpy as np
    session = importlib.import_module("session_render")
    source = Path(session.__file__).read_text().splitlines()
    stem_line = next(i for i, line in enumerate(source, 1) if line.startswith("    t=np.arange(n)/FS;out_start="))
    fade_line = next(i for i, line in enumerate(source, 1) if line.startswith("    guitar=stems['guitar']"))
    bus_line = next(i for i, line in enumerate(source, 1) if line.startswith("    mix=(tonal+bass)*duck"))
    captured = {}

    class Captured(Exception):
        pass

    def trace(frame, event, _argument):
        if frame.f_code is not session.render_song.__code__:
            return None
        if event == "line" and frame.f_lineno == stem_line and injected_stems is not None:
            for key, values in injected_stems.items():
                frame.f_locals["stems"][key][:len(values)] = values
        if event == "line" and frame.f_lineno == fade_line:
            captured["gain_probes"] = [dict(frame=index, tonal=float(frame.f_locals["tonal_fade"][index]),
                                           rhythm=float(frame.f_locals["rhythm_fade"][index])) for index in gain_frames(case)]
            if timing_only:
                raise Captured
            captured["tonal"] = np.concatenate([frame.f_locals["stems"][key][:case["frames"]].copy()
                                               for key in ("guitar", "piano")], axis=1)
        if event == "line" and frame.f_lineno == bus_line:
            captured["output"] = np.column_stack([captured.pop("tonal"), *[
                frame.f_locals[key][:case["frames"]] for key in ("bass", "drums", "duck")]])
            raise Captured
        return trace

    previous_events, previous_clock, previous_trace = session.make_events, session.local_seconds, sys.gettrace()
    session.make_events = lambda _: copy.deepcopy(events)
    rendered_song = song
    if not timing_only:
        clocks = {16: case["incoming_end_seconds"], song["bars"] * 4 - 16: case["outgoing_start_seconds"],
                  song["bars"] * 4 - 8: case["rhythm_handoff_seconds"]}
        session.local_seconds = lambda value, beat: clocks[beat]
        rendered_song = dict(song, duration_seconds=case["outgoing_end_seconds"],
                             in_bridge={} if case["incoming_end_seconds"] else None, energy=case["energy"])
    try:
        sys.settrace(trace)
        try:
            session.render_song(rendered_song)
        except Captured:
            pass
    finally:
        sys.settrace(previous_trace)
        session.make_events, session.local_seconds = previous_events, previous_clock
    if "gain_probes" not in captured or (not timing_only and "output" not in captured):
        raise ValueError("Original fade capture failed")
    return captured


def timing_songs(song):
    planner = importlib.import_module("session_planner")
    generator = planner.SessionPlanner(91031, planner.Controls(**song["controls"]), True)
    songs = [generator.next_song(), generator.next_song()]
    if songs[0] != {key: value for key, value in song.items() if key != "render_stats"}:
        raise ValueError("Original planner no longer reproduces the accepted first song")
    return songs


def timing_case(song):
    session = importlib.import_module("session_render")
    case = dict(id="original-song-" + str(song["id"]), frames=round((song["duration_seconds"] + 5) * 32000),
                incoming_start_seconds=0, incoming_end_seconds=session.local_seconds(song, 16) if song["in_bridge"] else 0,
                outgoing_start_seconds=session.local_seconds(song, song["bars"] * 4 - 16),
                outgoing_end_seconds=song["duration_seconds"],
                rhythm_handoff_seconds=session.local_seconds(song, song["bars"] * 4 - 8), rhythm_start_frame=0)
    return dict(case, **capture(song, [], case, timing_only=True))


def fingerprints(samples, case, events):
    import hashlib
    import numpy as np
    return dict(full_float32_sha256=hashlib.sha256(np.asarray(samples, dtype="<f4").tobytes()).hexdigest(),
                channel_peak=np.max(np.abs(samples), axis=0).astype(float).tolist(),
                channel_rms=np.sqrt(np.mean(samples.astype(np.float64) ** 2, axis=0)).tolist(),
                probes=[dict(frame=index, values=samples[index].astype(float).tolist()) for index in probes(case, events)])


def check_structure(samples, case, events):
    import numpy as np
    if samples.shape != (case["frames"], 9) or not np.isfinite(samples).all():
        raise ValueError("Incorrect fades dimensions or nonfinite samples")
    RHYTHM["check_structure"](samples, case, events)
    if np.any(samples[case["tonal_silence_start_frame"]:, :4]) or np.any(samples[case["bass_silence_start_frame"]:, 4:6]):
        raise ValueError("Faded tonal/bass stems did not end exactly")
    start = case["drum_tail_start_frame"]
    if not np.any(samples[start:start + case["drum_tail_frames"], 6:8]):
        raise ValueError("Drum filters lost their post-handoff tail")


def load_manifest():
    provenance, song, events, definitions = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    required = dict(schema_version=1, sample_rate=32000, channel_order=CHANNELS, tolerances=LIMITS,
                    tail_tolerances=TAIL_LIMITS, gain_tolerance=GAIN_TOLERANCE, timing_songs_file="timing-songs.json")
    if any(manifest.get(key) != value for key, value in required.items()) or len(manifest.get("cases", [])) != 2:
        raise ValueError("Changed fades format or tolerances")
    if {path.name for path in FIXTURES.iterdir()} != {"README.md", "manifest.json", "events.json", "timing-songs.json"}:
        raise ValueError("Unexpected or missing fades fixture file")
    if HELPERS["digest"](FIXTURES / "timing-songs.json") != manifest["timing_songs_sha256"]:
        raise ValueError("Changed original timing songs")
    songs = json.loads((FIXTURES / "timing-songs.json").read_text())
    if len(songs) != 2 or songs[0] != {key: value for key, value in song.items() if key != "render_stats"}:
        raise ValueError("Changed accepted original timing plan")
    for case, definition in zip(manifest["cases"], definitions):
        if any(case.get(key) != value for key, value in definition.items()):
            raise ValueError("Changed fades case definition")
        if HELPERS["digest"](FIXTURES / case["events_file"]) != case["events_sha256"] or json.loads((FIXTURES / case["events_file"]).read_text()) != events:
            raise ValueError("Changed accepted local score")
        if [probe.get("frame") for probe in case["probes"]] != probes(case, events):
            raise ValueError("Changed fades probe positions")
        if len(case["channel_peak"]) != 9 or len(case["channel_rms"]) != 9 or any(len(p["values"]) != 9 for p in case["probes"]):
            raise ValueError("Invalid fades fingerprint dimensions")
        values = case["channel_peak"] + case["channel_rms"] + [value for p in case["probes"] for value in p["values"]]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Nonfinite fades fingerprints")
        digest = case["full_float32_sha256"]
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("Invalid frozen fades PCM hash")
    if len(manifest.get("timing_cases", [])) != 2:
        raise ValueError("Invalid original timing case count")
    for case in manifest["cases"] + manifest["timing_cases"]:
        if [probe.get("frame") for probe in case["gain_probes"]] != gain_frames(case) or any(
                not isinstance(p[key], (int, float)) or not math.isfinite(p[key]) or not 0 <= p[key] <= 1
                for p in case["gain_probes"] for key in ("tonal", "rhythm")):
            raise ValueError("Invalid original gain fingerprints")
    return manifest, provenance, song, events


def check_gains(actual, expected):
    if len(actual) != len(expected) or any(a["frame"] != b["frame"] or any(
            abs(a[key] - b[key]) > GAIN_TOLERANCE for key in ("tonal", "rhythm")) for a, b in zip(actual, expected)):
        raise ValueError("Changed original Double fade gains")


def verify(manifest, provenance, song, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in manifest["cases"]}:
            raise ValueError("Unexpected or missing native fades candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    results = []
    with HELPERS["reference"](provenance):
        songs = timing_songs(song)
        if songs != json.loads((FIXTURES / "timing-songs.json").read_text()):
            raise ValueError("Original planner timing songs changed")
        for original, frozen in zip(songs, manifest["timing_cases"]):
            measured = timing_case(original)
            if {key: value for key, value in measured.items() if key != "gain_probes"} != {
                    key: value for key, value in frozen.items() if key != "gain_probes"}:
                raise ValueError("Changed full-song fade timing")
            check_gains(measured["gain_probes"], frozen["gain_probes"])
        for case in manifest["cases"]:
            captured = capture(song, events, case)
            expected = captured["output"]
            check_structure(expected, case, events)
            check_gains(captured["gain_probes"], case["gain_probes"])
            indices = probes(case, events)
            frozen = np.asarray([p["values"] for p in case["probes"]], dtype=np.float32)
            HELPERS["compare"](expected[indices], frozen, LIMITS, "frozen fades fingerprints")
            if not np.array_equal(expected[indices, 8], frozen[:, 8]):
                raise ValueError("Changed frozen score-driven duck")
            tail_indices = [index for index, frame in enumerate(indices) if case["drum_tail_start_frame"] <= frame <
                            case["drum_tail_start_frame"] + case["drum_tail_frames"]]
            HELPERS["compare"](expected[np.asarray(indices)[tail_indices], 6:8], frozen[tail_indices, 6:8],
                               TAIL_LIMITS, "frozen post-handoff drum tail")
            measured = fingerprints(expected, case, events)
            for key, limit in (("channel_peak", 1e-5), ("channel_rms", 1e-6)):
                if max(abs(a - b) for a, b in zip(measured[key], case[key])) > limit:
                    raise ValueError("Changed frozen fades channel metrics")
            item = dict(id=case["id"], frames=case["frames"], channels=9,
                        frozen_float32_sha256=case["full_float32_sha256"], regenerated_float32_sha256=measured["full_float32_sha256"])
            if candidates is not None:
                path = candidates / case["file"]
                if path.stat().st_size != case["bytes"]:
                    raise ValueError("Incorrect native fades candidate length")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                item.update(HELPERS["compare"](actual, expected, LIMITS, case["id"]), sha256=HELPERS["digest"](path))
                check_structure(actual, case, events)
                if not np.array_equal(actual[:, 8], expected[:, 8]):
                    raise ValueError("Native score-driven duck differs")
                item["duck_exact"] = True
                item["components"] = {name: HELPERS["compare"](actual[:, start:start + 2], expected[:, start:start + 2], LIMITS, name)
                                      for name, start in (("guitar", 0), ("piano", 2), ("bass", 4), ("drums", 6))}
                tail = slice(case["drum_tail_start_frame"], case["drum_tail_start_frame"] + case["drum_tail_frames"])
                item["drum_tail"] = HELPERS["compare"](actual[tail, 6:8], expected[tail, 6:8], TAIL_LIMITS, "post-handoff drum tail")
                if evidence is not None:
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        for stem, audio in (("dry-harmonic", samples[:, :2] + samples[:, 2:4]),
                                            ("rhythm", samples[:, 4:6] * samples[:, 8, None] + samples[:, 6:8])):
                            path = evidence / (case["id"] + "-" + stem + "-" + label + ".wav")
                            sf.write(path, audio, 32000, subtype="FLOAT")
                            item["audition"].append(dict(file=path.name, label="Unmastered pre-glue/pre-room " + stem,
                                                         sha256=HELPERS["digest"](path), **VOICES["measures"](audio)))
            results.append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print("Verified two frozen rack-fade bus cases and two full-song timing captures" + (" against every native sample" if candidates else ""))


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
            print("Frozen rack-fade integrity passed: two bus cases and original full-song timing")
        else:
            verify(manifest, provenance, song, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        sys.exit(str(error))
