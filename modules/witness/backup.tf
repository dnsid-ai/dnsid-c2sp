# --- Data volume backups -----------------------------------------------------------
#
# EBS snapshots are crash-consistent. SQLite's journal makes a crash-consistent copy
# recoverable, which is what a restore relies on; the runbook adds an integrity check and
# a comparison against the checkpoint archive before a restored volume serves traffic.

resource "aws_backup_vault" "this" {
  name        = var.name
  kms_key_arn = aws_kms_key.this.arn

  tags = local.tags
}

resource "aws_backup_vault_lock_configuration" "this" {
  count = var.backup_vault_lock_min_retention_days == null ? 0 : 1

  backup_vault_name  = aws_backup_vault.this.name
  min_retention_days = var.backup_vault_lock_min_retention_days
}

resource "aws_backup_plan" "this" {
  name = var.name

  rule {
    rule_name         = "witness-state"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.backup_schedule
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.backup_retention_days
    }

    dynamic "copy_action" {
      for_each = var.backup_copy_vault_arn == null ? [] : [var.backup_copy_vault_arn]
      content {
        destination_vault_arn = copy_action.value

        lifecycle {
          delete_after = var.backup_retention_days
        }
      }
    }
  }

  tags = local.tags
}

resource "aws_iam_role" "backup" {
  name = "${var.name}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_selection" "data" {
  name         = "${var.name}-data"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_ebs_volume.data.arn]
}

# --- Checkpoint archive ------------------------------------------------------------
#
# The hosting requirements call for an append-only archive of the checkpoints the
# witness accepted, outside the witness's write authority. It is the recovery anchor if
# the database is rolled back or lost. This module creates the bucket and a policy for
# the monitor that fills it; the monitor itself runs separately (see the runbook).

# trivy:ignore:AWS-0089 Access to the archive is audited with CloudTrail data events in the account trail, not S3 server access logs.
resource "aws_s3_bucket" "archive" {
  bucket_prefix       = "${var.name}-archive-"
  object_lock_enabled = true

  tags = local.tags
}

resource "aws_s3_bucket_ownership_controls" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    default_retention {
      mode = var.archive_object_lock_mode
      days = var.archive_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.archive]
}

resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # The witness must never be able to touch its own recovery anchor.
        Sid       = "DenyWitnessInstance"
        Effect    = "Deny"
        Principal = { AWS = aws_iam_role.witness.arn }
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.archive]
}

# Attach this policy to the monitor's identity. It can add and read checkpoints but not
# delete them or change their retention.
resource "aws_iam_policy" "archive_writer" {
  name        = "${var.name}-archive-writer"
  description = "Append to and read the C2SP witness checkpoint archive"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListArchive"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.archive.arn
      },
      {
        Sid      = "AppendAndRead"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.archive.arn}/*"
      },
      {
        Sid      = "UseArchiveKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.this.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com" }
        }
      },
    ]
  })

  tags = local.tags
}
