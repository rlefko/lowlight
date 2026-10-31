#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Check ExtractedFiles.bqrs decoded with --format=json --entities=string."""
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def expected_sources(root):
    top = subprocess.check_output(["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True)
    if Path(top.strip()).resolve() != root:
        raise ValueError("Expected the repository root")
    tracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).decode().split("\0")
    expected = set()
    for name in tracked:
        parts = PurePosixPath(name).parts
        if name.endswith(".swift") and (
            name.startswith("Lowlight/")
            or (len(parts) >= 4 and parts[0] == "Packages" and parts[2] == "Sources")
            or (len(parts) == 3 and parts[0] == "Packages" and parts[2] == "Package.swift")
        ):
            if not (root / name).is_file():
                raise ValueError(f"Missing tracked source: {name}")
            expected.add(name)
    if not any(p.startswith("Lowlight/") for p in expected) or not any(
        p.startswith("Packages/") and "/Sources/" in p for p in expected
    ):
        raise ValueError("Expected nonempty app and package source inventories")
    return expected


def source_path(label, root):
    if not isinstance(label, str) or not label or "\0" in label:
        raise ValueError("Invalid extracted file label")
    if label.startswith("file:"):
        url = urlsplit(label)
        if url.scheme != "file" or url.netloc not in ("", "localhost") or url.query or url.fragment:
            raise ValueError("Invalid extracted file URL")
        label = unquote(url.path, errors="strict")
        if "\0" in label:
            raise ValueError("Invalid extracted file URL")
    path = Path(label)
    if not path.is_absolute():
        raise ValueError("Extracted file labels must be absolute paths")
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return None  # Outside files cannot satisfy repository coverage.


def verify(payload, root):
    root = Path(root).resolve()
    expected = expected_sources(root)
    chunk = payload.get("#select") if isinstance(payload, dict) else None
    if not isinstance(chunk, dict) or "next" in chunk:
        raise ValueError("Expected a complete #select result set")
    columns = chunk.get("columns")
    if not isinstance(columns, list) or len(columns) != 2 or not all(isinstance(c, dict) for c in columns):
        raise ValueError("Unexpected ExtractedFiles result schema")
    if [column.get("kind") for column in columns] != ["Entity", "String"]:
        raise ValueError("Unexpected ExtractedFiles result schema")
    rows = chunk.get("tuples")
    if not isinstance(rows, list) or not rows:
        raise ValueError("Empty or malformed extracted-file inventory")
    extracted = set()
    for row in rows:
        if not isinstance(row, list) or len(row) != 2:
            raise ValueError("Malformed extracted-file row")
        if not isinstance(row[0], dict) or not isinstance(row[1], str):
            raise ValueError("Malformed extracted-file row")
        extracted.add(source_path(row[0].get("label"), root))
    missing = sorted(expected - extracted)
    if missing:
        raise ValueError("Swift files missing from CodeQL extraction: " + ", ".join(missing))
    return len(expected)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: scripts/verify-codeql-coverage.py DECODED_JSON [REPOSITORY_ROOT]")
    try:
        root = Path(sys.argv[2]) if len(sys.argv) == 3 else Path(__file__).resolve().parents[1]
        count = verify(json.loads(Path(sys.argv[1]).read_text()), root)
        print(f"Verified CodeQL extraction of all {count} app/package Swift sources and manifests")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
