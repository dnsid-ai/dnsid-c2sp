resource "aws_cloudwatch_log_group" "witness" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = local.tags
}

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = aws_kms_key.this.arn

  tags = local.tags
}

resource "aws_sns_topic_policy" "alarms" {
  arn = aws_sns_topic.alarms.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountManage"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:ListSubscriptionsByTopic"]
        Resource  = aws_sns_topic.alarms.arn
      },
      {
        Sid       = "AlarmPublishers"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alarms.arn
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions = [aws_sns_topic.alarms.arn]

  lb_dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.witness.arn_suffix
  }
}

# --- Availability --------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "${var.name}-witness-unavailable"
  alarm_description   = "The witness target has failed load balancer health checks. Checkpoint submissions are failing."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.lb_dimensions
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name}-witness-5xx"
  alarm_description   = "The witness returned 5xx responses in three consecutive five-minute periods."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.lb_dimensions
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "target_4xx" {
  alarm_name          = "${var.name}-witness-4xx"
  alarm_description   = "The witness rejected more requests than usual. Repeated rejections of the log operator's checkpoints can mean an inconsistent log: investigate, never reset state to clear it."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_4XX_Count"
  dimensions          = local.lb_dimensions
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.target_4xx_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "slow_responses" {
  alarm_name          = "${var.name}-witness-slow"
  alarm_description   = "Witness p99 response time is above 5 seconds."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.lb_dimensions
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  alarm_name          = "${var.name}-instance-status"
  alarm_description   = "The witness instance failed an EC2 status check. System failures are auto-recovered; instance failures need an operator."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.witness.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "data_volume_usage" {
  alarm_name          = "${var.name}-data-volume-usage"
  alarm_description   = "The witness data volume is more than 80% full, or the instance stopped reporting usage. Grow the volume before it fills."
  namespace           = local.metric_ns
  metric_name         = "disk_used_percent"
  dimensions          = { InstanceId = aws_instance.witness.id, path = local.data_mount, fstype = "xfs" }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "certificate_expiry" {
  alarm_name          = "${var.name}-certificate-expiry"
  alarm_description   = "The witness TLS certificate expires in under 30 days. ACM renews DNS-validated certificates automatically; check the validation record."
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  dimensions          = { CertificateArn = aws_acm_certificate.this.arn }
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 30
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = local.tags
}

# --- Restarts --------------------------------------------------------------------------

# The witness logs its verifier key on every start, so counting that line counts starts.
resource "aws_cloudwatch_log_metric_filter" "starts" {
  name           = "${var.name}-witness-starts"
  log_group_name = aws_cloudwatch_log_group.witness.name
  pattern        = "\"Witness cosignature/v1 vkey\""

  metric_transformation {
    name          = "WitnessStarts"
    namespace     = local.metric_ns
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "restarted" {
  alarm_name          = "${var.name}-witness-restarted"
  alarm_description   = "The witness process started. Expected after a planned change; otherwise check the logs and confirm the logged vkey matches the published key."
  namespace           = local.metric_ns
  metric_name         = aws_cloudwatch_log_metric_filter.starts.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = local.tags
}

# --- Change and failure events -------------------------------------------------------

locals {
  # Callers may name the secret by name, full ARN or partial ARN.
  secret_id_patterns = [
    aws_secretsmanager_secret.signing_key.name,
    { prefix = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${aws_secretsmanager_secret.signing_key.name}" },
  ]

  event_rules = {
    backup-failed = {
      description = "A backup or copy job for the witness data volume did not complete."
      pattern = {
        source      = ["aws.backup"]
        detail-type = ["Backup Job State Change", "Copy Job State Change"]
        detail = {
          state           = ["FAILED", "ABORTED", "EXPIRED"]
          backupVaultName = [aws_backup_vault.this.name]
        }
      }
    }
    instance-state = {
      description = "The witness instance is stopping, stopped or terminated."
      pattern = {
        source      = ["aws.ec2"]
        detail-type = ["EC2 Instance State-change Notification"]
        detail = {
          state         = ["stopping", "stopped", "shutting-down", "terminated"]
          "instance-id" = [aws_instance.witness.id]
        }
      }
    }
    config-changed = {
      description = "The witness trust-anchor configuration changed."
      pattern = {
        source      = ["aws.ssm"]
        detail-type = ["Parameter Store Change"]
        detail      = { name = [aws_ssm_parameter.config.name] }
      }
    }
    signing-key-changed = {
      description = "The witness signing-key secret was written, changed, scheduled for deletion or had its policy changed."
      pattern = {
        source      = ["aws.secretsmanager"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["secretsmanager.amazonaws.com"]
          eventName = [
            "PutSecretValue", "UpdateSecret", "DeleteSecret", "RestoreSecret",
            "PutResourcePolicy", "DeleteResourcePolicy", "UpdateSecretVersionStage",
            "RotateSecret", "CancelRotateSecret", "ReplicateSecretToRegions",
          ]
          requestParameters = { secretId = local.secret_id_patterns }
        }
      }
    }
    data-volume-changed = {
      description = "The witness data volume was detached or deleted. Expected during a planned instance replacement; otherwise treat it as a possible rollback attempt."
      pattern = {
        source      = ["aws.ec2"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource       = ["ec2.amazonaws.com"]
          eventName         = ["DetachVolume", "DeleteVolume"]
          requestParameters = { volumeId = [aws_ebs_volume.data.id] }
        }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "alerts" {
  for_each = local.event_rules

  name          = "${var.name}-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "alerts" {
  for_each = local.event_rules

  rule = aws_cloudwatch_event_rule.alerts[each.key].name
  arn  = aws_sns_topic.alarms.arn
}

# Reads of the key by anyone except the witness instance. EventBridge delivers read-only
# management events only to rules in this state, and only when a CloudTrail trail
# records read management events.
resource "aws_cloudwatch_event_rule" "signing_key_read" {
  count = var.secret_read_alerts ? 1 : 0

  name        = "${var.name}-signing-key-read"
  description = "The witness signing key was read by a principal other than the witness instance."
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"
  event_pattern = jsonencode({
    source      = ["aws.secretsmanager"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource       = ["secretsmanager.amazonaws.com"]
      eventName         = ["GetSecretValue", "BatchGetSecretValue"]
      requestParameters = { secretId = local.secret_id_patterns }
      # Any caller that is not a session of the witness instance role.
      "$or" = [
        { userIdentity = { type = [{ "anything-but" = "AssumedRole" }] } },
        { userIdentity = { sessionContext = { sessionIssuer = { arn = [{ "anything-but" = aws_iam_role.witness.arn }] } } } },
      ]
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "signing_key_read" {
  count = var.secret_read_alerts ? 1 : 0

  rule = aws_cloudwatch_event_rule.signing_key_read[0].name
  arn  = aws_sns_topic.alarms.arn
}
