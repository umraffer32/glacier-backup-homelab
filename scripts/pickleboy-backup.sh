#!/usr/bin/env bash


# Pickleboy media -> S3 Glacier Deep Archive. Additive only; safe to re-run anytime.
# Uses a scoped IAM user — no login step, no credential expiry to worry about.
# Initial 5.1TB run: start inside tmux/screen; if interrupted (network blip, laptop
# closed), just re-run — rclone copy only transfers what's missing.
# Mountpoint guard matters even for a manual run: an unmounted drive resolves to an
# empty dir on the root SSD, and against a now-static library "0 transferred" is what
# a HEALTHY re-run looks like too - only the guard tells those two states apart.


LOG="$HOME/rclone-backups/backup.log"

mountpoint -q /mnt/media/STORAGE || { echo "=== run ABORTED $(date '+%F %T') - /mnt/media/STORAGE not mounted ===" >> "$LOG"; echo "FAIL - /mnt/media/STORAGE not mounted, aborting"; exit 1; }

export AWS_PROFILE=pickleboy-backup
RC=0

echo "=== run start $(date '+%F %T') ===" >> "$LOG"

rclone copy /mnt/media/STORAGE/MOVIES pickleboy-glacier:s3-glacier-test-123456789012-us-west-2-an/MOVIES \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

rclone copy /mnt/media/STORAGE/SHOWS pickleboy-glacier:s3-glacier-test-123456789012-us-west-2-an/SHOWS \
  --size-only --progress --log-level INFO --log-file "$LOG" || RC=1

echo "=== run end $(date '+%F %T') status=$RC ===" >> "$LOG"
exit $RC
