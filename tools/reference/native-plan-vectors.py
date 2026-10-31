#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce native-v1 test vectors through the frozen Python draft algorithm."""
from collections import deque
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / "v9"))
import session_planner as reference

MASK = (1 << 64) - 1


class SplitMix:
    """Vigna's SplitMix64 transition with the native-v1 choice/Double mapping."""
    def __init__(self, seed):
        self.state = seed

    def raw(self):
        self.state = (self.state + 0x9e3779b97f4a7c15) & MASK
        word = self.state
        word = ((word ^ (word >> 30)) * 0xbf58476d1ce4e5b9) & MASK
        word = ((word ^ (word >> 27)) * 0x94d049bb133111eb) & MASK
        return word ^ (word >> 31)

    def randrange(self, count):
        threshold = ((-count) & MASK) % count
        while True:
            value = self.raw()
            if value >= threshold:
                return value % count

    def choice(self, values):
        return values[self.randrange(len(values))]

    def random(self):
        return (self.raw() >> 11) / 9007199254740992

    def uniform(self, low, high):
        return low + (high - low) * self.random()


if __name__ == "__main__":
    planner = reference.SessionPlanner.__new__(reference.SessionPlanner)
    planner.rng = SplitMix(91031)
    planner.seed = 91031
    planner.controls = reference.PRESETS["Focus"]
    planner.recent_families = deque(maxlen=4)
    planner.recent_signatures = deque(maxlen=64)
    planner.index = 0
    planner.baseline_first = False
    song = None
    plans = []
    for _ in range(4):
        song = planner._draft(song)
        plans.append({key: song[key] for key in [
            "family", "key", "energy", "tempo", "bars", "focus", "melody",
            "melody_times", "take_seed", "drum_cell", "bass_cell", "phrase_arc"
        ]})
    print(json.dumps(plans, indent=2))
