#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare the native tonal voice mixer with unchanged v9 voice/place functions."""
import argparse
import json
from pathlib import Path
import runpy
import sys

HERE = Path(__file__).resolve().parent
HELPERS = runpy.run_path(str(HERE / "verify-tonal.py"))
ROOT = HELPERS["ROOT"]
FIXTURES = ROOT / "tests/fixtures/voices-v9"
LIMITS = {"maximum_absolute_error": 1e-5, "rms_error": 1e-6}


def source_inputs():
    provenance = json.loads((HERE / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if HELPERS["digest"](ROOT / name) != expected:
            raise ValueError(f"Changed frozen v9 input: {name}")
    events = json.loads((ROOT / "tests/fixtures/v9/events.json").read_text())
    events = [event for event in events if event["instrument"] in ("guitar", "piano") and event["time"] < 8]
    warmth = json.loads((ROOT / "tests/fixtures/v9/song.json").read_text())["parameters"]["warmth"]
    if len(events) != 21 or warmth != .78:
        raise ValueError("Unexpected accepted score prefix")
    return provenance, events, warmth


def load_manifest():
    provenance, accepted, warmth = source_inputs()
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    if (manifest.get("schema_version"), manifest.get("sample_rate"), manifest.get("frames"), manifest.get("channels")) != (1, 32000, 384000, 2):
        raise ValueError("Unexpected voice fixture dimensions/version")
    if manifest.get("tolerances") != LIMITS or manifest.get("event_count") != 21 or manifest.get("warmth") != warmth:
        raise ValueError("Changed voice fixture controls or tolerances")
    for kind, name in (("events", "events.json"), ("fixture", "voice-prefix.flac")):
        if manifest[kind + "_file"] != name or HELPERS["digest"](FIXTURES / name) != manifest[kind + "_sha256"]:
            raise ValueError(f"Changed frozen voice {kind}")
    if json.loads((FIXTURES / "events.json").read_text()) != accepted:
        raise ValueError("Voice events differ from the accepted score prefix")
    if {path.name for path in FIXTURES.iterdir() if path.is_file()} != {"README.md", "manifest.json", "events.json", "voice-prefix.flac"}:
        raise ValueError("Unexpected or missing voice fixture file")
    return manifest, provenance, accepted


def render(renderer, events, warmth, absolute_endpoints=False):
    import numpy as np
    output = np.zeros((384000, 2), dtype=np.float32)
    for original in events:
        event = dict(original)
        if absolute_endpoints:
            start = round(event["time"] * 32000)
            gate = round((event["time"] + event["duration"]) * 32000)
            end = round((event["time"] + event["duration"] + event["release"]) * 32000)
            event["duration"], event["release"] = (gate - start) / 32000, (end - gate) / 32000
        renderer.place(output, renderer.voice(event, {"warmth": warmth}), event["time"])
    return output


def measures(samples):
    import numpy as np
    import pyloudnorm as pyln
    from scipy import signal
    return {"peak": float(np.max(np.abs(samples))),
            "rms": float(np.sqrt(np.mean(samples.astype(np.float64) ** 2))),
            "integrated_lufs": float(pyln.Meter(32000).integrated_loudness(samples)),
            "four_times_peak_dbtp": float(20 * np.log10(np.max(np.abs(signal.resample_poly(samples, 4, 1, axis=0)))))}


def verify(manifest, provenance, events, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    with HELPERS["reference"](provenance) as renderer:
        expected = render(renderer, events, manifest["warmth"])
    frozen, rate = sf.read(FIXTURES / "voice-prefix.flac", dtype="float32", always_2d=True)
    if rate != 32000:
        raise ValueError("Incorrect voice fixture sample rate")
    HELPERS["compare"](expected, frozen, LIMITS, "frozen voice reproduction")
    if np.any(expected[manifest["tail_silence_start_frame"]:]):
        raise ValueError("Unexpected reference tail beyond the frozen endpoint")
    result = {"frames": 384000, "channels": 2, "events": 21, "reference": measures(expected)}
    if candidates is not None:
        candidates = HELPERS["output_path"](candidates)
        if {path.name for path in candidates.glob("*.f32")} != {"voice-prefix.f32"}:
            raise ValueError("Unexpected or missing native voice candidate")
        path = candidates / "voice-prefix.f32"
        if path.stat().st_size != expected.size * 4:
            raise ValueError("Incorrect native voice candidate length")
        actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
        result.update(HELPERS["compare"](actual, expected, LIMITS, "native voice prefix"))
        if np.any(actual[manifest["tail_silence_start_frame"] + 1:]):
            raise ValueError("Native voices did not retire to exact silence")
        result["native"] = measures(actual)
        if evidence is not None:
            evidence = HELPERS["output_path"](evidence)
            evidence.mkdir(parents=True, exist_ok=True)
            result["audition"] = []
            for label, samples in (("reference", expected), ("native", actual)):
                path = evidence / ("voice-prefix-" + label + ".wav")
                sf.write(path, samples, 32000, subtype="FLOAT")
                result["audition"].append({"file": path.name, "sha256": HELPERS["digest"](path)})
            (evidence / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    print("Verified the frozen 12-second voice prefix" + (" and every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true", help="Check source/event/audio hashes without DSP dependencies")
    mode.add_argument("--compare", type=Path, help="Directory containing native voice-prefix.f32")
    parser.add_argument("--evidence", type=Path, help="Write labeled full-length dry A/B clips and measurements")
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance, events = load_manifest()
        if args.integrity:
            print("Frozen voice integrity passed: 21 accepted tonal events")
        else:
            verify(manifest, provenance, events, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
