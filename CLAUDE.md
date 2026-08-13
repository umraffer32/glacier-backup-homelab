# rclone-backups

One project within Uriah's pickleboy homelab — the box that runs Jellyfin, Immich, and the storage they sit on. On the box this directory is `~/rclone-backups`; this public mirror publishes it as `glacier-backup-homelab`. This file covers what's specific to working in this directory.

## What this is

Two backup projects, one repo:

- **Movies** — the Jellyfin library (MOVIES + SHOWS, measured 5.1TB / 13,929 objects) → S3 Glacier **Deep Archive**.
- **Pictures** — the full Immich tree at `/mnt/media/PICTURES` minus `lost+found/` (~173 GiB / 82,455 objects) → S3 Glacier **Instant Retrieval**, chosen for millisecond partial restores. Scope deliberately includes the Immich-regenerable `thumbs/` + `encoded-video/` so restores come back warm — widened from originals-only on 2026-08-11.

Full narrative for both — architecture, decisions, setup, cost, restore procedures, gotchas — is in [README.md](README.md). Read that first; don't expect this file to repeat it.

## Status

**Movies: complete and verified. Nothing outstanding.** All six build steps are done, the full 5.1TB upload (MOVIES + SHOWS) finished **2026-08-10 ~14:49 PDT** — MOVIES ran 7,363/7,363 files with zero real errors — and the backup was **independently reconciled against S3 on 2026-08-10 ~17:38 PDT**.

Reconciliation result: 13,929/13,929 objects present, byte-exact on both legs (MOVIES 3,612,780,382,420 B; SHOWS 1,900,911,285,394 B), `rclone check --one-way --size-only` reporting **0 differences**. Also confirmed, and now re-verified on every `scripts/verify-backup.sh` rerun (checks 5–8): all 13,929 objects are `DEEP_ARCHIVE` (a full census, not a sample — this is what protects the $5.08/mo cost model), bucket versioning is `Enabled`, there are no orphaned multipart uploads, and the only top-level prefixes are `MOVIES/` and `SHOWS/`.

Re-verify **after future backup runs, not on a calendar** — Deep Archive doesn't rot, so a timer-driven check just re-proves this one. Reruns are cheap (~15 LIST requests, well under a cent): `scripts/verify-backup.sh`.

**Pictures: complete and verified. Nothing outstanding but cron.** The full ~173 GiB upload (82,455 objects across all six prefixes) finished **2026-08-11 15:05:44 PDT** — 4h4m41s, `status=0`, zero errors anywhere in the log — and was **independently reconciled against S3 the same day**.

Reconciliation result: 82,455/82,455 objects present, byte-exact on all five compared prefixes (`upload` 140,570,940,085 B; `thumbs` 8,604,628,024 B; `encoded-video` 35,715,967,952 B; `library`/`profile` 13 B each), `rclone check --size-only` reporting **0 differences** on every one. Also confirmed: every object is `GLACIER_IR` (protects the ~$0.70/mo cost model), bucket versioning is `Enabled`, no orphaned multipart uploads, and exactly the six expected top-level prefixes exist.

One thing deliberately not done yet: the monthly cron (`30 3 1 * *`) is written and ready but not installed — held back by choice, not blocked on anything. Re-verify with `scripts/verify-pictures.sh` after future backup runs, same convention as movies.

## The one thing not to get wrong

The original build plan said, in both its Decision 3 and Step 3, that the rclone remote needs an explicit `acl = unset` line. That's backwards — it was the actual bug, and it silently broke every write until traced and removed. The live, working config (`~/.config/rclone/rclone.conf`) has **no** `acl` line at all, plus `no_check_bucket = true`. Trust the live config and README.md over any older plan wording on this one point.

## AWS profiles

Two, deliberately kept separate (`~/.aws/config`):
- `pickleboy` — SSO, admin. Genuinely-admin actions only.
- `pickleboy-backup` — scoped IAM user all backup scripts run under. Two inline policies, one per bucket (`policies/iam-policy-glacier-backup.json`, `policies/iam-policy-glacier-ir-pictures.json`) — no delete permission in either, by design.

