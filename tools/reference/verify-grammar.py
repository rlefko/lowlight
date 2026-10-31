#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Check native grammar data against the immutable accepted Python catalog."""
import ast
from dataclasses import asdict
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE / "v9"))
import session_planner as reference


def expected():
    tree = ast.parse((HERE / "v9/session_planner.py").read_text())
    assignments = [node for node in ast.walk(tree) if isinstance(node, ast.Assign)]
    keys = next(node.value for node in assignments if any(
        isinstance(target, ast.Name) and target.id == "keys" for target in node.targets))
    forms = next(node.value.args[0] for node in assignments if isinstance(node.value, ast.Call)
                 and any(isinstance(target, ast.Name) and target.id == "bars" for target in node.targets))
    arcs = next(node.value.args[0] for node in ast.walk(tree)
                if isinstance(node, ast.keyword) and node.arg == "phrase_arc")
    return {
        "schemaVersion": 1,
        "chords": {name: dict(root=value[0], voices=value[1], tops=value[2])
                   for name, value in reference.CHORDS.items()},
        "families": [dict(id=family["id"], mode=family["mode"], baseKey=family["base_key"],
                          progression=family["progression"]) for family in reference.CATALOG],
        "contours": reference.CONTOURS,
        "keys": ast.literal_eval(keys),
        "forms": ast.literal_eval(forms),
        "phraseArcs": ast.literal_eval(arcs),
        "names": reference.NAMES,
        "presets": {name: asdict(controls) for name, controls in reference.PRESETS.items()},
    }


if __name__ == "__main__":
    path = ROOT / "Packages/LowlightPlanning/Sources/LowlightPlanning/Resources/grammar-v1.json"
    if json.loads(path.read_text()) != expected():
        raise SystemExit("Native grammar differs from the frozen accepted catalog")
    print("Native grammar matches all 26 families, 16 chords, contours, forms, and presets")
