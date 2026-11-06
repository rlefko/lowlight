#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare or verify a gapless AAC reference from Lowlight's continuous Focus performance."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / ".build"
REFERENCE = ROOT / ".tools/reference"
RATE = 32_000
CHANNELS = 2
MAX_LU_DIFFERENCE = 0.5
CONTRACT = {"schema_version": 1, "seed": 91_031, "preset": "Focus",
            "sample_rate": RATE, "channels": CHANNELS, "codec": "aac"}
FIXTURE = "reference.m4a"
MANIFEST = "manifest.json"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_seconds(value):
    if type(value) is not int or not 1 <= value <= 3600:
        raise ValueError("duration_seconds must be an integer from 1 to 3600")
    return value * RATE


def inspect_levels(samples):
    import numpy as np
    import pyloudnorm
    peak = float(np.max(np.abs(samples)))
    if not math.isfinite(peak) or peak <= 0:
        raise ValueError("audio has zero or nonfinite sample peak")
    loudness = float(pyloudnorm.Meter(RATE).integrated_loudness(samples))
    if not math.isfinite(loudness):
        raise ValueError("audio does not have measurable integrated loudness")
    return peak, loudness


def decoded_evidence(audio, scratch, frames):
    import soundfile
    info = subprocess.check_output(["/usr/bin/afinfo", str(audio)], text=True)
    expected = r"^Data format:\s+2 ch,\s+32000 Hz, aac\s"
    if ("File type ID:   m4af" not in info or "Num Tracks:     1\n" not in info
            or not re.search(expected, info, re.MULTILINE)):
        raise ValueError("reference must be single-track stereo 32 kHz AAC in an M4A container")
    wave = scratch / "decoded.wav"
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32", str(audio), str(wave)],
                   check=True)
    with soundfile.SoundFile(wave) as stream:
        if (stream.samplerate, stream.channels, stream.frames) != (RATE, CHANNELS, frames):
            raise ValueError("gapless AAC decode differs from the source format or frame count")
        decoded = stream.read(dtype="float32")
    peak, loudness = inspect_levels(decoded)
    return {"decoded_frames": len(decoded), "decoded_lufs": loudness, "decoded_sample_peak": peak}


def source_samples(raw, frames):
    import numpy as np
    if raw.stat().st_size != frames * CHANNELS * 4:
        raise ValueError("incomplete interleaved Float32 export")
    return np.memmap(raw, dtype="<f4", mode="r", shape=(frames, CHANNELS))


def validate_manifest(record):
    if not isinstance(record, dict):
        raise ValueError("fixture manifest must be a JSON object")
    for key, expected in CONTRACT.items():
        if type(record.get(key)) is not type(expected) or record[key] != expected:
            raise ValueError(f"invalid fixture {key}")
    frames = check_seconds(record["duration_seconds"])
    if any(type(record[key]) is not int or record[key] != frames
           for key in ("frames", "decoded_frames")):
        raise ValueError("fixture duration and frames disagree")
    for key in ("pcm_sha256", "aac_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", record[key]):
            raise ValueError(f"invalid fixture {key}")
    for key in ("source_sample_peak", "decoded_sample_peak", "source_lufs", "decoded_lufs"):
        if type(record[key]) not in (float, int) or not math.isfinite(record[key]):
            raise ValueError(f"invalid fixture {key}")
    if not (0 < record["source_sample_peak"] <= 1 and record["decoded_sample_peak"] > 0):
        raise ValueError("invalid fixture sample peak")
    if abs(record["source_lufs"] - record["decoded_lufs"]) > MAX_LU_DIFFERENCE:
        raise ValueError(f"decoded loudness differs from the source by more than {MAX_LU_DIFFERENCE} LU")


