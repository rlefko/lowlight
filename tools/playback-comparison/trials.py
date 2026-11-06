#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare playback comparisons, rehearse on a simulator, or review independent device trials."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from uuid import UUID

from trial_records import BLOCKS, BUNDLE, digest, report, require, template


ROOT = Path(__file__).resolve().parents[2]
SCHEME = "Lowlight Playback Comparison"
SUPPORT = Path("Library/Application Support/PlaybackComparison")
FIXTURE = ("reference.m4a", "manifest.json")
GOOD = ("testGeneratorPlayback", "testAACPlayback", "testIdle", "testInvalidMode")


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def fixture_tool(action, folder, *args):
    run(sys.executable, "-B", ROOT / "tools/playback-comparison/fixture.py", action, folder, *args)


def sim_support(simulator):
    UUID(simulator)  # Never select an arbitrary booted device.
    container = output("xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data")
    require(Path(container).is_absolute() and Path(container).is_dir(), "missing profile container")
    return Path(container) / SUPPORT


def physical_copy(direction, device, name, local):
    require(re.fullmatch(r"[0-9A-Fa-f-]{24,40}", device), "provide an explicit device identifier")
    paths = (local, SUPPORT / name) if direction == "to" else (SUPPORT / name, local)
    run("xcrun", "devicectl", "device", "copy", direction, "--device", device,
        "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
        "--source", paths[0], "--destination", paths[1])


