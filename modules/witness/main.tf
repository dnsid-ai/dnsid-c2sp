data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_subnet" "instance" {
  id = var.instance_subnet_id
}

data "aws_ssm_parameter" "al2023_ami" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.instance_architecture}"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  ami_id            = coalesce(var.ami_id, try(nonsensitive(data.aws_ssm_parameter.al2023_ami[0].value), null))
  availability_zone = data.aws_subnet.instance.availability_zone

  # The witness listens on plain HTTP inside the VPC; TLS ends at the load balancer.
  witness_port = 7667

  # Mount point on the instance; the container sees <mount>/db as /data.
  data_mount = "/var/lib/witness"

  log_group_name = "/${var.name}/witness"
  metric_ns      = "C2SPWitness"

  # The image is pulled with ECR credentials only when it lives in a private ECR registry.
  image_is_ecr = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/", var.witness_image))

  tags = merge(var.tags, {
    "c2sp-witness/name" = var.name
  })
}

# One customer managed key encrypts the data volume, root volume, signing-key secret,
# logs, alarm topic, backups and checkpoint archive.
resource "aws_kms_key" "this" {
  description             = "${var.name} C2SP witness data"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_key_deletion_window_days

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"
          }
        }
      },
      {
        # CloudWatch alarms and EventBridge rules publish to the encrypted alarm topic.
        Sid       = "AlarmPublishers"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
