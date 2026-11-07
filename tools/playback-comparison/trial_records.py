# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Validate one phone's nine operator-recorded, unplugged Power Profiler windows."""
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import re
from statistics import median
from uuid import UUID

from fixture import CONTRACT, PERFORMANCE_RECIPE


BUNDLE = "com.rlefko.lowlight.profile"
BLOCKS = (("generator", "aac", "idle"), ("aac", "idle", "generator"), ("idle", "generator", "aac"))
UNITS = {"percentage_points_per_hour": 1, "fraction_per_hour": 100}
MATCHED = ("device", "model", "os_build", "build_commit", "app_sha256", "fixture_sha256",
           "route", "volume", "low_power")


def template(role):
    rows = []
    for block, order in enumerate(BLOCKS, 1):
        for mode in order:
            stem = f"{block}-{mode}"
            rows.append({
                "block": block, "mode": mode, "trial_id": "", **dict.fromkeys(MATCHED, ""),
                "screen": "", "charging": "", "thermal": "", "capture": "",
                "warmup_start": "", "measured_start": "", "measured_end": "",
                "metric": "", "unit": "", "rate": None, "uncertainty": None,
                "uncertainty_source": "", "trace": stem + ".aar", "trace_sha256": "",
                "start_snapshot": stem + "-start.json", "end_snapshot": stem + "-end.json",
            })
    return {"schema_version": 1, "device_role": role, "fixture_manifest": "manifest.json", "trials": rows}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, label):
    require(type(value) in (int, float) and math.isfinite(value), f"{label} must be a finite number")
    return value


