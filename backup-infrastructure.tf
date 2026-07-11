##############################################################################
# Disaster Recovery — AWS Backup Infrastructure
#
# Covers: RDS, EBS, EFS via AWS Backup (native snapshot orchestration)
# Plus:   S3 backup bucket for logical dumps produced by scripts/db_backup.sh
#
# Apply with: terraform init && terraform plan && terraform apply
##############################################################################

variable "aws_region" {
  default = "us-east-1"
}

variable "dr_region" {
  description = "Secondary region for cross-region backup copies"
  default     = "us-west-2"
}

variable "backup_resource_tag_key" {
  description = "Resources tagged with this key=value are auto-included in backup plan"
  default     = "Backup"
}

variable "backup_resource_tag_value" {
  default = "true"
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
}

##############################################################################
# KMS keys for encrypting backups (separate from source resource keys, so a
# compromised primary key doesn't also compromise backups)
##############################################################################
resource "aws_kms_key" "backup_key" {
  description             = "KMS key for AWS Backup vault encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_key" "backup_key_dr" {
  provider                = aws.dr
  description             = "KMS key for DR-region AWS Backup vault"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

##############################################################################
# Backup vaults (primary + DR region)
##############################################################################
resource "aws_backup_vault" "primary" {
  name        = "primary-backup-vault"
  kms_key_arn = aws_kms_key.backup_key.arn
}

resource "aws_backup_vault" "dr" {
  provider    = aws.dr
  name        = "dr-backup-vault"
  kms_key_arn = aws_kms_key.backup_key_dr.arn
}

# Vault lock prevents deletion/tampering of backups even by admins — critical
# defense against ransomware scenarios where credentials are compromised.
resource "aws_backup_vault_lock_configuration" "primary_lock" {
  backup_vault_name  = aws_backup_vault.primary.name
  changeable_for_days = 3
  max_retention_days  = 365
  min_retention_days  = 7
}

##############################################################################
# Backup plan: tiered retention (daily / weekly / monthly)
##############################################################################
resource "aws_backup_plan" "main" {
  name = "dr-backup-plan"

  rule {
    rule_name         = "daily_backups"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 3 * * ? *)" # 03:00 UTC daily
    start_window      = 60                  # minutes
    completion_window = 180

    lifecycle {
      delete_after = 35 # days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle {
        delete_after = 35
      }
    }
  }

  rule {
    rule_name         = "weekly_backups"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 4 ? * SUN *)" # Sunday 04:00 UTC
    start_window      = 60
    completion_window = 240

    lifecycle {
      cold_storage_after = 30
      delete_after        = 180
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle {
        cold_storage_after = 30
        delete_after        = 180
      }
    }
  }

  rule {
    rule_name         = "monthly_backups"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 5 1 * ? *)" # 1st of month, 05:00 UTC
    start_window      = 60
    completion_window = 300

    lifecycle {
      cold_storage_after = 30
      delete_after        = 2555 # ~7 years, adjust to compliance requirements
    }
  }
}

##############################################################################
# Selection: which resources get backed up (tag-based — tag anything you
# want covered with Backup=true rather than hardcoding ARNs)
##############################################################################
resource "aws_iam_role" "backup_role" {
  name = "aws-backup-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "backup.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup_policy" {
  role       = aws_iam_role.backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore_policy" {
  role       = aws_iam_role.backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_selection" "tagged_resources" {
  name         = "tagged-for-backup"
  iam_role_arn = aws_iam_role.backup_role.arn
  plan_id      = aws_backup_plan.main.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_resource_tag_key
    value = var.backup_resource_tag_value
  }
}

##############################################################################
# S3 bucket for logical DB dumps (from scripts/db_backup.sh)
##############################################################################
resource "aws_s3_bucket" "db_backups" {
  bucket = "my-org-db-backups"
}

resource "aws_s3_bucket_versioning" "db_backups_versioning" {
  bucket = aws_s3_bucket.db_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "db_backups_sse" {
  bucket = aws_s3_bucket.db_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup_key.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "db_backups_block" {
  bucket                  = aws_s3_bucket.db_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Object lock = immutability. Combined with vault lock above, this protects
# against both accidental deletion and malicious/ransomware deletion.
resource "aws_s3_bucket_object_lock_configuration" "db_backups_lock" {
  bucket = aws_s3_bucket.db_backups.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 35
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "db_backups_lifecycle" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    id     = "tiered-retention"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "db_backups_cross_region" {
  bucket = aws_s3_bucket.db_backups.id
  role   = aws_iam_role.s3_replication_role.arn

  rule {
    id     = "cross-region-dr-copy"
    status = "Enabled"
    destination {
      bucket        = aws_s3_bucket.db_backups_dr.arn
      storage_class = "STANDARD_IA"
    }
  }

  depends_on = [aws_s3_bucket_versioning.db_backups_versioning]
}

resource "aws_s3_bucket" "db_backups_dr" {
  provider = aws.dr
  bucket   = "my-org-db-backups-dr"
}

resource "aws_s3_bucket_versioning" "db_backups_dr_versioning" {
  provider = aws.dr
  bucket   = aws_s3_bucket.db_backups_dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_iam_role" "s3_replication_role" {
  name = "s3-backup-replication-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
    }]
  })
}

##############################################################################
# Alerting: notify on backup job failure
##############################################################################
resource "aws_sns_topic" "backup_alerts" {
  name = "dr-backup-alerts"
}

resource "aws_backup_vault_notifications" "primary_notifications" {
  backup_vault_name  = aws_backup_vault.primary.name
  sns_topic_arn      = aws_sns_topic.backup_alerts.arn
  backup_vault_events = [
    "BACKUP_JOB_FAILED",
    "RESTORE_JOB_FAILED",
    "COPY_JOB_FAILED",
  ]
}

output "primary_vault_name" {
  value = aws_backup_vault.primary.name
}

output "dr_vault_name" {
  value = aws_backup_vault.dr.name
}

output "db_backups_bucket" {
  value = aws_s3_bucket.db_backups.bucket
}
