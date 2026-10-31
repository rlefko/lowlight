#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Verify immutable v9 inputs or rerender short developer-only parity fixtures."""
import argparse
import copy
import hashlib
import importlib
import importlib.metadata
import json
import os
from pathlib import Path
import resource
import shutil
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FIXTURES = ROOT / "tests/fixtures/v9"
PROVENANCE = HERE / "provenance.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    # Replace the directory entry, never write through an existing link.
    with tempfile.TemporaryDirectory(prefix="report-", dir=path.parent) as temporary:
        candidate = Path(temporary) / path.name
        candidate.write_text(json.dumps(value, indent=2) + "\n")
        candidate.replace(path)


def integrity():
    evidence = json.loads(PROVENANCE.read_text())
    for relative, expected in evidence["files"].items():
        path = ROOT / relative
        if digest(path) != expected:
            raise ValueError(f"Frozen reference checksum mismatch: {relative}")
    actual = {str(p.relative_to(ROOT)) for p in FIXTURES.rglob("*") if p.is_file()}
    expected = {p for p in evidence["files"] if p.startswith("tests/fixtures/v9/")}
    if actual != expected:
        raise ValueError("Unexpected or missing developer fixture")
    actual_sources = {str(p.relative_to(ROOT)) for p in (HERE / "v9").glob("*.py")}
    expected_sources = {p for p in evidence["files"] if p.startswith("tools/reference/v9/")}
    if actual_sources != expected_sources:
        raise ValueError("Unexpected or missing frozen source module")
    # This checks the musical fixture without loading a bank or invoking a PRNG.
    events = json.loads((FIXTURES / "events.json").read_text())
    if len(events) != 621 or {event["instrument"] for event in events} != {
        "guitar", "piano", "bass", "kick", "snare", "hat"
    }:
        raise ValueError("Incomplete frozen v9 performance")
    print(f"Frozen reference integrity passed: {len(evidence['files'])} files")
    return evidence


def render(output):
    if sys.version_info[:3] != (3, 12, 14):
        raise RuntimeError("Reference rendering requires Python 3.12.14")
    for package, expected in json.loads(PROVENANCE.read_text())["dependency_versions"].items():
        if importlib.metadata.version(package) != expected:
            raise RuntimeError(f"Reference dependency mismatch: {package}; rerun tools/reference/setup")
    import numpy as np
    import soundfile as sf

    output = output.resolve()
    if not output.is_relative_to(ROOT / ".build"):
        raise ValueError("Candidate output must stay under the ignored .build directory")
    output.mkdir(parents=True, exist_ok=True)
    song = json.loads((FIXTURES / "song.json").read_text())
    events = json.loads((FIXTURES / "events.json").read_text())
    began = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="v9-", dir=output) as temporary:
        sandbox = Path(temporary) / "prototype"
        sandbox.mkdir()
        for path in (HERE / "v9").glob("*.py"):
            shutil.copyfile(path, sandbox / path.name)
        bank = ROOT / "Lowlight/SoundBank"
        for name in ("assets", "sample_manifest.json", "electric_guitar_manifest.json"):
            (sandbox / name).symlink_to(bank / name)
        sys.path.insert(0, str(sandbox))
        renderer = importlib.import_module("session_render")
        # Bypass musical event generation; DSP receives the reviewed score/takes.
        renderer.make_events = lambda _: copy.deepcopy(events)
        samples, stats = renderer.render_song(song)
        full = Path(temporary) / "song.wav"
        sf.write(full, samples, 32000, subtype="PCM_24")
        del samples
        master = importlib.import_module("master_stream").protect(full)
        with sf.SoundFile(full) as source:
            for clip in json.loads(PROVENANCE.read_text())["clips"]:
                source.seek(clip["start_frame"])
                pcm = source.read(clip["frames"], dtype="float32", always_2d=True)
                if len(pcm) != clip["frames"] or not np.isfinite(pcm).all():
                    raise ValueError("Reference render produced an incomplete/nonfinite clip")
                candidate = Path(temporary) / "clip.flac"
                sf.write(candidate, pcm, 32000, subtype="PCM_24")
                candidate.replace(output / clip["file"])
    peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    report = {
        "render_seconds": time.monotonic() - began,
        "peak_rss_mib": peak_rss / (1024 * 1024 if sys.platform == "darwin" else 1024),
        "song_fixed_gain_db": stats["fixed_gain_dB"],
        "source_body_lufs": stats["source_body_LUFS"],
        "master": master,
        "libsndfile_version": sf.__libsndfile_version__,
    }
    write_json(output / "render-report.json", report)
    return report


def compare(output, evidence):
    import numpy as np
    import pyloudnorm as pyln
    import soundfile as sf

    results = []
    limits = evidence["reproduction_tolerances"]
    for clip in evidence["clips"]:
        expected, rate = sf.read(FIXTURES / clip["file"], dtype="float32", always_2d=True)
        actual, actual_rate = sf.read(output / clip["file"], dtype="float32", always_2d=True)
        if rate != 32000 or actual_rate != rate or actual.shape != expected.shape:
            raise ValueError(f"Incorrect rate/frame/channel count: {clip['file']}")
        if not np.isfinite(actual).all():
            raise ValueError(f"Nonfinite output: {clip['file']}")
        error = actual.astype(np.float64) - expected
        maximum = float(np.max(np.abs(error)))
        rms = float(np.sqrt(np.mean(error * error)))
        meter = pyln.Meter(rate)
        lufs_delta = abs(float(meter.integrated_loudness(actual)) - float(meter.integrated_loudness(expected)))
        passed = maximum <= limits["maximum_absolute_error"] and rms <= limits["rms_error"] and lufs_delta <= limits["loudness_lu"]
        results.append({"file": clip["file"], "maximum_absolute_error": maximum,
                        "rms_error": rms, "loudness_delta_lu": lufs_delta, "passed": passed})
    write_json(output / "comparison.json", results)
    print(json.dumps(results, indent=2))
    if not all(result["passed"] for result in results):
        raise ValueError("Frozen v9 reproduction differs; inspect candidates without replacing the oracle")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integrity", action="store_true", help="Check frozen input and fixture hashes")
    parser.add_argument("--render", action="store_true", help="Render and compare candidates without modifying fixtures")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/reference")
    args = parser.parse_args()
    os.environ.setdefault("NUMBA_NUM_THREADS", "1")
    evidence = integrity()
    if args.render:
        print(json.dumps(render(args.output), indent=2))
        compare(args.output, evidence)
