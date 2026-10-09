module "witness" {
  source = "../../modules/witness"

  name = var.name

  vpc_id             = var.vpc_id
  alb_subnet_ids     = var.alb_subnet_ids
  instance_subnet_id = var.instance_subnet_id

  domain_name     = var.domain_name
  route53_zone_id = var.route53_zone_id

  witness_image       = var.witness_image
  ecr_repository_arns = var.ecr_repository_arns
  witness_config_yaml = file("${path.module}/${var.witness_config_path}")

  add_checkpoint_allowed_cidrs = var.add_checkpoint_allowed_cidrs

  alarm_email = var.alarm_email
}