def put_sim(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as staging:
        pending = Path(staging.name)
    try:
        shutil.copyfile(source, pending)
        os.replace(pending, destination)
    finally:
        pending.unlink(missing_ok=True)


def stage(folder, simulator, device):
    fixture_tool("verify", folder)
    if simulator:
        support = sim_support(simulator)
        for name in FIXTURE:  # Publish the manifest last; runtime also checks the AAC digest.
            put_sim(folder / name, support / name)
            require(digest(support / name) == digest(folder / name), f"staged {name} differs")
    else:
        with tempfile.TemporaryDirectory() as tmp:
            for name in FIXTURE:
                physical_copy("to", device, name, folder / name)
                copy = Path(tmp) / name
                physical_copy("from", device, name, copy)
                require(digest(copy) == digest(folder / name), f"device readback of {name} differs")


def collect(folder, device, block, mode):
    """Collect both on-demand snapshots after reconnecting, before the next app launch."""
    folder.mkdir(parents=True, exist_ok=True)
    stem = f"{block}-{mode}"
    with tempfile.TemporaryDirectory(dir=folder) as tmp:
        files = []
        for source, when in (("start.json", "start"), ("snapshot.json", "end")):
            destination = folder / f"{stem}-{when}.json"
            require(not destination.exists(), f"{destination} already exists")
            copy = Path(tmp) / source
            physical_copy("from", device, source, copy)
            sample = json.loads(copy.read_text())
            require(sample["bundleID"] == BUNDLE and sample["mode"] == mode, "wrong profile snapshot")
            files.append((copy, destination, UUID(sample["trialID"])))
        require(files[0][2] == files[1][2], "snapshots belong to different trials")
        # Link the complete pair without overwriting a concurrent collection.
        os.link(files[0][0], files[0][1])
        try:
            os.link(files[1][0], files[1][1])
        except OSError:
            files[0][1].unlink()
            raise
        print(f"{stem} trial_id {files[0][2]}")


def check_tests(tree, summary, names):
    expected = sorted("ComparisonTests/" + name + "()" for name in names)
    observed = []
    pending = list(tree["testNodes"])
    while pending:
        node = pending.pop()
        pending.extend(node.get("children", []))
        if node["nodeType"] == "Test Case":
            require(node["result"] == "Passed", f"test did not pass: {node.get('nodeIdentifier')}")
            observed.append(node["nodeIdentifier"])
    require(sorted(observed) == expected and summary["result"] == "Passed"
            and summary["passedTests"] == summary["totalTestCount"] == len(names)
            and summary["skippedTests"] == summary["failedTests"] == summary["expectedFailures"] == 0,
            f"unexpected test execution; expected {expected}, got {observed}")


def check_installed_fixture(support, expected):
    for name in FIXTURE:
        path = support / name
        actual = digest(path) if path.exists() else None
        require(actual == expected.get(name), f"installed profile has unexpected {name}")


def rehearse(folder, artifacts):
    fixture_tool("verify", folder)
    manifest = json.loads((folder / "manifest.json").read_text())
    require(manifest["duration_seconds"] >= 30, "rehearsal needs at least 30 seconds of audio")
    artifacts.mkdir(parents=True, exist_ok=False)
    run(ROOT / "scripts/toolchain")
    pins = dict(line.split("=", 1) for line in (ROOT / "config/toolchain.env").read_text().splitlines())
    simulator = output("xcrun", "simctl", "create", "Lowlight playback comparison",
                       pins["SIMULATOR_DEVICE_TYPE"], pins["SIMULATOR_RUNTIME"])
    try:
        run("xcrun", "simctl", "bootstatus", simulator, "-b")
        destination = "platform=iOS Simulator,id=" + simulator
        derived = artifacts / "DerivedData"
        run("xcodebuild", "build-for-testing", "-project", "Lowlight.xcodeproj", "-scheme", SCHEME,
            "-configuration", "PlaybackComparison", "-derivedDataPath", derived, "-destination",
            destination, "ARCHS=arm64", "CODE_SIGNING_ALLOWED=NO")
        products = derived / "Build/Products"
        spec, = products.glob("*.xctestrun")
        settings = plistlib.loads(spec.read_bytes())
        settings["LowlightUITests"]["EnvironmentVariables"]["LOWLIGHT_COMPARISON_REHEARSAL"] = "1"
        enabled = products / "Rehearsal.xctestrun"
        enabled.write_bytes(plistlib.dumps(settings))
        app = products / "PlaybackComparison-iphonesimulator/Lowlight.app"
        require(plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"] == BUNDLE,
                "refusing to install a shipping app")
        receipt = {"kind": "simulator_rehearsal", "simulator": simulator,
                   "fixture_sha256": manifest["aac_sha256"], "app_sha256": digest(app / "Lowlight"),
                   "groups": {}}
        # The missing case runs before staging; corruption is confined to this disposable container.
        for group, names in (("missing", ("testUnavailableFixture",)), ("playback", GOOD),
                             ("corrupt", ("testCorruptFixture",))):
            expected = {}
            if group != "missing":
                support = sim_support(simulator)
            if group == "playback":
                for name in FIXTURE:
                    put_sim(folder / name, support / name)
                    expected[name] = digest(folder / name)
            elif group == "corrupt":
                with (support / "reference.m4a").open("r+b") as stream:
                    first = stream.read(1)
                    stream.seek(0)
                    stream.write(bytes([first[0] ^ 1]))
                expected = {name: digest(support / name) for name in FIXTURE}
                require(expected["reference.m4a"] != manifest["aac_sha256"]
                        and expected["manifest.json"] == digest(folder / "manifest.json"),
                        "corruption did not preserve the original manifest")
            result = artifacts / (group + ".xcresult")
            try:
                run("xcodebuild", "test-without-building", "-xctestrun", enabled, "-destination", destination,
                    "-parallel-testing-enabled", "NO", "-resultBundlePath", result,
                    *("-only-testing:LowlightUITests/ComparisonTests/" + name for name in names))
            finally:
                # XCTest can move the installed data container. Check its contents at the new path.
                check_installed_fixture(sim_support(simulator), expected)
            read = ("xcrun", "xcresulttool", "get", "test-results")
            check_tests(json.loads(output(*read, "tests", "--path", result)),
                        json.loads(output(*read, "summary", "--path", result)), names)
            receipt["groups"][group] = names
        (artifacts / "rehearsal.json").write_text(json.dumps(receipt, indent=2) + "\n")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=False)
        run("xcrun", "simctl", "delete", simulator)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    prepare = actions.add_parser("prepare", help="Generate a local native reference and encoded AAC")
    prepare.add_argument("fixture", type=Path)
    prepare.add_argument("--seconds", type=int, default=2100)
    put = actions.add_parser("stage", help="Stage a verified fixture in an installed profile app")
    put.add_argument("fixture", type=Path)
    target = put.add_mutually_exclusive_group(required=True)
    target.add_argument("--simulator", metavar="UUID")
    target.add_argument("--device", metavar="DEVELOPMENT_DEVICE_ID")
    rehearsal = actions.add_parser("rehearse", help="Run six exact tests on a new disposable simulator")
    rehearsal.add_argument("fixture", type=Path)
    rehearsal.add_argument("output", type=Path)
    capture = actions.add_parser("collect", help="Copy start and end snapshots after a physical run")
    capture.add_argument("directory", type=Path)
    capture.add_argument("--device", required=True)
    capture.add_argument("--block", type=int, choices=(1, 2, 3), required=True)
    capture.add_argument("--mode", choices=BLOCKS[0], required=True)
    example = actions.add_parser("template", help="Create a blank three-block operator record")
    example.add_argument("record", type=Path)
    example.add_argument("--role", choices=("older", "current"), required=True)
    analyze = actions.add_parser("report", help="Verify and compare measurements for one phone")
    analyze.add_argument("record", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            fixture_tool("prepare", args.fixture.resolve(), "--seconds", str(args.seconds))
        elif args.action == "stage":
            stage(args.fixture.resolve(), args.simulator, args.device)
        elif args.action == "rehearse":
            rehearse(args.fixture.resolve(), args.output.resolve())
        elif args.action == "collect":
            collect(args.directory.resolve(), args.device, args.block, args.mode)
        elif args.action == "template":
            with args.record.open("x") as stream:
                print(json.dumps(template(args.role), indent=2), file=stream)
        else:
            result = report(args.record)
            print(json.dumps(result, indent=2, allow_nan=False))
            return 0 if result["status"] == "comparable" else 2
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Comparison failed: {exc}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
