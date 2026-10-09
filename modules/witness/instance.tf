# The SQLite database lives on its own volume so that the instance can be replaced
# (patching, image upgrades) without touching witness state. An EBS volume attaches to
# one instance at a time, which is what keeps this a single-writer service.
resource "aws_ebs_volume" "data" {
  availability_zone = local.availability_zone
  type              = "gp3"
  size              = var.data_volume_size_gib
  encrypted         = true
  kms_key_id        = aws_kms_key.this.arn

  tags = merge(local.tags, {
    Name                    = "${var.name}-data"
    "c2sp-witness/role"     = "state"
    "c2sp-witness/instance" = var.name
  })

  # Losing or rolling back this volume is a security event, not an outage. Terraform
  # refuses to destroy it; see the runbook for decommissioning and restores.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "witness" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.instance_subnet_id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.witness.name
  associate_public_ip_address = false
  monitoring                  = true

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region           = local.region
    volume_id        = aws_ebs_volume.data.id
    data_mount       = local.data_mount
    witness_image    = var.witness_image
    image_is_ecr     = local.image_is_ecr
    witness_port     = local.witness_port
    secret_arn       = aws_secretsmanager_secret.signing_key.arn
    config_parameter = aws_ssm_parameter.config.name
    log_group_name   = aws_cloudwatch_log_group.witness.name
    metric_namespace = local.metric_ns
  }))
  # A new image, volume or boot script means a new instance. The old one is stopped
  # before its data volume is detached, so two witnesses never run against one database.
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # A hop limit of 1 keeps the container (one network hop further) away from the
    # instance credentials.
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  maintenance_options {
    auto_recovery = "default"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    kms_key_id            = aws_kms_key.this.arn
    delete_on_termination = true
    # Not volume_tags: that would also rewrite the separately managed data volume's tags.
    tags = merge(local.tags, { Name = "${var.name}-root" })
  }

  tags = merge(local.tags, { Name = var.name })

  lifecycle {
    # New Amazon Linux releases must not silently replace the witness. Patch on
    # purpose with -replace (see the runbook).
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.witness.id

  # Stop the instance (and so the witness) before detaching, so SQLite is closed cleanly.
  stop_instance_before_detaching = true
}
