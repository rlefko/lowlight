# Sound bank

## Frozen revision 9 recordings

The original bank contains the 77 active recorded notes from the accepted revision 9 archive, copied without conversion or editing. Archive SHA-256: `64f61c7bc012aa862a26cfc0de28a03681acdde1174992f970f1b5d281c2ca61`. The two original manifests preserve source URLs, revisions, source checksums, mapping corrections, trimming, gain calibration, and prepared-asset checksums.

| Source | Active notes | Instruments | Retained notices |
| --- | --- | --- | --- |
| FreePats Electric Guitar FSBS (jazz), 2026-08-07 | 32 | Electric guitar | Original license and README |
| VCSL, commit `c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e` | 35 | Piano and percussion | Original CC0 notice |
| VSCO Community, commit `440300901dfe9275fd84e0b7763af1f8443ae62e` | 10 | Bass | Original CC0 notice |

All active notes are CC0-1.0. Their notices live in [SoundBank/licenses](../Lowlight/SoundBank/licenses). No legacy acoustic-guitar samples or unrelated notices are imported. The bank is 8,825,758 compressed bytes; decoded interleaved float32 data totals 55,605,692 bytes (53.03 MiB). Including manifests, inventory, and notices, the 85 bank files total 8,975,997 bytes before packaging.

`inventory.json` is a compact index derived from the original manifests. It adds SHA-256 checksums of the decoded samples, generated with FFmpeg 7.1 as interleaved little-endian float32 at the source rate and channel count. No resampling, channel remixing, gain, or lossy encoding was applied. These hashes allow the Apple decoder test to compare every sample against an independent decoder. `manifest-checksums.json` freezes the original manifests/notices and the derived inventory.

Run `scripts/verify-bank` to verify the exact file set, compressed hashes and sizes, FLAC headers, metadata agreement, provenance, and license inventory. Run `scripts/verify-bank --decode` with FFmpeg available to independently check decoded sample hashes. The default validator needs only Ruby's standard library and makes no network requests. Native decoding results and platform limits are documented in the PR's validation evidence; this bank inventory alone does not establish iOS decoder support.

To reproduce the import from an authorized copy of the accepted archive, verify its archive hash, parse the 45 entries in `sample_manifest.json` and 32 entries in `electric_guitar_manifest.json`, and copy only those `asset` paths plus the four active notice files byte for byte. Preserve the two manifests unchanged. The decoded hash command for each note is `ffmpeg -nostdin -v error -i NOTE.flac -map 0:a:0 -c:a pcm_f32le -f f32le -`; hash those output bytes. Do not normalize or re-prepare the recordings during import. Original preprocessing details remain in the source manifests rather than an invented reconstruction script.

Developer reference code, plans, short fixtures, and their measurements are outside the app target. Long listening references, research plots/reports, the handoff archive, and analysis-only uploaded audio remain outside version control and app resources.


## Band recordings

The band adds 28 recordings of individual notes from the same VCSL revision. The ten TX81Z electric-piano notes cover two velocity layers. Six soft-mallet vibraphone notes retain their mallet attacks and decays. The tenor has six non-vibrato sustains and six staccato notes. Each voice maps to the nearest recorded concert pitch within three semitones. The preparation measures each fundamental because the original filenames use different octave conventions. [Pinned VCSL source and CC0 license](https://github.com/sgossner/VCSL/tree/c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e)

The [source inventory](../tools/band/sources-v1.json) records every WAV path, git blob ID, SHA-256 and concert pitch. To reproduce the band under the pinned Python environment, run the following from the repository root. An existing VCSL checkout at this revision can replace the source directory when running offline.

```sh
tools/reference/setup /path/to/python3.12
.tools/reference/bin/python tools/band/prepare.py --download .build/vcsl .build/reproduced-band
diff -r Lowlight/SoundBank/band .build/reproduced-band
```

The importer maintains a small lead-in for breath and mallet noise, downmixes and resamples to 32 kHz, removes low-frequency rumble, calibrates each note's first 400 ms at Focus Warmth, and bounds peaks and release tails. The 16-bit mono FLACs total 2,075,718 bytes. Their [shipped manifest](../Lowlight/SoundBank/band/manifest.json) includes peak-estimated tuning offsets in cents, leading frames trimmed at 32 kHz, SHA-256 of each FLAC, and independent decoded Float32 checksums. The directory occupies 2,088,224 bytes including that manifest. The app selects the brighter electric-piano layer at velocity 0.50 and the short tenor recording at gates up to 320 ms.

Prepared voices share the keys bus and room send. The fourth-order low-pass cutoff moves from 4,200 Hz to 1,700 Hz across Warmth. Sample selection, pitch shifting and decoding happen before playback. The render kernel uses its fixed voice pool and filters the active voices as Warmth changes. The finite note release, room tail and peak protector run through the existing song path.
