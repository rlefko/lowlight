# Frozen revision 9 sound bank

The app bank contains the 77 active recorded notes from the accepted revision 9 archive, copied without conversion or editing. Archive SHA-256: `64f61c7bc012aa862a26cfc0de28a03681acdde1174992f970f1b5d281c2ca61`. The two original manifests preserve source URLs, revisions, source checksums, mapping corrections, trimming, gain calibration, and prepared-asset checksums.

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
