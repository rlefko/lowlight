#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Check the app's visual trace against the XCUITest observation windows."""
import argparse
from datetime import datetime
import json
from math import ceil
from pathlib import Path
import re
from statistics import median
from typing import NamedTuple


class Event(NamedTuple):
    time: float
    pid: int
    category: str
    message: str


EXPECTED = {
    "active": "active", "about": "covered", "afterAbout": "active",
    "controls": "covered", "offscreen": "offscreen", "afterScroll": "active",
    "background": "scene", "foreground": "active", "paused": "playback",
    "lowPower": "lowPower", "reduceMotion": "reduceMotion", "disabled": "disabled",
}
ANCHOR = re.compile(r"anchor frame=(\d+) seed=(\d+) playing=([01])")


def read_trace(path):
    events = []
    with path.open(encoding="utf-8") as source:
        for line in source:
            if not line.startswith("{"):  # simctl also prints a filter banner
                continue
            record = json.loads(line)
            category = record.get("category")
            if record.get("subsystem") != "com.rlefko.lowlight" or category not in (
                "Horizon", "HorizonEvidence"
            ):
                continue
            events.append(Event(
                datetime.fromisoformat(record["timestamp"]).timestamp(),
                record["processID"], category, record["eventMessage"],
            ))
            if len(events) > 25_000:
                raise ValueError("Expected the filtered trace from one visibility test.")
    return sorted(events)


def gate_window(events, name, gate):
    markers = [e for e in events if e.category == "HorizonEvidence"
               and e.message in ("begin " + name, "end " + name)]
    if len(markers) != 2 or markers[0].message != "begin " + name or markers[0].pid != markers[1].pid:
        raise ValueError(f"{name}: incomplete or duplicate window")
    start, end = (e.time for e in markers)
    before = [e for e in events if e.category == "Horizon" and e.time <= start]
    gates = [e for e in before if e.message.startswith("gate ")]
    if not gates or gates[-1].message != "gate " + gate:
        raise ValueError(f"{name}: expected gate {gate}, observed {gates[-1:]}")
    pid = gates[-1].pid
    during = [e for e in events if e.category == "Horizon" and start <= e.time <= end]
    if any(e.message.startswith("gate ") or e.pid != pid for e in during):
        raise ValueError(f"{name}: gate or process changed during measurement")
    return start, end, pid, before, during


def check_cost_gate(path, mode):
    events = read_trace(Path(path))
    gate = {"animated": "active", "static": "disabled"}[mode]
    start, end, pid, _, _ = gate_window(events, "cost " + mode, gate)
    # The measured app emits only transition events. Reject accidentally timed per-frame tracing.
    if any(e.pid != pid or not e.message.startswith("gate ") for e in events if e.category == "Horizon"):
        raise ValueError(f"{mode}: expected only gate transitions from the measured app")
    duration = end - start
    if not 58 <= duration <= 75:
        raise ValueError(f"{mode}: warmup and measured playback spanned {duration:.3f}s")
    return {"mode": mode, "gate": gate, "pid": pid, "seconds": round(duration, 3)}


def window(events, name, gate):
    start, end, pid, before, during = gate_window(events, name, gate)
    duration = end - start
    if not 2.9 <= duration <= 3.5:
        raise ValueError(f"{name}: expected a three-second window, got {duration:.3f}s")
    samples = [ANCHOR.fullmatch(e.message) for e in before if e.pid == pid and e.message.startswith("anchor ")]
    if not samples or not samples[-1] or samples[-1][3] != ("0" if name == "paused" else "1"):
        raise ValueError(f"{name}: missing expected playback state in this app process")
    ticks = [e.time for e in during if e.message == "tick"]
    draws = sum(e.message == "draw" for e in during)
    if gate == "active":
        # Count complete events; a fractional window can include a final frame at its edge.
        ceiling = ceil(15 * duration)
        if not (1 < len(ticks) <= ceiling and 1 < draws <= ceiling):
            raise ValueError(f"{name}: {len(ticks)} wakes / {draws} draws in {duration:.3f}s")
    elif ticks or draws:
        raise ValueError(f"{name}: {len(ticks)} wakes / {draws} draws while gated")
    intervals = [(b - a) * 1000 for a, b in zip(ticks, ticks[1:])]
    return {
        "gate": gate, "start": start, "end": end, "pid": pid, "seconds": round(duration, 3),
        "ticks": len(ticks), "draws": draws, "draws_per_second": round(draws / duration, 2),
        "tick_interval_ms": ({
            "min": round(min(intervals), 2), "median": round(median(intervals), 2),
            "max": round(max(intervals), 2),
        } if intervals else None),
    }


def background_progression(events, measured):
    samples = [(event.time, int(match[1]), int(match[2])) for event in events
               if event.pid == measured["pid"] and (match := ANCHOR.fullmatch(event.message))
               and match[3] == "1"]
    before = [s for s in samples if s[0] <= measured["start"]]
    after = [s for s in samples if s[0] >= measured["end"]]
    if not before or not after:
        raise ValueError("Missing background entry capture or foreground playback refresh.")
    entry, leave = before[-1], after[0]
    wall = leave[0] - entry[0]
    audio = (leave[1] - entry[1]) / 32_000
    if entry[2] != leave[2] or audio < measured["seconds"] - 0.25 or abs(wall - audio) > 0.75:
        raise ValueError(f"Expected advancing audio around Home/return; got {entry} to {leave}.")
    return {
        "entry_frame": entry[1], "exit_frame": leave[1], "seed": entry[2],
        "wall_seconds": round(wall, 3), "audio_seconds": round(audio, 3),
    }


def analyze(path):
    events = read_trace(Path(path))
    windows = {name: window(events, name, gate) for name, gate in EXPECTED.items()}
    return {"windows": windows, "background_progression": background_progression(events, windows["background"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="Filtered simulator log stream in NDJSON format")
    try:
        print(json.dumps(analyze(parser.parse_args().trace), indent=2))
    except (OSError, KeyError, ValueError) as error:
        parser.exit(1, f"Visibility check failed: {error}\n")
