#!/usr/bin/env bash
# Tests the scoped IAM user against the pictures (Glacier IR) bucket - proves the
# new pickleboy-glacier-ir-bucket-access policy grants what it should and blocks
# what it shouldn't. Plain S3 calls are enough; no rclone needed yet.

BUCKET="s3-glacier-ir-pictures-123456789012-us-west-2"
SCOPED_PROFILE="pickleboy-backup"
ADMIN_PROFILE="pickleboy"
KEY="iam-test.txt"

echo "=== 1. List bucket (should succeed) ==="
aws s3 ls "s3://$BUCKET" --profile "$SCOPED_PROFILE" \
  && echo "PASS" || echo "FAIL"

echo "=== 2. Upload a test object (should succeed) ==="
echo "pickleboy iam test $(date)" | aws s3 cp - "s3://$BUCKET/$KEY" --profile "$SCOPED_PROFILE" \
  && echo "PASS" || echo "FAIL"

echo "=== 3. Read it back (should succeed) ==="
aws s3api head-object --bucket "$BUCKET" --key "$KEY" --profile "$SCOPED_PROFILE" \
  && echo "PASS" || echo "FAIL"

echo "=== 4. Delete with the scoped user (should FAIL - no delete permission, by design) ==="
aws s3 rm "s3://$BUCKET/$KEY" --profile "$SCOPED_PROFILE" \
  && echo "FAIL (delete should have been denied)" || echo "PASS (delete correctly denied)"

echo "=== 5. Clean up with the admin profile instead (should succeed) ==="
aws s3 rm "s3://$BUCKET/$KEY" --profile "$ADMIN_PROFILE" \
  && echo "PASS" || echo "FAIL"

echo "=== Done ==="