## Scripts here

- `scripts/pickleboy-backup.sh` — the actual rclone sync, additive-only
- `scripts/verify-backup.sh` — PASS/FAIL reconciliation of the local library against S3 (8 checks, read-only, sub-cent). Never add `--download` to its `rclone check` calls — hashes can't be compared against archived objects without restoring them, and that would turn a sub-cent listing into a multi-hundred-dollar retrieval.
- `scripts/test-iam-user.sh` — PASS/FAIL policy smoke test against `pickleboy-backup`
- `scripts/pickleboy-backup-pictures.sh` — the pictures backup, additive-only, cron-safe: mount guard aborts *into the log* (`=== run ABORTED ===`), `status=$RC` run brackets
- `scripts/verify-pictures.sh` — PASS/FAIL reconciliation for the pictures bucket (8 checks, read-only, sub-cent). Never add `--download` here either — GIR would serve the bytes and silently bill ~$5 retrieval + egress; for a real hash check drop `--size-only` instead (metadata MD5, zero download, validated)
- `scripts/test-iam-pictures.sh` — PASS/FAIL policy smoke test against the pictures bucket

Full usage of all of them is in README.md. Keep them simple and direct — no unnecessary `set -e`/traps/pre-flight checks, explicit PASS/FAIL-style output. Same convention as the rest of the homelab's scripts.

## Reports

Published Artifacts (private by default), mirrored in `artifacts/` — refresh that mirror whenever a report is re-published. There's also a designed PDF at `reports/pickleboy-glacier-report.pdf` (source in `reports/`, `build-report.sh` regenerates it) — the full synthesis, one document. Both the PDF and the artifact list are surfaced right at the top of README.md now, not just linked from the bottom — readers need to know they're an option before they hit the operational detail.

**Name reports by their role, not the project's state.** "Everything But The Upload" was accurate when written and became actively misleading the moment the upload ran — it was renamed to "The Long Version" on 2026-08-10 (same URL, `73bfd878-…`). The rename touched 11 places across 7 files, because every other report's footer links to it by name. Prefer names that stay true as the project moves.
- [The full PDF report](reports/pickleboy-glacier-report.pdf) — 30-page designed synthesis of the whole project
- [The Short Version](https://claude.ai/code/artifact/0d613c39-fef2-4caf-a9dd-306011d44866) — start here (web)
- [The Pictures Version](https://claude.ai/code/artifact/3556bf57-e29c-413f-9803-42e06fe95514) — the pictures project's report: decisions, three reviews, deployed state, status
- [Every Byte Accounted For](https://claude.ai/code/artifact/3c8069bf-2063-4aec-9613-fd8302d348e8) — verification report, 2026-08-10 reconciliation against S3
- [The Actual Bill](https://claude.ai/code/artifact/7e77bbde-0263-4a76-a0e9-c92833c6becb) — cost analysis
- [The Long Version](https://claude.ai/code/artifact/73bfd878-034e-4c25-a9ae-0972d2490b5c) — implementation status
- [Media Library Sizing & Compression](https://claude.ai/code/artifact/45ca0117-fe6f-4bec-a4ad-c36d06bc7f0c) — sizing & compression research
- [The Grep That Crashed The Box](https://claude.ai/code/artifact/670c08be-cd8b-4ffc-b5e8-cc3dcc0be256) — incident report, 2026-08-10 double freeze/power-cycle, root-caused to a runaway grep call

Downstream of that incident — the two power cycles left the 8TB NTFS media drive with its dirty bit set; it stopped mounting, `/mnt/media/STORAGE` resolved to an empty directory on the root SSD, and the whole Jellyfin library looked deleted. It started here (the runaway grep was a Fable plan-mode session in this directory, grepping `artifacts/the-actual-bill.html`) but the failure was homelab-level, so the full write-up lives in the homelab's incident log outside this repo; `artifacts/the-grep-that-crashed-the-box.html` covers the whole chain. Resolved same day, zero data loss. Mitigation since installed: `earlyoom` — the box had no OOM protection at all, which is why a 12.4GB process could take it down instead of just being killed.
