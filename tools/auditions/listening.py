#!/usr/bin/env python3
# Copyright (C) 2026 Ryan Lefkowitz
# SPDX-License-Identifier: GPL-3.0-only
"""Package the preregistered listening comparisons without revealing their order."""

import argparse
import html
import json
import math
from pathlib import Path
import random
import subprocess
import tempfile
import wave

from writing import fingerprint

RAW = ("-f", "f32le", "-ar", "32000", "-ac", "2")
PAIRS = (("focus", "Focus", 105), ("reflective", "Reflective", 105),
         ("commute", "Commute", 105), ("continuous", "Continuous session", 600),
         ("palette", "Instrument palette", 105))


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True)


def levels(path, options=()):
    result = run("ffmpeg", "-nostdin", "-hide_banner", *options, "-i", str(path), "-af",
                 "loudnorm=print_format=json", "-f", "null", "-")
    record = json.JSONDecoder().raw_decode(result.stderr[result.stderr.rfind("{"):])[0]
    loudness, peak = float(record["input_i"]), float(record["input_tp"])
    if not all(math.isfinite(value) for value in (loudness, peak)):
        raise ValueError(f"invalid audio levels in {path}")
    return loudness, peak


def read_capture(directory):
    record = json.loads((directory / "capture.json").read_text())
    for name, item in record["audio"].items():
        if name not in {"focus", "reflective", "commute", "original-palette"}:
            raise ValueError(f"unknown recording {name}")
        source = directory / (name + ".f32")
        if source.stat().st_size != item["seconds"] * 32000 * 8 or fingerprint(source) != item["pcm_sha256"]:
            raise ValueError(f"recording differs from its capture manifest: {name}")
    return record


def encode(source, output, scratch, seconds, gain):
    # Apply a single attenuation to preserve dynamics. Check the AAC a listener will hear.
    raw = scratch / "matched.wav"
    run("ffmpeg", "-nostdin", "-v", "error", "-y", *RAW, "-t", str(seconds), "-i", str(source),
        "-af", f"volume={gain:.6f}dB:precision=double", "-c:a", "pcm_f32le", str(raw))
    run("/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "160000", str(raw), str(output))
    decoded = scratch / "decoded.wav"
    run("/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16", str(output), str(decoded))
    with wave.open(str(decoded), "rb") as wav:
        if (wav.getnchannels(), wav.getframerate(), wav.getnframes()) != (2, 32000, seconds * 32000):
            raise ValueError(f"decoded format or length mismatch: {output.name}")
    decoded.unlink()
    return levels(output)


def listening_page():
    rows = []
    for stem, title, seconds in PAIRS:
        buttons = "".join(
            f'<button type="button" data-file="{stem}-{label}.m4a" aria-pressed="{str(label == "A").lower()}">{label}</button>'
            for label in ("A", "B"))
        rows.append(f'<section><h2>{html.escape(title)} <small>{seconds // 60}:{seconds % 60:02}</small></h2>'
                    f'<div class="player">{buttons}<audio controls preload="none" src="{stem}-A.m4a"></audio></div></section>')
    return """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Lowlight listening comparison</title>
<style>
:root{color-scheme:light dark;font-family:system-ui,sans-serif}body{max-width:44rem;margin:3rem auto;padding:0 1rem}
h1{letter-spacing:-.04em}p{line-height:1.5}section{padding:.65rem 0 1.3rem;border-top:1px solid #888}
h2{font-size:1.15rem}small{font-size:.85rem;font-weight:400}button{font:inherit;min-width:2.8rem;min-height:2.8rem}
[aria-pressed=true]{font-weight:700;outline:2px solid currentColor}.player{display:flex;align-items:center;gap:.6rem}
audio{flex:1;min-width:8rem}
</style><main><h1>Lowlight listening comparison</h1>
<p>Keep your volume fixed. Select A or B to hear the same moment in the other recording.
Which would you leave playing? Note when you first anticipate the loop or hear a distracting change.</p>
""" + "\n".join(rows) + """
</main><script>
document.querySelectorAll("section").forEach(section=>{
  const player=section.querySelector("audio");
  player.addEventListener("play",()=>document.querySelectorAll("audio").forEach(other=>{if(other!==player)other.pause()}));
  section.querySelectorAll("button").forEach(button=>button.onclick=()=>{
    if(button.getAttribute("aria-pressed")==="true")return;
    const time=player.currentTime, playing=!player.paused;
    player.pause();
    section.querySelectorAll("button").forEach(b=>b.setAttribute("aria-pressed",String(b===button)));
    player.src=button.dataset.file;
    player.onloadedmetadata=()=>{player.currentTime=Math.min(time,player.duration);if(playing)player.play().catch(()=>{})};
    player.load();
  });
});
</script></html>"""


def package(baseline, candidate, destination):
    if destination.exists():
        raise ValueError("choose a new directory for this audition")
    before, after = read_capture(baseline), read_capture(candidate)
    if set(before["audio"]) != {"focus", "reflective", "commute"} or set(after["audio"]) != set(before["audio"]) | {"original-palette"}:
        raise ValueError("provide the original and expanded writing captures in that order")
    frozen = Path(__file__).resolve().parents[2] / "tests/fixtures/music-writing-v1/capture.json"
    if before["audio"] != json.loads(frozen.read_text())["audio"]:
        raise ValueError("baseline PCM does not match the frozen recordings")
    rng = random.SystemRandom()
    # Counterbalance the three short pairs, then conceal each of the two remaining orders.
    short_order = [True, False, rng.choice([True, False])]
    rng.shuffle(short_order)
    order = short_order + [rng.choice([True, False]) for _ in range(2)]
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        scratch = Path(temp)
        result = scratch / "listening"
        result.mkdir()
        key = {}
        for (stem, _, seconds), reverse in zip(PAIRS, order):
            recording = "focus" if stem in ("continuous", "palette") else stem
            items = [("PR 52", baseline / (recording + ".f32")), ("new band", candidate / (recording + ".f32"))]
            if stem == "palette":
                items[0] = ("new score, original palette", candidate / "original-palette.f32")
            if reverse:
                items.reverse()
            source_levels = [levels(path, (*RAW, "-t", str(seconds))) for _, path in items]
            target = min(loudness + min(0, -2.0 - peak) for loudness, peak in source_levels)
            readings = []
            for label, (identity, path), (loudness, _) in zip("AB", items, source_levels):
                asset = result / f"{stem}-{label}.m4a"
                gain = target - loudness
                measured, peak = encode(path, asset, scratch, seconds, gain)
                if peak > -1.0 or abs(measured - target) > 0.2:
                    raise ValueError(f"decoded {asset.name} measures {measured} LUFS, {peak} dBTP (target {target})")
                readings.append(measured)
                key[asset.name] = dict(identity=identity, seconds=seconds, constant_gain_db=gain,
                                       lufs=measured, true_peak_dbtp=peak, sha256=fingerprint(asset))
            if abs(readings[0] - readings[1]) > 0.2:
                raise ValueError(f"encoded {stem} pair differs by more than 0.2 LU")
        (result / "index.html").write_text(listening_page())
        (result / "answer-key.json").write_text(json.dumps(key, indent=2) + "\n")
        result.rename(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("baseline", "candidate", "destination"):
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    package(args.baseline.resolve(), args.candidate.resolve(), args.destination.resolve())