def instant(value):
    require(isinstance(value, str) and "T" in value, "expected an ISO 8601 timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(result.utcoffset() is not None, "timestamp needs a UTC offset")
    return result


def nonempty(value, label):
    require(isinstance(value, str) and value.strip(), f"missing {label}")


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def artifact(root, name):
    nonempty(name, "artifact path")
    path = (root / name).resolve()
    require(not Path(name).is_absolute() and root in path.parents and path.is_file()
            and path.stat().st_size > 0, f"missing or invalid artifact: {name}")
    return path


def check_snapshots(row, root, warmup, end, fixture_frames):
    mode = row["mode"]
    active = "running" if mode == "idle" else "playing"
    samples = []
    for key, reason in (("start_snapshot", "start"), ("end_snapshot", "refresh")):
        sample = json.loads(artifact(root, row[key]).read_text())
        require(sample["formatVersion"] == 2 and sample["performanceRecipe"] == PERFORMANCE_RECIPE
                and sample["bundleID"] == BUNDLE and sample["platform"] == "device"
                and sample["appSHA256"] == row["app_sha256"]
                and sample["trialID"].lower() == row["trial_id"].lower()
                and sample["mode"] == mode and sample["state"] == active and sample["reason"] == reason
                and sample.get("error") is None
                and type(sample["startCount"]) is int and sample["startCount"] == 1
                and sample["seed"] == 91031 and sample["preset"] == "Focus",
                f"{key} does not identify the trial and its playback state")
        if mode == "aac":
            require(sample["aacSHA256"] == row["fixture_sha256"], f"{key} identifies another AAC file")
        frames = sample["generatedFrames"]
        require(type(frames) is int and frames >= 0, f"invalid frame count in {key}")
        samples.append((instant(sample["observedAt"]), frames))
    (before, initial), (after, final) = samples
    require(before <= warmup < end <= after, "app snapshots do not bracket the measured interval")
    if mode == "idle":
        require(initial == final == 0, "idle snapshot reports playback frames")
    else:
        # The operator captures the endpoints outside the locked measurement. Check elapsed
        # playback over that whole span; a status label alone cannot show it continued.
        if mode == "aac":
            require(final <= fixture_frames, "AAC progress exceeds the staged fixture duration")
        elapsed = (after - before).total_seconds()
        audio = (final - initial) / 32000
        require(abs(elapsed - audio) <= max(3, elapsed * 0.01),
                "frame progression does not match elapsed playback")
    return before, initial, after


def check_row(row, root, block, mode, fixture):
    require(type(row["block"]) is int and (row["block"], row["mode"]) == (block, mode),
            "unexpected block or playback order")
    UUID(row["trial_id"])
    for key in ("device", "model", "os_build", "route", "uncertainty_source"):
        nonempty(row[key], key)
    for key, length in (("build_commit", 40), ("app_sha256", 64), ("fixture_sha256", 64),
                        ("trace_sha256", 64)):
        require(isinstance(row[key], str) and re.fullmatch(f"[0-9a-f]{{{length}}}", row[key]),
                f"invalid {key}")
    require(0 < number(row["volume"], "volume") <= 1 and type(row["low_power"]) is bool,
            "record audible volume (0–1) and the Low Power Mode setting")
    require((row["screen"], row["charging"], row["thermal"], row["capture"]) ==
            ("locked", "unplugged", "nominal", "on_device_power_profiler"),
            "requires locked, unplugged, thermally nominal on-device capture throughout")
    warmup, start, end = (instant(row[key]) for key in ("warmup_start", "measured_start", "measured_end"))
    require((start - warmup).total_seconds() >= 300 and (end - start).total_seconds() >= 1800,
            "requires at least five warmup minutes and 30 measured minutes")
    require(row["metric"] == "whole_system_battery_drain" and row["unit"] in UNITS,
            "expected whole-system battery capacity per hour with explicit units")
    scale = UNITS[row["unit"]]
    rate = number(row["rate"], "rate") * scale
    uncertainty = number(row["uncertainty"], "uncertainty") * scale
    seconds = (end - start).total_seconds()
    maximum = 100 * 3600 / seconds  # A complete battery discharged in this unplugged window.
    require(0 <= rate <= maximum and 0 < uncertainty <= maximum,
            "rate or absolute uncertainty is unbounded for the measured duration")
    trace = artifact(root, row["trace"])
    require(trace.name.endswith((".aar", ".trace.zip", ".atrc.zip", ".trace")), "expected a retained Power Profiler trace")
    require(digest(trace) == row["trace_sha256"], "trace SHA-256 mismatch")
    require(row["fixture_sha256"] == fixture["aac_sha256"], "fixture differs from retained manifest")
    before, initial, after = check_snapshots(row, root, warmup, end, fixture["frames"])
    # Start snapshots can already include generated frames. For idle, the same
    # elapsed clock measures how long the control has been running before capture.
    offset = initial / 32000 + (start - before).total_seconds()
    return before, after, rate, uncertainty, {"block": block, "mode": mode,
                                            "offset_seconds": offset, "duration_seconds": seconds}


def summarize(rates):
    absolute = [{mode: block[mode][0] for mode in block} for block in rates]
    costs = [{mode: block[mode][0] - block["idle"][0] for mode in ("generator", "aac")}
             for block in rates]
    # Bound each paired subtraction using the operator's absolute uncertainties.
    # Taking the full three-block spread gives an envelope, not a confidence interval.
    bounds = {}
    for mode in ("generator", "aac"):
        values = [cost[mode] for cost in costs]
        errors = [block[mode][1] + block["idle"][1] for block in rates]
        bounds[mode] = [min(v - e for v, e in zip(values, errors)),
                        max(v + e for v, e in zip(values, errors))]
    result = {"unit": "percentage_points_per_hour", "absolute_by_block": absolute,
              "above_idle_by_block": costs, "above_idle_envelopes": bounds}
    center = median(cost["aac"] for cost in costs)
    lower, upper = bounds["aac"]
    if lower <= 0 or max(center - lower, upper - center) > 0.10 * center:
        return {**result, "status": "inconclusive",
                "reason": "AAC above idle is unresolved or its envelope exceeds 10% of its median"}
    paired, limits = [], []
    for block, cost in zip(rates, costs):
        delta = block["generator"][0] - block["aac"][0]
        delta_error = block["generator"][1] + block["aac"][1]
        baseline_error = block["aac"][1] + block["idle"][1]
        paired.append(100 * delta / cost["aac"])
        limits.extend(100 * (delta + de) / (cost["aac"] + be)
                      for de in (-delta_error, delta_error)
                      for be in (-baseline_error, baseline_error))
    estimate = median(paired)
    result["paired_difference_envelope_percent"] = [min(limits), max(limits)]
    if max(estimate - min(limits), max(limits) - estimate) > 10:
        return {**result, "status": "inconclusive",
                "reason": "paired difference is uncertain by more than ten percentage points"}
    return {**result, "status": "comparable",
            "paired_generator_vs_aac_above_idle_percent": paired,
            "median_paired_difference_percent": estimate}


def report(path):
    """Return an inconclusive record, without comparisons, on any missing/mismatched evidence."""
    try:
        data = json.loads(path.read_text())
        require(type(data["schema_version"]) is int and data["schema_version"] == 1
                and data["device_role"] in ("older", "current"), "unknown schema or phone role")
        fixture = json.loads(artifact(path.resolve().parent, data["fixture_manifest"]).read_text())
        require(all(type(fixture.get(k)) is type(v) and fixture[k] == v for k, v in CONTRACT.items())
                and type(fixture["frames"]) is int
                and type(fixture["duration_seconds"]) is int and 1 <= fixture["duration_seconds"] <= 3600
                and fixture["frames"] == fixture["duration_seconds"] * 32000,
                "invalid fixture manifest")
        rows = data["trials"]
        require(isinstance(rows, list) and len(rows) == 9, "expected three complete three-mode blocks")
        rates = [{}, {}, {}]
        windows = []
        previous_end = None
        seen_ids, seen_traces = set(), set()
        for index, row in enumerate(rows):
            block, offset = divmod(index, 3)
            mode = BLOCKS[block][offset]
            try:
                before, after, rate, error, window = check_row(row, path.resolve().parent, block + 1, mode, fixture)
                require(all(row[key] == rows[0][key] for key in MATCHED), "device or conditions differ")
                trial_id = UUID(row["trial_id"])
                require(trial_id not in seen_ids and row["trace_sha256"] not in seen_traces,
                        "duplicate trial ID or reused raw trace")
                require(previous_end is None or before >= previous_end, "trial times overlap")
            except (ValueError, KeyError, TypeError, AttributeError, OSError) as exc:
                raise ValueError(f"block {block + 1} {mode}: {exc}") from exc
            rates[block][mode] = (rate, error)
            windows.append(window)
            previous_end = after
            seen_ids.add(trial_id)
            seen_traces.add(row["trace_sha256"])
        for key in ("offset_seconds", "duration_seconds"):
            values = [w[key] for w in windows]
            require(max(values) - min(values) <= 5, f"unmatched {key}; full nine-trial spread exceeds 5s")
        return {"device_role": data["device_role"], "device": rows[0]["device"],
                "windows": windows, **summarize(rates)}
    except (ValueError, KeyError, TypeError, AttributeError, OSError, OverflowError) as exc:
        return {"status": "inconclusive", "reason": str(exc)}
