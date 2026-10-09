variable "name" {
  description = "Name prefix for every resource. Lowercase letters, digits and hyphens; it must be unique in the account and region."
  type        = string
  default     = "c2sp-witness"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}[a-z0-9]$", var.name))
    error_message = "name must be 2-24 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Tags added to every resource that supports them."
  type        = map(string)
  default     = {}
}

# --- Network ---------------------------------------------------------------

variable "vpc_id" {
  description = "VPC that hosts the load balancer and the witness instance."
  type        = string
}

variable "alb_subnet_ids" {
  description = "Public subnets for the internet-facing load balancer, in at least two Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.alb_subnet_ids) >= 2
    error_message = "An Application Load Balancer needs subnets in at least two Availability Zones."
  }
}

variable "instance_subnet_id" {
  description = "Private subnet for the witness instance. It needs outbound HTTPS (NAT gateway or VPC endpoints) to reach the image registry, package repositories and AWS APIs. The data volume is created in this subnet's Availability Zone."
  type        = string
}

variable "instance_egress_cidrs" {
  description = "IPv4 CIDRs the instance may reach on port 443 (image registry, package repositories, AWS APIs). Narrow it if you route those through VPC endpoints or a proxy."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.instance_egress_cidrs) > 0 && alltrue([for c in var.instance_egress_cidrs : can(cidrnetmask(c))])
    error_message = "instance_egress_cidrs must contain at least one IPv4 CIDR block."
  }
}

# --- Public endpoint -------------------------------------------------------

variable "domain_name" {
  description = "Public hostname of the witness, for example witness.example.org. Log operators submit checkpoints to https://<domain_name>/add-checkpoint."
  type        = string
}

variable "route53_zone_id" {
  description = "Public Route 53 hosted zone that contains domain_name. The module creates the ACM validation records and an alias record in it."
  type        = string
}

variable "add_checkpoint_allowed_cidrs" {
  description = "IPv4 CIDRs allowed to send POST requests (only POST /add-checkpoint is routed). Empty allows any source: nobody can forge a checkpoint, but anyone holding a validly signed one can submit it and use capacity. Ask the log operator for its egress CIDRs."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.add_checkpoint_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "add_checkpoint_allowed_cidrs must contain IPv4 CIDR blocks."
  }
}

variable "read_allowed_cidrs" {
  description = "IPv4 CIDRs allowed to send non-POST requests (GET /vkey and /<origin-hash>/checkpoint). Empty (the default) keeps the read endpoints public, which lets third parties observe what the witness accepted."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.read_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "read_allowed_cidrs must contain IPv4 CIDR blocks."
  }
}

variable "rate_limit_per_5_minutes" {
  description = "Requests a single source IP may make in a five-minute window before the WAF blocks it."
  type        = number
  default     = 300

  validation {
    condition     = var.rate_limit_per_5_minutes >= 10
    error_message = "AWS WAF rate-based rules need a limit of at least 10."
  }
}

variable "alb_deletion_protection" {
  description = "Enable deletion protection on the load balancer. Disable it only to decommission the witness."
  type        = bool
  default     = true
}

variable "alb_access_logs" {
  description = "Optional S3 bucket (and prefix) for load balancer access logs. Prefer a bucket outside this account so the workload cannot alter its own logs. The bucket must use SSE-S3 and allow ELB log delivery."
  type = object({
    bucket = string
    prefix = optional(string, "")
  })
  default = null
}

# --- Witness workload ------------------------------------------------------

variable "witness_image" {
  description = "Witness container image pinned by digest, for example registry.example.org/c2sp-ledger-witness@sha256:<64 hex>. Tags alone are rejected so that what runs is exactly what you reviewed."
  type        = string

  validation {
    condition     = can(regex("^[^\\s@]+@sha256:[0-9a-f]{64}$", var.witness_image))
    error_message = "witness_image must be pinned by digest (<repository>@sha256:<64 lowercase hex>)."
  }
}

