#!/usr/bin/env bash

# Reconciles the local Immich originals against what's actually in S3 Glacier IR.
# 8 checks, read-only and cheap - listings only, well under a cent. Safe to
# re-run anytime. Best run after a backup, not on a timer.
#
# NEVER add --download to the rclone check call. Glacier IR would serve the
# bytes without complaint - and bill ~$4 of retrieval plus egress for the
# privilege. For a real hash check, drop --size-only instead: on GIR rclone
# compares MD5s from object metadata with zero download.

BUCKET="s3-glacier-ir-pictures-123456789012-us-west-2"
PROFILE="pickleboy-backup"
LOCAL="/mnt/media/PICTURES"
REMOTE="pickleboy-glacier-ir:$BUCKET"

export AWS_PROFILE="$PROFILE"

echo "=== 1. Pictures drive mounted (everything below is meaningless if not) ==="
mountpoint -q "$LOCAL" \
  && echo "PASS" || { echo "FAIL - $LOCAL is not mounted, aborting"; exit 1; }

echo "=== 2. Local vs remote totals (library/profile expect 1 file, 13 bytes each) ==="
for D in upload library profile thumbs encoded-video; do
  echo "--- $D ---"
  echo "local:  $(find "$LOCAL/$D" -type f | wc -l) files, $(du -sb "$LOCAL/$D" | cut -f1) bytes"
  echo "remote: $(rclone size "$REMOTE/$D" | tr '\n' ' ')"
done
echo "(backups/ not compared here: the bucket keeps dumps the 14-day local window rotates out)"
echo "(thumbs/encoded-video: remote >= local is EXPECTED after Immich regeneration events -"
echo " additive-only keeps superseded derivatives; only local > remote is a problem)"

echo "=== 3. Per-file reconciliation (should report 0 differences) ==="
for D in upload library profile thumbs encoded-video; do
  echo "--- $D ---"
  rclone check "$LOCAL/$D" "$REMOTE/$D" --size-only --one-way --fast-list \
    && echo "PASS" || echo "FAIL"
done

echo "=== 4. Newest dump in bucket is recent (proves the dumps leg is alive) ==="
NEWEST=$(rclone lsf "$REMOTE/backups" | grep '^immich-db-backup-' | sort | tail -1)
STAMP=$(echo "$NEWEST" | sed -nE 's/^immich-db-backup-([0-9]{8})T.*/\1/p')
if [ -n "$NEWEST" ] && [ -n "$STAMP" ]; then
  AGE_DAYS=$(( ( $(date +%s) - $(date -d "$STAMP" +%s) ) / 86400 ))
  [ "$AGE_DAYS" -le 35 ] \
    && echo "PASS ($NEWEST, ${AGE_DAYS} days old)" \
    || echo "FAIL - newest uploaded dump is $AGE_DAYS days old: $NEWEST"
else
  echo "FAIL - no dumps found under backups/"
fi

echo "=== 5. Every object is GLACIER_IR (guards the cost model) ==="
STRAY=$(aws s3api list-objects-v2 --bucket "$BUCKET" \
  --query 'Contents[?StorageClass!=`GLACIER_IR`].[StorageClass,Key]' --output text 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL - aws command failed:"; echo "$STRAY"
elif [ -z "$STRAY" ]; then
  echo "PASS"
else
  echo "FAIL - not in Glacier IR:"; echo "$STRAY"
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

echo "=== 8. Exactly backups/ encoded-video/ library/ profile/ thumbs/ upload/ at top level ==="
PREFIXES=$(aws s3api list-objects-v2 --bucket "$BUCKET" --delimiter '/' \
  --query 'CommonPrefixes[].Prefix' --output text 2>&1)
RC=$?
SORTED=$(echo "$PREFIXES" | tr '\t' '\n' | sort | tr '\n' ' ')
if [ $RC -ne 0 ]; then
  echo "FAIL - aws command failed:"; echo "$PREFIXES"
elif [ "$SORTED" = "backups/ encoded-video/ library/ profile/ thumbs/ upload/ " ]; then
  echo "PASS"
else
  echo "FAIL - unexpected top-level prefixes: $SORTED"
fi

echo "=== Done ==="
