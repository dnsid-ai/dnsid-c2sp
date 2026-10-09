output "witness_url" {
  description = "Base URL to give the log operator."
  value       = module.witness.witness_url
}

output "instance_id" {
  description = "Witness instance (Session Manager target)."
  value       = module.witness.instance_id
}

output "signing_key_secret_arn" {
  description = "Upload the private key here as SecretBinary."
  value       = module.witness.signing_key_secret_arn
}

output "alarm_topic_arn" {
  description = "Subscribe on-call to this topic."
  value       = module.witness.alarm_topic_arn
}

output "archive_bucket_name" {
  description = "Checkpoint archive bucket for the monitor."
  value       = module.witness.archive_bucket_name
}

output "archive_writer_policy_arn" {
  description = "Attach to the monitor's identity."
  value       = module.witness.archive_writer_policy_arn
}

output "log_group_name" {
  description = "Witness container logs."
  value       = module.witness.log_group_name
}