variable "ecr_repository_arns" {
  description = "ARNs of private ECR repositories the instance may pull witness_image from. Leave empty for a public registry."
  type        = list(string)
  default     = []
}

variable "witness_config_yaml" {
  description = "Contents of the witness config.yaml: the logs it cosigns for, each with origin, public_key and url. The origin and public_key are trust anchors; authenticate them out of band before deploying."
  type        = string

  validation {
    condition     = can(yamldecode(var.witness_config_yaml).logs[0].origin)
    error_message = "witness_config_yaml must be YAML with a non-empty logs list whose entries have an origin."
  }

  validation {
    condition     = length(var.witness_config_yaml) <= 4096
    error_message = "witness_config_yaml must be at most 4096 bytes (the SSM Parameter Store standard-tier limit)."
  }
}

variable "instance_architecture" {
  description = "CPU architecture of the witness instance: arm64 (Graviton) or x86_64. It must match instance_type, and witness_image must include this platform."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be arm64 or x86_64."
  }
}

variable "instance_type" {
  description = "EC2 instance type. The witness needs about 0.25 vCPU and 256 MiB; the default leaves room for the OS, Docker and the CloudWatch agent."
  type        = string
  default     = "t4g.small"
}

variable "ami_id" {
  description = "AMI for the instance. Null uses the latest Amazon Linux 2023 AMI at creation time. Later AMI releases do not replace a running instance; see the runbook for patching."
  type        = string
  default     = null
}

variable "data_volume_size_gib" {
  description = "Size of the encrypted gp3 volume that holds the SQLite database. The database stays small; the size mostly buys headroom."
  type        = number
  default     = 8

  validation {
    condition     = var.data_volume_size_gib >= 1
    error_message = "data_volume_size_gib must be at least 1."
  }
}

# --- Data protection -------------------------------------------------------

variable "kms_key_deletion_window_days" {
  description = "Waiting period before the module's KMS key is deleted after it is scheduled for deletion."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "Retention for the witness and WAF CloudWatch log groups."
  type        = number
  default     = 365
}

variable "backup_schedule" {
  description = "AWS Backup schedule (cron expression, UTC) for snapshots of the data volume. The hosting requirements ask for at least one backup a day; the default is every six hours."
  type        = string
  default     = "cron(0 */6 * * ? *)"
}

variable "backup_retention_days" {
  description = "Days AWS Backup keeps each recovery point."
  type        = number
  default     = 30
}

variable "backup_copy_vault_arn" {
  description = "Optional backup vault in another Region or account that receives a copy of every recovery point. Use one to put backups in a separate failure domain. A cross-account copy also needs the destination vault's access policy and permission for the destination account to use this module's KMS key; the module grants neither. Copy-job failures are not alerted; check them in AWS Backup."
  type        = string
  default     = null
}

variable "backup_vault_lock_min_retention_days" {
  description = "Optional AWS Backup Vault Lock (governance mode): the shortest retention any recovery point in the vault may have. Null leaves the vault unlocked."
  type        = number
  default     = null
}

variable "archive_object_lock_mode" {
  description = "Default S3 Object Lock mode for the checkpoint archive bucket. COMPLIANCE cannot be shortened or bypassed by anyone, including the account root, so try GOVERNANCE first."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.archive_object_lock_mode)
    error_message = "archive_object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "archive_retention_days" {
  description = "Default Object Lock retention for each object in the checkpoint archive."
  type        = number
  default     = 365
}

# --- Monitoring ------------------------------------------------------------

variable "alarm_email" {
  description = "Optional email address subscribed to the alarm topic. The subscription must be confirmed from the email AWS sends."
  type        = string
  default     = null
}

variable "target_4xx_threshold" {
  description = "Witness 4xx responses per 15 minutes that raise an alarm. A few 409 responses are normal: a submitter that is behind retries with the size the witness returns."
  type        = number
  default     = 10
}

variable "secret_read_alerts" {
  description = "Alert on reads of the signing-key secret by anyone other than the witness instance. This needs a CloudTrail trail in the account that records read management events."
  type        = bool
  default     = true
}
