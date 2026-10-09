# --- Signing key and configuration -------------------------------------------

# Terraform creates only the secret container. The private key is generated inside the
# operator's trust boundary and uploaded out of band (see the runbook), so it never
# appears in Terraform state or plans.
resource "aws_secretsmanager_secret" "signing_key" {
  name                    = "${var.name}/signing-key"
  description             = "C2SP witness private signing key (SecretBinary). Uploaded out of band; never managed by Terraform."
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 30

  tags = local.tags
}

resource "aws_ssm_parameter" "config" {
  name        = "/${var.name}/config.yaml"
  description = "C2SP witness log configuration (trust anchors). Read by the instance at every witness start."
  type        = "String"
  tier        = "Standard"
  value       = var.witness_config_yaml

  tags = local.tags
}

# --- Instance role -------------------------------------------------------------

resource "aws_iam_role" "witness" {
  name = "${var.name}-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_instance_profile" "witness" {
  name = "${var.name}-instance"
  role = aws_iam_role.witness.name

  tags = local.tags
}

# Session Manager is the only administrative path: no SSH key, no inbound admin port.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.witness.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "witness" {
  name = "witness-runtime"
  role = aws_iam_role.witness.id

  # The role can read its key and config and write its logs and metrics. It has no
  # permission to snapshot, detach, delete or replace its own data volume.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadSigningKey"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = aws_secretsmanager_secret.signing_key.arn
        },
        {
          Sid      = "ReadConfig"
          Effect   = "Allow"
          Action   = "ssm:GetParameter"
          Resource = aws_ssm_parameter.config.arn
        },
        {
          Sid      = "DecryptKeyViaSecretsManager"
          Effect   = "Allow"
          Action   = "kms:Decrypt"
          Resource = aws_kms_key.this.arn
          Condition = {
            StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" }
          }
        },
        {
          Sid      = "WriteWitnessLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
          Resource = "${aws_cloudwatch_log_group.witness.arn}:*"
        },
        {
          Sid      = "PublishDiskMetrics"
          Effect   = "Allow"
          Action   = "cloudwatch:PutMetricData"
          Resource = "*"
          Condition = {
            StringEquals = { "cloudwatch:namespace" = local.metric_ns }
          }
        },
      ],
      [for st in [
        {
          Sid      = "EcrLogin"
          Effect   = "Allow"
          Action   = "ecr:GetAuthorizationToken"
          Resource = "*"
        },
        {
          Sid      = "EcrPull"
          Effect   = "Allow"
          Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
          Resource = var.ecr_repository_arns
        },
      ] : st if length(var.ecr_repository_arns) > 0],
    )
  })
}

# --- Security groups -------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "C2SP witness load balancer"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere; per-route source limits are enforced by the WAF"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_witness" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to the witness"
  ip_protocol                  = "tcp"
  from_port                    = local.witness_port
  to_port                      = local.witness_port
  referenced_security_group_id = aws_security_group.instance.id
}

resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "C2SP witness instance"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-instance" })
}

resource "aws_vpc_security_group_ingress_rule" "witness_from_alb" {
  security_group_id            = aws_security_group.instance.id
  description                  = "Witness port from the load balancer only"
  ip_protocol                  = "tcp"
  from_port                    = local.witness_port
  to_port                      = local.witness_port
  referenced_security_group_id = aws_security_group.alb.id
}

# trivy:ignore:AWS-0104 The default reaches the registry and AWS APIs through NAT; instance_egress_cidrs narrows it.
resource "aws_vpc_security_group_egress_rule" "instance_https" {
  for_each = toset(var.instance_egress_cidrs)

  security_group_id = aws_security_group.instance.id
  description       = "HTTPS to the image registry, package repositories and AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}
