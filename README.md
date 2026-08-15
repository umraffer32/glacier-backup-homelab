# Pickleboy Glacier Backup

Two additive-only backups from pickleboy to S3's Glacier family, via scoped no-delete IAM credentials and `rclone`, in one repo. This file is the operational reference for both — what's actually deployed, how to reproduce it, and how to run it; full reasoning and cost math live in the linked reports.

- **Movies (Jellyfin) → Glacier Deep Archive** — 5,135 GiB / 13,929 objects. **Complete and verified:** the full upload finished **2026-08-10 ~14:49 PDT** and was independently reconciled against S3 the same day — 13,929/13,929 objects, byte-exact, **0 differences**. See [Verification](#verification). Nothing outstanding.
- **Pictures (Immich) → Glacier Instant Retrieval** — ~173 GiB / 82,455 objects, the full tree. **Complete and verified:** the full upload finished **2026-08-11 ~15:05 PDT** and was independently reconciled against S3 the same day — 82,455/82,455 objects, byte-exact, **0 differences**. Nothing outstanding but the monthly cron, held back by choice. See [The pictures backup](#the-pictures-backup-immich--glacier-instant-retrieval).
- **Pictures, third copy → local, on Uriah's Windows PC** — 3-2-1 complete. `D:\immich-backup`, 82,492 files / 188,049,601,430 bytes, exact match against the source tree. See [The local third copy](#the-local-third-copy-pictures--windows-pc).

> **Public mirror.** One-time sanitized snapshot of the private working repo: the AWS account ID — everywhere, including inside the two bucket names — is replaced with AWS's canonical example ID `123456789012`. Everything else (paths, hostnames, profile names, dates, costs) is real and as-deployed.

## Read this as

This README is the terse operational reference — what's deployed, how to reproduce it, how to run it. If you want the actual story, two other formats cover it:

- **[The full PDF report](reports/pickleboy-glacier-report.pdf)** — 30 pages, designed, front to back: sizing, the six decisions, the build, the bug three reviews missed, the upload, the crash that hit hours later, the money, the proof, and the restore procedure. Start here if you're only reading one thing.
- **[The Short Version](https://claude.ai/code/artifact/0d613c39-fef2-4caf-a9dd-306011d44866)** — the same story as one web page, if a page beats a PDF for you. Five more web reports go deeper on specific angles (cost, verification, the incident, sizing research) — full list in [Links](#links).

Both cover the movie project. The pictures project's running report is **[The Pictures Version](https://claude.ai/code/artifact/3556bf57-e29c-413f-9803-42e06fe95514)** — decisions, reviews, deployed state, and status, updated as the project moves.

All the web reports linked in this README are also mirrored in-repo under [`artifacts/`](artifacts/) — the claude.ai links may require access; the in-repo copies don't.

## The pictures backup (Immich → Glacier Instant Retrieval)

**Status (2026-08-11): complete and verified.** The full upload ran **11:01:03–15:05:44 PDT** (4h4m41s, `status=0`, zero errors in the log) and was reconciled against S3 the same afternoon: 82,455/82,455 objects, byte-exact, **0 differences**, every object confirmed `GLACIER_IR`. Everything below describes deployed, verified, *running* configuration — the only thing not yet done is the monthly cron, held back deliberately (see [Cadence](#cadence)).

### What's backed up

The full Immich tree at `/mnt/media/PICTURES`, minus only `lost+found/` — **175.12 GiB / ~82,500 objects**:

| Prefix | What it is | Size |
|---|---|---|
| `upload/` | The originals — the irreplaceable set | 130.92 GiB / 26,652 files |
| `thumbs/` | Thumbnails + previews (Immich-regenerable) | 8.3 GiB |
| `encoded-video/` | Transcodes (Immich-regenerable) | 34 GiB |
| `library/` + `profile/` | 13-byte `.immich` markers today; `library/` is where a storage-template migration would land originals | ~26 B |
| `backups/` | Newest 1–2 nightly Postgres dumps per run (`--max-age 48h --min-age 1m`) — albums, people, faces and edits all live in the DB, photos alone lose that structure | ~214 MiB each |

Scope history, honestly: the plan was originally originals-only, per [The Actual Bill](https://claude.ai/code/artifact/7e77bbde-0263-4a76-a0e9-c92833c6becb) §07's analysis that derived data buys nothing a restore can't rebuild. Widened to the full tree on 2026-08-11: ~$2/yr buys a restore that comes back instantly warm instead of waiting on regeneration jobs.

### Why Instant Retrieval, not Deep Archive

One reason, and it isn't the one usually given: **partial-restore ergonomics.** "I need that album back" is a plain `rclone copy` with millisecond access — no restore-request, no 12–48 h wait, no temporary Standard-rate copy billed alongside. That's worth the ~52¢/mo premium over Deep Archive at this size. Explicitly *not* a reason: minimum-duration floors. This design is additive-only with a no-delete credential and no lifecycle rules — nothing is ever deleted, so neither GIR's 90-day nor Deep Archive's 180-day floor can ever bill. Consequence accepted deliberately: the bucket tracks *cumulative-ever-uploaded*, including photos later culled locally and thumbnails superseded by regeneration.

### Deployed infrastructure

- **Bucket: `s3-glacier-ir-pictures-123456789012-us-west-2`**, us-west-2. Versioning `Enabled`, all four public-access-block flags on, SSE-S3 default encryption, Object Ownership `BucketOwnerEnforced`, **no lifecycle rules and no bucket policy** — verified at creation. A lifecycle rule is the only way a deletion path could enter this design; keep it that way.
- **Second rclone remote** — the movie remote pins `DEEP_ARCHIVE` remote-wide, so pictures get their own:
  ```ini
  [pickleboy-glacier-ir]
  type = s3
  region = us-west-2
  storage_class = GLACIER_IR
  chunk_size = 64M
  provider = AWS
  env_auth = true
  no_check_bucket = true
  ```
  Same rules as the movie remote: **no `acl` line** (see the movie project's headline gotcha below), and the storage class lives in the config so no hand-typed command can accidentally land `STANDARD`.
- **Second inline IAM policy on the same user** — [`policies/iam-policy-glacier-ir-pictures.json`](policies/iam-policy-glacier-ir-pictures.json), deployed as `pickleboy-glacier-ir-bucket-access`. Identical action set to the movie policy (list/put/get/restore/multipart, **zero delete actions**), scoped to the pictures bucket only. Deliberately a *separate* policy, not an edit: the movie project's deployed policy stays byte-for-byte untouched, and a mistake here can only ever break the new bucket. Both live policies verified to match their repo JSON files.

### Scripts

- **[`scripts/pickleboy-backup-pictures.sh`](scripts/pickleboy-backup-pictures.sh)** — the backup. Six `rclone copy` legs (upload, library, profile, thumbs, encoded-video, backups), additive-only, safe to re-run anytime. Built for unattended cron, which the movie script never was: a `mountpoint` guard aborts *into the log* (`=== run ABORTED ===`) if the drive isn't mounted — with a static library, "0 transferred" is what a healthy run looks like, so an unmounted drive would otherwise be indistinguishable from success — and `=== run start/end status=N ===` lines bracket every run. Flag rationale: `--fast-list` (the hash-bucket fan-out is 33k+ directories; without it every run costs ~23,000 LIST requests, with it ~27), `--transfers 16` (26k small files are request-bound), `--min-age 1m` (skips files Immich is mid-write on), `--max-age 48h` on the dumps leg only.
  ```bash
  ~/rclone-backups/scripts/pickleboy-backup-pictures.sh
  ```
- **[`scripts/verify-pictures.sh`](scripts/verify-pictures.sh)** — 8-check PASS/FAIL reconciliation, read-only, sub-cent: mount, per-prefix totals, per-file `rclone check` on all five content prefixes, bucket-side dump freshness (newest dump ≤ 35 days — stays true all month, unlike comparing against last night's local dump), full `GLACIER_IR` census, versioning, orphaned multipart uploads, exact six-prefix census. Run after backup runs, not on a schedule. **Never add `--download`**: unlike Deep Archive (which fails loudly), GIR would happily serve every byte and bill ~$5 of retrieval plus egress. For a real hash check, drop `--size-only` instead — on GIR, `rclone check` compares MD5s from object metadata with zero download (validated live on a multipart smoke object).
  ```bash
  ~/rclone-backups/scripts/verify-pictures.sh
  ```
- **[`scripts/test-iam-pictures.sh`](scripts/test-iam-pictures.sh)** — 5-check IAM smoke test, same shape as the movie one: list/put/read succeed, delete with the scoped profile **fails by design**, admin cleanup. Ran 5/5 on 2026-08-11.
  ```bash
  ~/rclone-backups/scripts/test-iam-pictures.sh
  ```

### Cadence

The first verified full run has happened, so this is ready to install — but it's being **held back deliberately for now**, not blocked on anything:

```
30 3 1 * * /home/mrpocket/rclone-backups/scripts/pickleboy-backup-pictures.sh >/dev/null 2>&1
```

03:30 on the 1st sits 1.5 h after Immich's 02:00 nightly dump, inside the 48 h window. Stdout is discarded deliberately — no MTA exists on this box — so `pictures-backup.log` is the *only* record a run leaves; the start/end/ABORTED lines are what make that log answerable at a glance. Stated plainly: **worst-case data-loss window will be ~31 days** of new photos once this is installed. Accepted because the library has been static since Feb 27 (measured, not assumed) and changing cadence is a one-character crontab edit if continuous uploads resume. Verification stays manual-after-runs, never scheduled.

### Restoring pictures

No restore-request dance — GIR objects are immediately readable. Reverse the direction and go:

```bash
rclone copy pickleboy-glacier-ir:s3-glacier-ir-pictures-123456789012-us-west-2/upload /mnt/media/PICTURES/upload --progress
```

- **Partial restores** (an album, a folder): effectively pennies — $0.03/GB retrieval, and egress rides inside AWS's 100 GB/mo free tier.
- **Full restore:** ~**$12.8** in one calendar month (retrieval $5.25 + egress $6.76 + GET requests $0.82), or ~**$6.1** split across two months — 175 GiB fits inside 2×100 GB of free egress. The free tier is account-wide: a simultaneous movie restore competes for it.
- The tree comes back **warm** — thumbs and transcodes included, no regeneration wait — and every folder's `.immich` marker rides along with it (Immich refuses to start a non-empty folder that's missing its marker; it's just an epoch-ms timestamp, `date +%s%3N` recreates one if ever needed).
- The DB dumps under `backups/` restore the metadata: albums, people, faces, edits. Restore the newest dump alongside the files.

### What it costs (pictures)

| Scenario | Cost |
|---|---|
| Steady-state storage | ~$0.70/mo · ~$8.4/yr |
| Growth from dump accumulation | +~$0.02/mo per year of operation |
| One-time upload PUT fees | ~$1.65 |
| Full restore, single month | ~$12.8 |
| Full restore, patient (2 months) | ~$6.1 |
| Premium over Deep Archive | ~52¢/mo |

### Pictures gotchas

1. **The storage-template landmine.** Immich's storage template is an admin-UI toggle with zero config-file trace. Flipping it *moves* every original from `upload/` into `library/` — and this additive-only design would then hold two complete copies forever (~doubling the `upload/`-side bill), with cleanup possible only via the admin profile. Don't enable it without planning the S3 side first.
2. **The dumps leg is non-self-healing.** Local retention is a 14-day rolling window; the cron captures a 48 h slice monthly. One missed run (box down on the 1st, drive unmounted) and that month's dumps are permanently gone from the backup — the next run can't reach back. The ABORTED/status log lines exist to make a missed run visible; glance at the log after the 1st.
3. **"0 transferred" is a healthy run.** Don't read an idle log as a broken one — and don't read a broken mount as idle; the mount guard (a lesson from the 2026-08-10 mount incident) is what distinguishes them.
4. **Thumbnail regeneration churns the bucket.** If Immich regenerates derivatives (version upgrades do this), changed files re-upload and superseded ones persist as noncurrent versions or orphaned keys. `verify-pictures.sh` check 2 treats remote ≥ local on `thumbs/`/`encoded-video/` as expected for exactly this reason. Bounded by the derived data's size — pennies.
5. **`pictures-backup.log` is gitignored and unbounded.** Append-only, no rotation, ~82k INFO lines from the first run alone. Accepted; it's the run record, not repo content.

## The local third copy (pictures → Windows PC)

**Status (2026-08-14): done.** 3-2-1 is now complete for the pictures project: live tree + Glacier IR offsite + this local copy.

The plan was originally a local drive physically attached to pickleboy — a spare USB stick, then a spare bare HDD needing a dock. Both hit real friction (the stick hard-stalled at the kernel level under sustained write and turned out to run hot; the HDD needed a dock plus a free USB3 port pickleboy didn't have). Rather than solve that hardware puzzle, the simplest path won: a direct `scp -r` of the whole `PICTURES` tree from pickleboy to `D:\immich-backup` on Uriah's main Windows PC.

Verified complete by exact match, not just a "did it finish" glance:

| | Source (pickleboy) | `D:\immich-backup` |
|---|---|---|
| Files | 82,492 | 82,492 |
| Bytes | 188,049,601,430 | 188,049,601,430 |

SCP doesn't checksum in flight, so this isn't a byte-hash proof the way the Glacier reconciliation is — but an exact match on both count and total size across 82k files is a strong signal; a dropped or partial transfer would almost certainly show up as a mismatch on at least one.

This was a one-time manual copy, not a script or cron — `scripts/pickleboy-backup-pictures-local.sh` exists in this repo (written and tested against the abandoned USB stick) but is currently unused, since the real copy lives on a different machine entirely. Left in place as a starting point if a drive ever gets attached to pickleboy directly instead.

## The movie backup (Jellyfin → Deep Archive)

Everything from here down documents the movie project — complete, verified, and untouched by the pictures work above.

## Architecture & decisions

Six decisions, locked before anything was built:

1. **Copy, never mirror.** `rclone copy` only adds — a local mistake (deleted file, reorganized folder) can never propagate into the backup. Sidesteps Deep Archive's 180-day early-deletion fee too, since nothing here ever deletes.
2. **Scope: `/mnt/media/STORAGE/MOVIES` and `/mnt/media/STORAGE/SHOWS` only.** Matches the actual workflow — downloads land outside `MOVIES` first as a to-watch queue, then get moved in by hand once watched. Anything still outside those two folders at sync time is automatically excluded.
3. **One bucket, reused: `s3-glacier-test-123456789012-us-west-2-an`, us-west-2.** Verified empty and pre-configured before use: default SSE-S3 encryption with a bucket key, all four public-access-block flags on, no lifecycle rules, no bucket policy. **Object Ownership is `BucketOwnerEnforced` (ACLs disabled)** — this matters, see the acl gotcha below. The original plan reasoned this meant rclone's remote config needed an explicit `acl = unset` line to avoid sending an ACL header at all; that turned out to be backwards (see [Gotchas](#gotchas--lessons-learned)) — the live config has **no** `acl` line at all.
4. **A dedicated IAM user, not SSO.** Static keys, scoped to just this bucket, with **no delete permission of any kind**. Reversed from an earlier "SSO is fine, this is manual/interactive anyway" call once the `AdministratorAccess` permission set's session cap (12 hours, confirmed via `aws sso-admin describe-permission-set`) turned out shorter than the initial upload was likely to take. Local CLI/rclone profile name is `pickleboy-backup`; the underlying IAM username is `pickleboy` — different strings, same credential, worth not conflating. The original `pickleboy` SSO profile stays around for one-time admin actions only (creating this user, changing bucket settings) — it's not what the backup runs under.
5. **Versioning: enabled on the bucket.** Decision 1's copy-only design only protects against *local* deletions propagating outward — it does nothing against a remote-side mistake (an accidental `aws s3 rm --recursive`, a `rclone sync` typed out of habit instead of `copy`). Versioning turns either into a recoverable delete-marker instead of a permanent loss. Costs effectively nothing in practice: this library is write-once with no automated churn, so nothing creates a second version unless a file is deliberately replaced.
6. **No junk-file exclude list.** The catalogued junk (~1,690 files, ~2.2MB) costs a few cents one-time in PUT fees and effectively nothing monthly to just upload — cheaper than maintaining an exclude list that would also silently go stale as new downloads bring differently-named junk it can't catch.

## Setup / how to reproduce

Reflects the **live, working configuration** — corrected in one place from the original build plan (see the acl gotcha below).

1. **Install rclone from the official installer, not apt.** The apt package predates rclone's AWS SDK v2 migration and can't authenticate against SSO or newer credential flows.
   ```bash
   curl https://rclone.org/install.sh | sudo bash
   rclone version   # 1.75.0+
   ```

2. **Create the scoped IAM user and policy** (one-time, via the admin SSO profile):
   ```bash
   aws iam create-user --user-name pickleboy --profile pickleboy
   aws iam put-user-policy \
     --user-name pickleboy \
     --policy-name pickleboy-glacier-bucket-access \
     --policy-document file://policies/iam-policy-glacier-backup.json \
     --profile pickleboy
   aws iam create-access-key --user-name pickleboy --profile pickleboy
   aws configure --profile pickleboy-backup   # paste the key/secret interactively, never inline
   ```
   See [`policies/iam-policy-glacier-backup.json`](policies/iam-policy-glacier-backup.json) for the exact policy — one bucket, no delete permission, plus `GetObject`/`RestoreObject` so the same credential can execute a real restore without a mid-emergency permissions change.

3. **Configure the rclone remote.** The live `~/.config/rclone/rclone.conf`:
   ```ini
   [pickleboy-glacier]
   type = s3
   region = us-west-2
   storage_class = DEEP_ARCHIVE
   chunk_size = 64M
   provider = AWS
   env_auth = true
   no_check_bucket = true
   ```
   Two things worth calling out:
   - **No `acl` line.** The original plan called for an explicit `acl = unset` here — that was wrong (see [Gotchas](#gotchas--lessons-learned)). Omitting the line entirely is what actually works against this `BucketOwnerEnforced` bucket.
   - **`storage_class`/`chunk_size` live in the remote config, not as per-command flags** — every command against `pickleboy-glacier:` defaults to Deep Archive and a 64MB chunk size, so it's structurally impossible to forget on some future hand-typed command. The larger chunk size (rclone's default is 5MB) cut one-time multipart request fees from ~$5.92 to ~$1.14 on the initial upload.

4. **Enable bucket versioning** (one-time, via the admin profile):
   ```bash
   aws s3api put-bucket-versioning \
     --bucket s3-glacier-test-123456789012-us-west-2-an \
     --versioning-configuration Status=Enabled \
     --profile pickleboy
   ```

5. **Verify the scoped user before trusting it** — `test-iam-user.sh` (below).

6. **Run the backup** — `pickleboy-backup.sh` (below).

## Script reference

- **[`scripts/pickleboy-backup.sh`](scripts/pickleboy-backup.sh)** — the actual backup. Two `rclone copy` calls (Movies, then Shows), `--size-only` (avoids a known rclone failure mode against already-archived objects, and skips a slow full-hash comparison on unchanged files), logging to `backup.log`. Additive only — safe to re-run anytime; only transfers what's missing or changed. Long enough to want a `tmux`/`screen` session for the initial run.
  ```bash
  ~/rclone-backups/scripts/pickleboy-backup.sh
  ```

- **[`scripts/verify-backup.sh`](scripts/verify-backup.sh)** — the reconciliation above, as a repeatable 8-check PASS/FAIL run: drive mounted, local vs remote totals, per-file `rclone check` on both legs, full Deep Archive census, versioning, orphaned multipart uploads, top-level prefixes. Read-only and sub-cent. Run it after a backup, not on a schedule.
  ```bash
  ~/rclone-backups/scripts/verify-backup.sh
  ```

- **[`scripts/test-iam-user.sh`](scripts/test-iam-user.sh)** — a 5-check smoke test proving the scoped IAM policy grants exactly what it should before ever pointing rclone at it: list succeeds, put succeeds, read-back succeeds, delete with the scoped profile **fails** (by design), cleanup with the admin profile succeeds. PASS/FAIL output, no dependencies beyond the AWS CLI.
  ```bash
  ~/rclone-backups/scripts/test-iam-user.sh
  ```

## Verification

Run **2026-08-10 ~17:38 PDT**, after the upload completed. Read-only throughout — roughly 15 LIST requests, well under a cent, so it's cheap enough to repeat freely.

| Check | Result |
|---|---|
| MOVIES objects | 7,363 local → 7,363 remote |
| SHOWS objects | 6,566 local → 6,566 remote |
| MOVIES bytes | 3,612,780,382,420 → byte-identical |
| SHOWS bytes | 1,900,911,285,394 → byte-identical |
| `rclone check --one-way --size-only`, both legs | **0 differences**, 13,929 matching files |
| Storage class, all 13,929 objects | 100% `DEEP_ARCHIVE` |
| Bucket versioning | `Enabled` |
| Orphaned multipart uploads | none |
| Top-level prefixes | `MOVIES/`, `SHOWS/` only |

Total 5,513,691,667,814 bytes = **5,135 GiB**, matching the originally measured figure exactly.

Three notes on why the checks are shaped this way:

- **The aggregate byte match alone would not have been sufficient.** A missing file offset by an extra file of the same size would net to zero. The per-file `rclone check` pass is what rules that out; the two together are the actual proof.
- **The storage-class census covers all 13,929 objects, not a sample.** `storage_class` is set once in the remote config, so a single object landing in `STANDARD` would silently break the cost model — Deep Archive is ~$0.99/TB/mo against Standard's ~$23. Worth checking exhaustively precisely because it's a set-and-forget setting.
- **`--size-only` is deliberate, and `--download` must never be used here.** Hash comparison against Deep Archive objects isn't possible without first restoring them, and `--download` would attempt exactly that — turning a sub-cent listing operation into a multi-hundred-dollar retrieval. `HeadObject`-level metadata (which is all a size check needs) is free on archived objects.

Re-verify **after future backup runs, not on a schedule.** Deep Archive doesn't degrade, so a calendar-driven check mostly re-proves this one; new data being uploaded is the event that makes it informative.

## What it costs

| Scenario | Cost |
|---|---|
| Steady-state storage | $5.08/mo · $61.00/yr |
| Year 1, all-in | $62–70 |
| 3 years, all-in | $185–251 |
| Full restore, if ever needed | $494–585 |
| Delete everything, before day 180 | $30.50 |
| Delete everything, after day 180 | $0 |

Full math, reconciliation against earlier estimates, and the case for Deep Archive over B2/Wasabi/Glacier Instant Retrieval: [The Actual Bill](https://claude.ai/code/artifact/7e77bbde-0263-4a76-a0e9-c92833c6becb).

## Restore / disaster-recovery procedure

The scoped IAM user's policy already grants `GetObject` and `RestoreObject` against the whole bucket, so a real emergency doesn't also require a mid-crisis permissions change. Framed honestly:

- **`GetObject`'s authorization path is genuinely permission-tested** — `test-iam-user.sh`'s `head-object` check authorizes against the same path.
- **`RestoreObject` has only ever been granted, never actually exercised.** This procedure is designed and permission-scoped, not drilled end-to-end. Drilling it is not free — a restore incurs a retrieval fee plus a temporary duplicate copy billed at Standard rates — which is the honest reason it hasn't been done, not an oversight.

Mechanically: `HeadObject` (what `rclone check` uses) works on archived objects without restoring anything — only `GetObject` (fetching the actual body) needs a restore first. To pull a file back:
1. `aws s3api restore-object` (or `rclone backend restore`) — standard tier ≈12 hours, bulk tier ≈48 hours before the object is downloadable.
2. Once restored, a normal `GetObject`/download.
3. The retrieval fee and the temporary duplicate copy (billed at Standard rates while it exists) are where most of the restore cost comes from — not the download itself.

## Gotchas & lessons learned

7 known risks surfaced during build and testing — all 7 resolved.

1. **✓ 12-hour SSO sessions would've interrupted a multi-hour upload.** Resolved by Decision 4 — a dedicated scoped IAM user with non-expiring static keys.
2. **✓ An explicit `acl = unset` silently broke every write.** The headline bug — see Decision 3 and the Setup section above. Invisible to three review passes because none of them exercised a real write against the bucket. Fixed by omitting the acl line entirely and adding `no_check_bucket=true`.
3. **✓ Interrupted multipart uploads — drilled, not just documented.** A real upload was killed mid-transfer; confirmed orphaned parts show up via `aws s3api list-multipart-uploads` (invisible to a normal `ls`), clean up via `abort-multipart-upload`, and a re-run completes fine.
4. **✓ Tmux survives a dropped SSH session — checked, not assumed.** Verified tmux's server reparents to PID 1 at creation; a detached upload ran to completion unattended.
5. **✓ Diagnostic test objects left in the bucket.** Leftover `_diag-test/` objects from testing, cleaned up via the admin profile, confirmed via a direct re-list.
6. **✓ "In-place replacement within 180 days" — also effectively free.** Originally assumed re-ripping and re-uploading a file within 180 days would trigger Deep Archive's early-deletion fee on the outgoing version. Backwards: that fee only bills on an *actual, permanent* delete before 180 days. A versioned overwrite just retains the old version as ordinary-billed noncurrent storage — and with no delete permission on this profile and no lifecycle rule expiring noncurrent versions, that fee has no path to ever apply here.
7. **✓ Static keys don't self-expire.** Certificate-based auth (IAM Roles Anywhere) was scoped and priced out — free, but real new infrastructure (a private CA, cert issuance, a signing helper) trading one long-lived secret for another, to fix a property that isn't actually dangerous here: no delete permission and single-bucket scope already bound the blast radius regardless of how long a leak went unnoticed. Declined as disproportionate. Resolved instead with a documented rotation procedure:

   ```
   aws iam create-access-key --user-name pickleboy --profile pickleboy   # new pair; run by hand
   aws configure --profile pickleboy-backup   # paste the new key/secret interactively, never inline
   ./scripts/test-iam-user.sh                                                    # confirm list/put/get pass, delete still denied
   # after one successful backup run on the new key:
   aws iam update-access-key --user-name pickleboy --access-key-id <OLD_ID> --status Inactive --profile pickleboy
   aws iam delete-access-key --user-name pickleboy --access-key-id <OLD_ID> --profile pickleboy
   ```

## Links

- [The full PDF report](reports/pickleboy-glacier-report.pdf) — 30-page designed synthesis of the whole project: sizing, decisions, build, the bug, the upload, the crash, verification, cost, and restore, all in one document
- [The Short Version](https://claude.ai/code/artifact/0d613c39-fef2-4caf-a9dd-306011d44866) — the condensed overview this README complements
- [The Pictures Version](https://claude.ai/code/artifact/3556bf57-e29c-413f-9803-42e06fe95514) — the pictures project's report: decisions, three reviews, deployed state, status (mirrored in `artifacts/the-pictures-version.html`)
- [Every Byte Accounted For](https://claude.ai/code/artifact/3c8069bf-2063-4aec-9613-fd8302d348e8) — verification report: the reconciliation above, why the aggregate totals alone weren't proof, and the `--download` trap
- [The Actual Bill](https://claude.ai/code/artifact/7e77bbde-0263-4a76-a0e9-c92833c6becb) — full cost breakdown & reconciliation
- [The Long Version](https://claude.ai/code/artifact/73bfd878-034e-4c25-a9ae-0972d2490b5c) — full build log & implementation status
- [Media Library Sizing & Compression](https://claude.ai/code/artifact/45ca0117-fe6f-4bec-a4ad-c36d06bc7f0c) — sizing & compression research
- [The Grep That Crashed The Box](https://claude.ai/code/artifact/670c08be-cd8b-4ffc-b5e8-cc3dcc0be256) — incident report, 2026-08-10 double freeze/power-cycle, root-caused to a runaway grep call