def new_destination(destination):
    if not destination.is_relative_to(BUILD) or destination == BUILD:
        raise ValueError("prepare destination must be a new directory beneath this checkout's .build")
    if destination.exists():
        raise ValueError(f"destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)


def prepare(destination, seconds):
    import soundfile
    frames = check_seconds(seconds)
    new_destination(destination)
    subprocess.run([ROOT / "scripts/toolchain"], check=True)
    subprocess.run([ROOT / "scripts/verify-bank"], check=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        scratch = Path(temporary)
        result = scratch / "fixture"
        result.mkdir()
        raw = result / "source.f32"
        env = dict(os.environ, TOOLCHAINS="com.apple.dt.toolchain.Xcode",
                   LOWLIGHT_COMPARISON_OUTPUT=str(result), LOWLIGHT_COMPARISON_SECONDS=str(seconds))
        subprocess.run(["xcrun", "swift", "test", "--package-path", str(ROOT / "Packages/LowlightAudio"),
                        "--scratch-path", str(BUILD / "PlaybackComparisonExport"), "-c", "release",
                        "--filter", "PlaybackComparisonFixtureTests/exportFocus"], env=env, check=True)
        samples = source_samples(raw, frames)
        peak, loudness = inspect_levels(samples)
        wave = scratch / "source.wav"
        soundfile.write(wave, samples, RATE, subtype="FLOAT")
        audio = result / FIXTURE
        subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "128000",
                        str(wave), str(audio)], check=True)
        record = {**CONTRACT, "duration_seconds": seconds, "frames": frames,
                  "pcm_sha256": digest(raw), "aac_sha256": digest(audio), "source_sample_peak": peak,
                  "source_lufs": loudness, **decoded_evidence(audio, scratch, frames)}
        validate_manifest(record)
        (result / MANIFEST).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        result.rename(destination)
    return record


def verify(directory):
    record = json.loads((directory / MANIFEST).read_text())
    validate_manifest(record)
    audio = directory / FIXTURE
    if digest(audio) != record["aac_sha256"]:
        raise ValueError("AAC SHA-256 differs from manifest")
    source = directory / "source.f32"
    if source.exists():
        samples = source_samples(source, record["frames"])
        if hashlib.sha256(samples).hexdigest() != record["pcm_sha256"]:
            raise ValueError("source PCM SHA-256 differs from manifest")
        peak, loudness = inspect_levels(samples)
        if (peak, loudness) != (record["source_sample_peak"], record["source_lufs"]):
            raise ValueError("source PCM levels differ from manifest")
    BUILD.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=BUILD) as scratch:
        decoded = decoded_evidence(audio, Path(scratch), record["frames"])
    # Core Audio can differ by a few Float32 rounding bits on repeat decodes of the
    # very same authenticated payload. Require exact length and remeasure both levels.
    if (abs(decoded["decoded_lufs"] - record["decoded_lufs"]) > 0.001
            or abs(decoded["decoded_sample_peak"] - record["decoded_sample_peak"]) > 0.0001
            or abs(decoded["decoded_lufs"] - record["source_lufs"]) > MAX_LU_DIFFERENCE):
        raise ValueError("decoded levels differ from the measured manifest or source")
    return record


def smoke(destination):
    new_destination(destination)
    # M4A embeds creation dates. Check each container against its own digest and
    # compare the stable native PCM between two independent sessions/encodes.
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        result = Path(temporary) / "repeat"
        first = prepare(result / "first", 12)
        second = prepare(result / "second", 12)
        verify(result / "first")
        verify(result / "second")
        if first["pcm_sha256"] != second["pcm_sha256"]:
            raise ValueError("fresh Focus sessions rendered different source PCM")
        if abs(first["decoded_lufs"] - second["decoded_lufs"]) > 0.001:
            raise ValueError("fresh AAC encodes differ in integrated loudness")
        result.rename(destination)
    return first


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("prepare", help="generate local PCM, AAC and a measured manifest")
    export.add_argument("directory", type=Path)
    export.add_argument("--seconds", type=int, default=2100)
    check = commands.add_parser("verify", help="recheck the AAC, manifest, and any retained source PCM")
    check.add_argument("directory", type=Path)
    repeat = commands.add_parser("smoke", help="repeat and verify two fresh 12-second exports")
    repeat.add_argument("directory", type=Path)
    args = parser.parse_args()
    # Both commands use the same pinned BS.1770 meter used for the audio baseline.
    if Path(sys.prefix).resolve() != REFERENCE.resolve():
        python = REFERENCE / "bin/python"
        if not python.is_file():
            parser.error("install the pinned meter with tools/reference/setup first")
        os.execv(python, [str(python), "-B", __file__, *sys.argv[1:]])
    directory = args.directory.resolve()
    try:
        if args.command == "prepare":
            record = prepare(directory, args.seconds)
        elif args.command == "smoke":
            record = smoke(directory)
        else:
            record = verify(directory)
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"fixture: {error}\n")
    print(json.dumps(record, sort_keys=True))


if __name__ == "__main__":
    main()
