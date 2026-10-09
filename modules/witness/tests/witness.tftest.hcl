# Plan-only tests against a mocked AWS provider: no credentials, no resources.

mock_provider "aws" {
  # Mocked attributes (ARNs, IDs) are available while planning.
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "us-east-1a" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/c2sp-witness-instance" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::c2sp-witness-archive-x" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:c2sp-witness/signing-key-AbCdEf" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-east-1:111111111111:parameter/c2sp-witness/config.yaml" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:/c2sp-witness/witness" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111111111111:c2sp-witness-alarms" }
  }
  mock_resource "aws_ebs_volume" {
    defaults = {
      id  = "vol-0123456789abcdef0"
      arn = "arn:aws:ec2:us-east-1:111111111111:volume/vol-0123456789abcdef0"
    }
  }
  mock_resource "aws_wafv2_ip_set" {
    defaults = { arn = "arn:aws:wafv2:us-east-1:111111111111:regional/ipset/x/00000000-0000-0000-0000-000000000000" }
  }
}

variables {
  vpc_id              = "vpc-0123456789abcdef0"
  alb_subnet_ids      = ["subnet-0000000000000000a", "subnet-0000000000000000b"]
  instance_subnet_id  = "subnet-0000000000000000c"
  domain_name         = "witness.example.org"
  route53_zone_id     = "Z0000000000000000000"
  witness_image       = "registry.example.org/witness@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  witness_config_yaml = <<-EOT
    logs:
      - origin: example.org/log
        public_key: "example.org/log+00000000+AQ=="
        url: https://log.example.org/
  EOT
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_instance.witness.metadata_options[0].http_tokens == "required" && aws_instance.witness.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required with a hop limit of 1."
  }

  assert {
    condition     = aws_instance.witness.associate_public_ip_address == false
    error_message = "The witness instance must not have a public IP."
  }

  assert {
    condition     = aws_ebs_volume.data.encrypted && aws_ebs_volume.data.availability_zone == "us-east-1a"
    error_message = "The data volume must be encrypted and in the instance subnet's AZ."
  }

  assert {
    condition     = aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "The instance must stop before its data volume detaches."
  }

  assert {
    condition     = aws_lb_listener.https.default_action[0].type == "fixed-response"
    error_message = "Unrouted paths, including /healthz, must not reach the witness."
  }

  assert {
    condition     = length(aws_wafv2_ip_set.add_checkpoint) == 0 && length(aws_wafv2_ip_set.read) == 0
    error_message = "No allowlists are created by default."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 2
    error_message = "By default the WAF has only the body-size and rate-limit rules."
  }

  assert {
    condition     = length(aws_backup_plan.this.rule) == 1 && aws_s3_bucket.archive.object_lock_enabled
    error_message = "Backups and the Object Lock archive must be on."
  }

  assert {
    condition     = !strcontains(jsonencode(jsondecode(aws_iam_role_policy.witness.policy).Statement), "ecr:")
    error_message = "No ECR permissions without ecr_repository_arns."
  }

  assert {
    condition     = output.witness_url == "https://witness.example.org/"
    error_message = "Unexpected witness URL."
  }
}

run "allowlists" {
  command = plan

  variables {
    add_checkpoint_allowed_cidrs = ["192.0.2.0/24"]
    read_allowed_cidrs           = ["198.51.100.0/24"]
    ecr_repository_arns          = ["arn:aws:ecr:us-east-1:111111111111:repository/witness"]
    witness_image                = "111111111111.dkr.ecr.us-east-1.amazonaws.com/witness@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 4
    error_message = "Both allowlist rules must be added."
  }

  assert {
    condition     = local.image_is_ecr
    error_message = "An ECR image must be detected as such."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.witness.policy, "ecr:BatchGetImage")
    error_message = "ECR pull permissions must be granted when repositories are given."
  }
}

run "rejects_tag_only_image" {
  command = plan

  variables {
    witness_image = "registry.example.org/c2sp-ledger-witness:v1.0.0"
  }

  expect_failures = [var.witness_image]
}

run "rejects_ipv6_allowlist" {
  command = plan

  variables {
    add_checkpoint_allowed_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.add_checkpoint_allowed_cidrs]
}

run "rejects_empty_config" {
  command = plan

  variables {
    witness_config_yaml = "logs: []\n"
  }

  expect_failures = [var.witness_config_yaml]
}
