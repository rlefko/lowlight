#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare native prepared notes with the unchanged accepted v9 functions."""
import argparse
from contextlib import contextmanager
import hashlib
import importlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FIXTURES = ROOT / "tests/fixtures/tonal-v9"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def output_path(path):
    path = path.resolve()
    if not path.is_relative_to(ROOT / ".build"):
        raise ValueError("Generated audio must stay under the ignored .build directory")
    return path


def load_manifest():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    provenance = json.loads((HERE / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if name.startswith("tools/reference/v9/") and digest(ROOT / name) != expected:
            raise ValueError(f"Changed frozen v9 source: {name}")
    if manifest.get("schema_version") != 1 or manifest.get("sample_rate") != 32000 or len(manifest.get("cases", [])) != 16:
        raise ValueError("Unexpected tonal fixture schema or case count")
    expected = {"manifest.json", "README.md"}
    identifiers = set()
    for case in manifest["cases"]:
        name = case["id"]
        if not name.isascii() or not name.isidentifier() or name in identifiers:
            raise ValueError("Invalid or repeated case identifier")
        identifiers.add(name)
        if case["window_file"] != name + ".flac" or digest(FIXTURES / case["window_file"]) != case["window_sha256"]:
            raise ValueError(f"Changed frozen tonal window: {name}")
        expected.add(case["window_file"])
    if {p.name for p in FIXTURES.iterdir() if p.is_file()} != expected:
        raise ValueError("Unexpected or missing tonal fixture file")
    return manifest, provenance


@contextmanager
def reference(provenance):
    if sys.version_info[:3] != (3, 12, 14):
        raise RuntimeError("Reference rendering requires Python 3.12.14")
    for package, version in provenance["dependency_versions"].items():
        if importlib.metadata.version(package) != version:
            raise RuntimeError(f"Reference dependency mismatch: {package}")
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tonal-v9-", dir=ROOT / ".build") as temporary:
        sandbox = Path(temporary) / "prototype"
        sandbox.mkdir()
        for source in (HERE / "v9").glob("*.py"):
            shutil.copyfile(source, sandbox / source.name)
        for name in ("assets", "sample_manifest.json", "electric_guitar_manifest.json"):
            (sandbox / name).symlink_to(ROOT / "Lowlight/SoundBank" / name)
        sys.path.insert(0, str(sandbox))
        try:
            yield importlib.import_module("render_room")
        finally:
            sys.path.remove(str(sandbox))


def prepared(renderer, case):
    if case["instrument"] == "guitar":
        samples = renderer.guitar(case["note"], case["round_robin"], case["warmth"])
    elif case["instrument"] == "piano":
        samples = renderer.piano(case["note"], case["warmth"])
    else:
        raise ValueError("Unsupported tonal fixture instrument")
    return samples.reshape(len(samples), -1)


def compare(actual, expected, limits, label):
    import numpy as np
    if actual.shape != expected.shape or not np.isfinite(actual).all():
        raise ValueError(f"Incorrect shape or nonfinite samples: {label}")
    error = actual.astype(np.float64) - expected
    maximum = float(np.max(np.abs(error)))
    rms = float(np.sqrt(np.mean(error * error)))
    if maximum > limits["maximum_absolute_error"] or rms > limits["rms_error"]:
        raise ValueError(f"Tonal comparison failed: {label}; maximum={maximum}, rms={rms}")
    return {"maximum_absolute_error": maximum, "rms_error": rms}


def verify(manifest, provenance, candidates=None, evidence=None):
    import numpy as np
    import soundfile as sf
    results = []
    if candidates is not None:
        candidates = output_path(candidates)
        expected = {case["id"] + ".f32" for case in manifest["cases"]}
        if {path.name for path in candidates.glob("*.f32")} != expected:
            raise ValueError("Unexpected or missing native candidate")
    if evidence is not None:
        evidence = output_path(evidence)
        evidence.mkdir(parents=True, exist_ok=True)
    with reference(provenance) as renderer:
        for case in manifest["cases"]:
            expected = prepared(renderer, case)
            if expected.shape != (case["frames"], case["channels"]) or not np.isfinite(expected).all():
                raise ValueError(f"Changed oracle output shape: {case['id']}")
            frozen, rate = sf.read(FIXTURES / case["window_file"], dtype="float32", always_2d=True)
            windows = np.concatenate([expected[w["start_frame"]:w["start_frame"] + w["frames"]] for w in case["windows"]])
            if rate != manifest["sample_rate"]:
                raise ValueError("Incorrect frozen sample rate")
            compare(windows, frozen, manifest["tolerances"], "oracle " + case["id"])
            peak = float(np.max(np.abs(expected)))
            rms = float(np.sqrt(np.mean(expected.astype(np.float64) ** 2)))
            if abs(peak - case["peak"]) > 1e-5 or abs(rms - case["rms"]) > 1e-6:
                raise ValueError(f"Changed oracle full-array metrics: {case['id']}")
            result = {"id": case["id"], "frames": len(expected), "channels": case["channels"]}
            if candidates is not None:
                path = candidates / (case["id"] + ".f32")
                if path.stat().st_size != expected.size * 4:
                    raise ValueError(f"Incorrect native candidate length: {case['id']}")
                actual = np.fromfile(path, dtype="<f4").reshape(expected.shape)
                result.update(compare(actual, expected, manifest["tolerances"], case["id"]))
                if evidence is not None and case["id"] in ("guitar_root", "piano_root"):
                    result["audition"] = []
                    for label, samples in (("reference", expected), ("native", actual)):
                        clip = samples[:32000]
                        path = evidence / f"{case['id']}-{label}.wav"
                        sf.write(path, clip, 32000, subtype="FLOAT")
                        result["audition"].append({"file": path.name, "sha256": digest(path),
                                                   "rms_dbfs": float(20 * np.log10(np.sqrt(np.mean(clip.astype(np.float64) ** 2))))})
            results.append(result)
    if evidence is not None:
        (evidence / "comparison.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print(f"Verified {len(results)} frozen tonal cases" + (" and every native sample" if candidates else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--integrity", action="store_true", help="Check fixture/source hashes without loading DSP dependencies")
    mode.add_argument("--compare", type=Path, help="Directory of full interleaved little-endian Float32 native candidates")
    parser.add_argument("--evidence", type=Path, help="Write two labeled dry-note A/B pairs and comparison metrics")
    args = parser.parse_args()
    if args.evidence and not args.compare:
        parser.error("--evidence requires --compare")
    try:
        manifest, provenance = load_manifest()
        if args.integrity:
            print(f"Frozen tonal integrity passed: {len(manifest['cases'])} cases")
        else:
            verify(manifest, provenance, args.compare, args.evidence)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(str(error))
