#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Regenerate the catalog from DuskHorizon.svg on macOS with sips and Pillow."""

from pathlib import Path
import subprocess
import tempfile

from PIL import Image

HERE = Path(__file__).resolve().parent
CATALOG = HERE.parents[1] / "Lowlight/Assets.xcassets"
MASTER = (HERE / "DuskHorizon.svg").read_text()
DAY = ("#938588", "#e9ba9c", "#ffe2a8", "#6a687d", "#343d53")
PALETTES = {
    "Day": DAY,
    "Night": ("#21243b", "#766879", "#ffd69c", "#565269", "#282f45"),
    "Tinted": ("#494949", "#a9a9a9", "#ffffff", "#626262", "#292929"),
}

with tempfile.TemporaryDirectory() as temp:
    svg = Path(temp) / "icon.svg"
    png = Path(temp) / "icon.png"
    for name, palette in PALETTES.items():
        artwork = MASTER
        for source, destination in zip(DAY, palette):
            if source not in artwork:
                raise ValueError(f"Missing master color {source}")
            artwork = artwork.replace(source, destination)
        svg.write_text(artwork)
        subprocess.run(["sips", "-s", "format", "png", svg, "--out", png], check=True)
        with Image.open(png) as image:
            if image.size != (1024, 1024) or image.convert("RGBA").getchannel("A").getextrema() != (255, 255):
                raise ValueError("Icons require an opaque, full-bleed 1024-pixel master")
            rgb = image.convert("RGB")
            rgb.save(CATALOG / f"AppIcon.appiconset/{name}.png", optimize=True)
            if name == "Day":
                poster = rgb.resize((512, 512), Image.Resampling.LANCZOS)
                poster.save(CATALOG / "NowPlayingArtwork.imageset/Dusk.png", optimize=True)
