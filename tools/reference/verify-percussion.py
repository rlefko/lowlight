#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare native one-shot percussion with unchanged v9 pitched/add_note functions."""
import argparse
import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
VOICES = runpy.run_path(str(HERE / "verify-voices.py"))
HELPERS, ROOT = VOICES["HELPERS"], VOICES["ROOT"]
FIXTURES = ROOT / "tests/fixtures/percussion-v9"
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}
CONFIGS = [("percussion-prefix", 416000, 392079, "events.json"),
           ("percussion-controls", 160000, 126400, "controls.json")]
BODIES = [{"instrument": inst, "note": int(inst == "snare"), "round_robin": rr,
           "velocity": velocity, "file": f"body-{inst}-{suffix}{rr}.f32"}
          for inst, velocity, suffix, takes in [("kick", .5, "", 2), ("snare", .5, "", 2),
                                                ("hat", .71999999, "1-", 2), ("hat", .72, "2-", 2),
                                                ("shaker", .5, "", 4)] for rr in range(takes)]


def source_inputs():
    provenance = json.loads((HERE / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if HELPERS["digest"](ROOT / name) != expected:
            raise ValueError(f"Changed frozen v9 input: {name}")
    events = json.loads((ROOT / "tests/fixtures/v9/events.json").read_text())
    prefix = [event for event in events if event["instrument"] in ("kick", "snare", "hat", "shaker") and event["time"] < 12]
    if len(prefix) != 36:
        raise ValueError("Unexpected accepted percussion prefix")
    matrix = [("kick", 0, 1, -1), ("kick", 1, .5, 1), ("snare", 0, 1, -1), ("snare", 1, .075, -.06),
              ("hat", 0, .719999999, .18), ("hat", 1, .71999999, -1), ("hat", 0, .72, .18), ("hat", 1, 1, 1),
              ("shaker", 0, 1, -1), ("shaker", 1, .095, -.3), ("shaker", 2, .5, 0), ("shaker", 3, 1, 1),
              ("kick", 10, 1, 0), ("snare", 3, .6, 0), ("hat", 3, .72, 0), ("shaker", 7, .095, -.3)]
    matrix += [(inst, 1, 0, 0) for inst in ("kick", "snare", "hat", "shaker")]
    controls = [dict(instrument=inst, note=int(inst == "snare"), time=min(index * .25, 4),
                     local_time=min(index * .25, 4), beat=min(index * .25, 4) * 1.3,
                     duration=1 / 32000 if index % 2 == 0 else 16, release=0 if index % 2 == 0 else 5,
                     velocity=velocity, pan=pan, round_robin=rr, role="ghost" if velocity == .075 else "drum",
                     articulation="connected" if index % 2 == 0 else "soft")
                for index, (inst, rr, velocity, pan) in enumerate(matrix)]
    return provenance, [prefix, controls]


def load_manifest():
    provenance, scores = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    if (manifest.get("schema_version"), manifest.get("sample_rate"), manifest.get("tolerances")) != (1, 32000, LIMITS):
        raise ValueError("Changed percussion fixture version/rate/tolerances")
    bodies, clips = manifest.get("bodies", []), manifest.get("clips", [])
    if len(bodies) != 12 or len(clips) != 2:
        raise ValueError("Unexpected percussion case count")
    for case, definition in zip(bodies, BODIES):
        if any(case.get(key) != value for key, value in definition.items()) or case.get("channels") != 1 or not 1 <= case.get("frames", 0) <= 22400:
            raise ValueError("Changed percussion preparation case")
    names = {"README.md", "manifest.json"}
    for clip, (name, frames, tail, events_file), events in zip(clips, CONFIGS, scores):
        if (clip.get("id"), clip.get("frames"), clip.get("channels"), clip.get("tail_silence_start_frame"), clip.get("event_count")) != (name, frames, 2, tail, len(events)):
            raise ValueError("Changed percussion clip controls")
        for kind, filename in (("events", events_file), ("fixture", name + ".flac")):
            names.add(filename)
            if clip.get(kind + "_file") != filename or HELPERS["digest"](FIXTURES / filename) != clip[kind + "_sha256"]:
                raise ValueError(f"Changed frozen percussion {kind}")
        if json.loads((FIXTURES / events_file).read_text()) != events:
            raise ValueError("Changed accepted or curated percussion events")
    if {path.name for path in FIXTURES.iterdir() if path.is_file()} != names:
        raise ValueError("Unexpected or missing percussion fixture file")
    return manifest, provenance, scores


def prepared(renderer, case):
    import numpy as np
    inst = case["instrument"]
    samples = renderer.ins.pitched(inst, case["note"], 1 if case["velocity"] < .72 else 2, case["round_robin"]).copy()
    if inst == "hat":
        samples = samples[:4160].copy()
    if inst in ("hat", "snare"):
        samples *= np.exp(-np.arange(len(samples)) / 32000 / (.052 if inst == "hat" else .085))[:, None]
    return samples[:, 0]


def render(renderer, events, frames):
    import numpy as np
    output = np.zeros((frames, 2), dtype=np.float32)
    for event in events:
        renderer.ins.add_note(output, event["instrument"], event["note"], event["time"], event["duration"],
                              event["velocity"], event["pan"], event["round_robin"], release_seconds=event["release"])
    return output


def verify(manifest, provenance, scores, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.iterdir()} != {case["file"] for case in BODIES} | {name + ".f32" for name, *_ in CONFIGS}:
            raise ValueError("Unexpected or missing native percussion candidate")
    if evidence is not None:
        evidence = HELPERS["output_path"](evidence)
    result = {"bodies": [], "clips": []}
    with HELPERS["reference"](provenance) as renderer:
        arrays = [("bodies", case, prepared(renderer, case)) for case in manifest["bodies"]]
        arrays += [("clips", clip, render(renderer, events, clip["frames"])) for clip, events in zip(manifest["clips"], scores)]
    for kind, case, expected in arrays:
        name = case["file"] if kind == "bodies" else case["id"] + ".f32"
        if expected.shape != ((case["frames"],) if kind == "bodies" else (case["frames"], 2)) or not np.isfinite(expected).all():
            raise ValueError(f"Changed percussion oracle dimensions: {name}")
        item = {"file": name, "frames": case["frames"], "channels": case["channels"]}
        if kind == "clips":
            frozen, rate = sf.read(FIXTURES / case["fixture_file"], dtype="float32", always_2d=True)
            if rate != 32000 or np.any(expected[case["tail_silence_start_frame"]:]):
                raise ValueError("Changed reference percussion rate/tail")
            HELPERS["compare"](expected, frozen, LIMITS, "frozen " + name)
            item["reference"] = VOICES["measures"](expected)
        if candidates is not None:
            path = candidates / name
            if path.stat().st_size != expected.size * 4:
                raise ValueError(f"Incorrect percussion candidate length: {name}")
            actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
            item.update(HELPERS["compare"](actual, expected, LIMITS, name), sha256=HELPERS["digest"](path))
            if kind == "clips":
                if np.any(actual[case["tail_silence_start_frame"]:]):
                    raise ValueError("Native percussion did not retire to exact silence")
                item["native"] = VOICES["measures"](actual)
                if evidence is not None:
                    evidence.mkdir(parents=True, exist_ok=True)
                    item["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        path = evidence / (case["id"] + "-" + label + ".wav")
                        sf.write(path, samples, 32000, subtype="FLOAT")
                        item["audition"].append({"file": path.name, "sha256": HELPERS["digest"](path)})
        result[kind].append(item)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    print("Verified 12 percussion bodies and two complete clips" + (" against every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true", help="Check hashes/controls without DSP dependencies")
    mode.add_argument("--compare", type=Path, help="Directory containing exactly 14 native Float32 candidates")
    parser.add_argument("--evidence", type=Path, help="Write aligned reference/native WAVs and metrics")
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, scores = load_manifest()
        if args.integrity:
            print("Frozen percussion integrity passed: 12 preparations, 36 accepted events, 20 curated controls")
        else:
            verify(manifest, provenance, scores, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
