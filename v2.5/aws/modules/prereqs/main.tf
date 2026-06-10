# prereqs — VPC-independent data-plane dependencies shared by all application
# instances:
#
#   * a customer-managed symmetric KMS key (the envelope-encryption KEK, also
#     applied as the SSE-KMS key on every S3 object the app writes),
#   * a single S3 bucket (instances are separated by key prefix), and
#   * an IAM policy granting access to exactly those two resources, to be
#     attached to the application role your compute configuration creates.
#
# The KMS key is the deployment's most critical secret — losing it makes every
# encrypted Postgres column unrecoverable. Rotation is on; deletion is delayed.

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS — shared KEK + SSE-KMS key
# ---------------------------------------------------------------------------
resource "aws_kms_key" "main" {
  description             = "Sema4.ai self-hosted KEK + S3 SSE for ${var.infra_id}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false

  tags = var.tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.infra_id}"
  target_key_id = aws_kms_key.main.key_id
}

# Key policy delegates to IAM (account root). The app role's IAM policy below
# grants the actual data-plane key permissions; SSE-KMS on S3 uses the same key.
data "aws_iam_policy_document" "kms" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # EKS managed node groups launch instances through an Auto Scaling group; for
  # the nodes' CMK-encrypted root EBS volumes, the Auto Scaling service-linked
  # role must be able to use the key and create grants for the launched
  # resources. Without this, node launches fail. The role is auto-created the
  # first time Auto Scaling is used in the account.
  statement {
    sid    = "AllowAutoScalingUseOfKey"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowAutoScalingGrantForAWSResources"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key_policy" "main" {
  key_id = aws_kms_key.main.id
  policy = data.aws_iam_policy_document.kms.json
}

# ---------------------------------------------------------------------------
# S3 — shared bucket (per-instance key prefix)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "main" {
  bucket = "${var.infra_id}-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "expire-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.main.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------
# IAM — application access policy, scoped to exactly the bucket and key above.
#
# Deliberately a standalone policy, not a role: a role cannot exist without a
# trust policy, and trust is compute-specific (EKS Pod Identity, ECS task
# role, EC2 instance profile, IRSA, ...). Create the application role with the
# trust your platform needs as part of your compute configuration and attach
# this policy to it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "app" {
  statement {
    sid    = "S3Objects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }

  statement {
    sid       = "S3List"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.main.arn]
  }

  statement {
    sid    = "KmsEnvelopeAndSse"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_policy" "app" {
  name   = "${var.infra_id}-app-s3-kms"
  policy = data.aws_iam_policy_document.app.json
  tags   = var.tags
}
