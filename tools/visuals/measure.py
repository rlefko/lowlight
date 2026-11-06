#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Compare foreground playback with and without horizon motion on one fresh simulator."""

import argparse
from contextlib import contextmanager
import json
import math
from pathlib import Path
import plistlib
import subprocess
import sys

from visibility import check_cost_gate

ROOT = Path(__file__).resolve().parents[2]
TEST = "LowlightUITests/HorizonTests/testVisualPlaybackCost"
MODES = ("animated", "static", "static", "animated", "animated", "static")


def run(*command, log=None):
    if log is None:
        return subprocess.check_output(command, cwd=ROOT, text=True).strip()
    with log.open("w") as output:
        subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)


def check_metrics(results):
    if len(results) != 1 or results[0]["testIdentifier"] != "HorizonTests/testVisualPlaybackCost()":
        raise ValueError("Expected the visual playback performance test")
    trial, = results[0]["testRuns"]
    metrics = {metric["identifier"]: metric for metric in trial["metrics"]}
    for suffix, unit in (
        ("Clock.time.monotonic", "s"),
        ("CPU-com.rlefko.lowlight.time", "s"),
        ("Memory-com.rlefko.lowlight.physical_peak", "kB"),
        ("Memory-com.rlefko.lowlight.physical_absolute", "kB"),
    ):
        metric = metrics["com.apple.dt.XCTMetric_" + suffix]
        value, = metric["measurements"]
        if metric["unitOfMeasurement"] != unit or not math.isfinite(value) or value <= 0:
            raise ValueError(f"Invalid measurement for {suffix}")
        if suffix == "Clock.time.monotonic" and not 28 <= value <= 32:
            raise ValueError(f"Unexpected wall-clock interval {value}")


@contextmanager
def capture_trace(device, trace):
    predicate = 'subsystem == "com.rlefko.lowlight" AND category IN {"Horizon", "HorizonEvidence"}'
    with trace.open("w") as events:
        stream = subprocess.Popen(
            ["xcrun", "simctl", "spawn", device, "log", "stream", "--style", "ndjson",
             "--level", "info", "--predicate", predicate], stdout=events)
        try:
            yield
        finally:
            stream.terminate()
            stream.wait()


def measure(output, device, visibility):
    destination = "platform=iOS Simulator,id=" + device
    derived = output / "DerivedData"
    run("xcrun", "simctl", "bootstatus", device, "-b", log=output / "boot.log")
    run("xcodebuild", "build-for-testing", "-project", "Lowlight.xcodeproj",
        "-scheme", "LowlightVisualProbe", "-configuration", "Release",
        "-destination", destination, "-derivedDataPath", derived, "ARCHS=arm64",
        "CODE_SIGNING_ALLOWED=NO", log=output / "build.log")
    products = derived / "Build/Products"
    test_run, = products.glob("LowlightVisualProbe*.xctestrun")
    settings = plistlib.loads(test_run.read_bytes())
    trial = test_run.with_name("HorizonTrial.xctestrun")
    if visibility:
        run("xcrun", "simctl", "ui", device, "appearance", "dark")
        settings["LowlightUITests"]["EnvironmentVariables"]["LOWLIGHT_VISUAL_EVIDENCE"] = "1"
        trial.write_bytes(plistlib.dumps(settings))
        trace = output / "visibility.ndjson"
        with capture_trace(device, trace):
            run("xcodebuild", "test-without-building", "-xctestrun", trial,
                "-destination", destination, "-parallel-testing-enabled", "NO",
                "-only-testing:LowlightUITests/HorizonTests/testHorizonVisibility",
                "-only-testing:LowlightUITests/HorizonTests/testPlayingAccessibility",
                "-resultBundlePath", output / "visibility.xcresult", log=output / "visibility.log")
        run(sys.executable, ROOT / "tools/visuals/visibility.py", trace, log=output / "visibility.json")
        return

    for index, mode in enumerate(MODES, start=1):
        print(f"Trial {index}: {mode}", flush=True)
        if index > 1:
            # Each launch starts with the production seed and default controls.
            run("xcrun", "simctl", "uninstall", device, "com.rlefko.lowlight")
        settings["LowlightUITests"]["EnvironmentVariables"]["LOWLIGHT_VISUAL_TRIAL"] = mode
        trial.write_bytes(plistlib.dumps(settings))
        name = f"{index}-{mode}"
        result = output / (name + ".xcresult")
        trace = output / (name + ".ndjson")
        with capture_trace(device, trace):
            run("xcodebuild", "test-without-building", "-xctestrun", trial,
                "-destination", destination, "-parallel-testing-enabled", "NO",
                "-only-testing:" + TEST, "-resultBundlePath", result, log=output / (name + ".log"))
        gate = check_cost_gate(trace, mode)
        (output / ("gate-" + name + ".json")).write_text(json.dumps(gate, indent=2) + "\n")
        metrics = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "metrics",
                                 "--path", result))
        # A skipped opt-in test can still produce a successful xcodebuild exit.
        check_metrics(metrics)
        (output / (name + ".json")).write_text(json.dumps(metrics, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New directory for results, logs, and metrics")
    parser.add_argument("--visibility", action="store_true",
                        help="Trace actual redraws in each visibility and playback state")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    run("scripts/toolchain")
    pins = dict(line.split("=", 1) for line in (ROOT / "config/toolchain.env").read_text().splitlines())
    device = run("xcrun", "simctl", "create", "Lowlight visual measurements",
                 pins["SIMULATOR_DEVICE_TYPE"], pins["SIMULATOR_RUNTIME"])
    try:
        measure(output, device, args.visibility)
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
        run("xcrun", "simctl", "delete", device)


if __name__ == "__main__":
    main()
