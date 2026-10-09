output "witness_url" {
  description = "Base URL to give the log operator. Submitters append /add-checkpoint."
  value       = "https://${var.domain_name}/"
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "instance_id" {
  description = "EC2 instance running the witness. Connect with Session Manager."
  value       = aws_instance.witness.id
}

output "data_volume_id" {
  description = "EBS volume holding the witness SQLite database."
  value       = aws_ebs_volume.data.id
}

output "signing_key_secret_arn" {
  description = "Secrets Manager secret that must hold the private signing key as SecretBinary. Upload it out of band."
  value       = aws_secretsmanager_secret.signing_key.arn
}

output "config_parameter_name" {
  description = "SSM parameter holding the witness config.yaml."
  value       = aws_ssm_parameter.config.name
}

output "log_group_name" {
  description = "CloudWatch log group with the witness container logs."
  value       = aws_cloudwatch_log_group.witness.name
}

output "alarm_topic_arn" {
  description = "SNS topic every alarm and alert publishes to. Subscribe your on-call channel."
  value       = aws_sns_topic.alarms.arn
}

output "backup_vault_name" {
  description = "AWS Backup vault holding data volume recovery points."
  value       = aws_backup_vault.this.name
}

output "archive_bucket_name" {
  description = "Object Lock bucket for the independent checkpoint archive."
  value       = aws_s3_bucket.archive.id
}

output "archive_writer_policy_arn" {
  description = "IAM policy to attach to the checkpoint monitor's identity."
  value       = aws_iam_policy.archive_writer.arn
}

output "kms_key_arn" {
  description = "KMS key that encrypts the module's data."
  value       = aws_kms_key.this.arn
}
