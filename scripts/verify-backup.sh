#!/usr/bin/env bash

# Reconciles the local Jellyfin library against what's actually in Glacier.
# 8 checks, read-only and cheap - listings only, well under a cent. Safe to
# re-run anytime. Best run after a backup, not on a timer: Deep Archive
# doesn't rot, so a calendar-driven check just re-proves the last one.
#
# NEVER add --download to the rclone check calls. Hashes can't be compared
# against archived objects without restoring them first, and --download would
# try exactly that - turning this into a multi-hundred-dollar retrieval.
# --size-only is the point.

BUCKET="s3-glacier-test-123456789012-us-west-2-an"
PROFILE="pickleboy-backup"
LOCAL="/mnt/media/STORAGE"
REMOTE="pickleboy-glacier:$BUCKET"

export AWS_PROFILE="$PROFILE"

echo "=== 1. Media drive mounted (everything below is meaningless if not) ==="
mountpoint -q "$LOCAL" \
  && echo "PASS" || { echo "FAIL - $LOCAL is not mounted, aborting"; exit 1; }

echo "=== 2. Local vs remote totals ==="
for D in MOVIES SHOWS; do
  echo "--- $D ---"
  echo "local:  $(find "$LOCAL/$D" -type f | wc -l) files, $(du -sb "$LOCAL/$D" | cut -f1) bytes"
  echo "remote: $(rclone size "$REMOTE/$D" | tr '\n' ' ')"
done

echo "=== 3. Per-file reconciliation, MOVIES (should report 0 differences) ==="
rclone check "$LOCAL/MOVIES" "$REMOTE/MOVIES" --size-only --one-way \
  && echo "PASS" || echo "FAIL"

echo "=== 4. Per-file reconciliation, SHOWS (should report 0 differences) ==="
rclone check "$LOCAL/SHOWS" "$REMOTE/SHOWS" --size-only --one-way \
  && echo "PASS" || echo "FAIL"

echo "=== 5. Every object is DEEP_ARCHIVE (guards the cost model) ==="
STRAY=$(aws s3api list-objects-v2 --bucket "$BUCKET" \
  --query 'Contents[?StorageClass!=`DEEP_ARCHIVE`].[StorageClass,Key]' --output text 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL - aws command failed:"; echo "$STRAY"
elif [ -z "$STRAY" ]; then
  echo "PASS"
else
  echo "FAIL - not in Deep Archive:"; echo "$STRAY"
fi

echo "=== 6. Bucket versioning still enabled ==="
VER=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text)
[ "$VER" = "Enabled" ] && echo "PASS" || echo "FAIL - versioning is '$VER'"

echo "=== 7. No orphaned multipart uploads (they bill as storage, invisible to ls) ==="
MPU=$(aws s3api list-multipart-uploads --bucket "$BUCKET" \
  --query 'Uploads[].[Initiated,Key]' --output text 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL - aws command failed:"; echo "$MPU"
elif [ -z "$MPU" ] || [ "$MPU" = "None" ]; then
  echo "PASS"
else
  echo "FAIL - orphaned uploads, abort them with: aws s3api abort-multipart-upload"
  echo "$MPU"
fi

echo "=== 8. Only MOVIES/ and SHOWS/ at top level (no stray prefixes) ==="
PREFIXES=$(aws s3api list-objects-v2 --bucket "$BUCKET" --delimiter '/' \
  --query 'CommonPrefixes[].Prefix' --output text 2>&1)
RC=$?
SORTED=$(echo "$PREFIXES" | tr '\t' '\n' | sort | tr '\n' ' ')
if [ $RC -ne 0 ]; then
  echo "FAIL - aws command failed:"; echo "$PREFIXES"
elif [ "$SORTED" = "MOVIES/ SHOWS/ " ]; then
  echo "PASS"
else
  echo "FAIL - unexpected top-level prefixes: $SORTED"
fi

echo "=== Done ==="
