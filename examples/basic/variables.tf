variable "region" {
  description = "AWS Region to deploy into."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "c2sp-witness"
}

variable "vpc_id" {
  description = "Existing VPC."
  type        = string
}

variable "alb_subnet_ids" {
  description = "Public subnets (two or more AZs) for the load balancer."
  type        = list(string)
}

variable "instance_subnet_id" {
  description = "Private subnet with outbound HTTPS for the witness instance."
  type        = string
}

variable "domain_name" {
  description = "Public hostname of the witness."
  type        = string
}

variable "route53_zone_id" {
  description = "Hosted zone that contains domain_name."
  type        = string
}

variable "witness_image" {
  description = "Witness image pinned by digest."
  type        = string
}

variable "ecr_repository_arns" {
  description = "Private ECR repositories the image may be pulled from."
  type        = list(string)
  default     = []
}

variable "witness_config_path" {
  description = "Path to the reviewed witness config.yaml."
  type        = string
  default     = "config.yaml"
}

variable "add_checkpoint_allowed_cidrs" {
  description = "Source CIDRs of the log operator's checkpoint submitter."
  type        = list(string)
  default     = []
}

variable "alarm_email" {
  description = "Optional email subscribed to alarms."
  type        = string
  default     = null
}
