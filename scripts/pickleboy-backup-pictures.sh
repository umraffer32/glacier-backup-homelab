#!/usr/bin/env bash


# Immich library (full tree minus lost+found) -> S3 Glacier Instant Retrieval.
# Additive only; safe to re-run anytime.
# Runs unattended from cron (monthly, 30 3 1 * *), which is why the mountpoint guard
# below matters: an unmounted drive resolves to an empty dir on the root SSD, and with
# a static library "0 transferred" is what a HEALTHY run looks like - only the guard
# tells those two states apart. The run start/end lines are the only trace cron leaves.
# Note: cron's PATH has rclone (/usr/bin) but NOT aws (/usr/local/bin) - keep this rclone-only.


LOG="$HOME/rclone-backups/pictures-backup.log"

mountpoint -q /mnt/media/PICTURES || { echo "=== run ABORTED $(date '+%F %T') - /mnt/media/PICTURES not mounted ===" >> "$LOG"; echo "FAIL - /mnt/media/PICTURES not mounted, aborting"; exit 1; }

export AWS_PROFILE=pickleboy-backup
REMOTE="pickleboy-glacier-ir:s3-glacier-ir-pictures-123456789012-us-west-2"
RC=0

echo "=== run start $(date '+%F %T') ===" >> "$LOG"

# --fast-list is load-bearing here: upload/ fans out into 33k+ dirs, and the default
# per-directory walk would cost ~23,000 LIST requests per run vs ~27 with it.
# --min-age 1m skips files Immich is mid-write on.
rclone copy /mnt/media/PICTURES/upload "$REMOTE/upload" \
  --fast-list --transfers 16 --min-age 1m \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

rclone copy /mnt/media/PICTURES/library "$REMOTE/library" \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

rclone copy /mnt/media/PICTURES/profile "$REMOTE/profile" \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

# thumbs/ and encoded-video/ share upload/'s hash-bucket fan-out, so --fast-list
# matters here too; both are Immich-job-written, so --min-age guards mid-write files.
rclone copy /mnt/media/PICTURES/thumbs "$REMOTE/thumbs" \
  --fast-list --transfers 16 --min-age 1m \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

rclone copy /mnt/media/PICTURES/encoded-video "$REMOTE/encoded-video" \
  --fast-list --transfers 16 --min-age 1m \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

# Newest 1-2 dumps only; the bucket keeps what the 14-day local window rotates out.
rclone copy /mnt/media/PICTURES/backups "$REMOTE/backups" --max-age 48h --min-age 1m \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

echo "=== run end $(date '+%F %T') status=$RC ===" >> "$LOG"
exit $RC
