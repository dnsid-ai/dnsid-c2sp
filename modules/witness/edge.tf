# --- TLS certificate and DNS ------------------------------------------------------

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# One hostname means exactly one validation record.
resource "aws_route53_record" "cert_validation" {
  zone_id         = var.route53_zone_id
  name            = one(aws_acm_certificate.this.domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.this.domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.this.domain_validation_options).resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}

resource "aws_route53_record" "witness" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}

# --- Load balancer -----------------------------------------------------------------

# trivy:ignore:AWS-0053 A witness is a public endpoint; the listener routes three paths and the WAF limits them.
resource "aws_lb" "this" {
  name                       = var.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.alb_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = 30
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  enable_deletion_protection = var.alb_deletion_protection

  dynamic "access_logs" {
    for_each = var.alb_access_logs == null ? [] : [var.alb_access_logs]
    content {
      enabled = true
      bucket  = access_logs.value.bucket
      prefix  = access_logs.value.prefix
    }
  }

  tags = local.tags
}

resource "aws_lb_target_group" "witness" {
  name                 = var.name
  port                 = local.witness_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = 15

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.tags
}

resource "aws_lb_target_group_attachment" "witness" {
  target_group_arn = aws_lb_target_group.witness.arn
  target_id        = aws_instance.witness.id
  port             = local.witness_port
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  # Anything not explicitly routed below never reaches the witness, including /healthz.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found\n"
      status_code  = "404"
    }
  }

  tags = local.tags
}

resource "aws_lb_listener_rule" "add_checkpoint" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    http_request_method {
      values = ["POST"]
    }
  }
  condition {
    path_pattern {
      values = ["/add-checkpoint"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.witness.arn
  }

  tags = local.tags
}

resource "aws_lb_listener_rule" "reads" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  condition {
    http_request_method {
      values = ["GET", "HEAD"]
    }
  }
  condition {
    path_pattern {
      values = ["/vkey", "/*/checkpoint"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.witness.arn
  }

  tags = local.tags
}

# --- WAF -----------------------------------------------------------------------------

resource "aws_wafv2_ip_set" "add_checkpoint" {
  count = length(var.add_checkpoint_allowed_cidrs) > 0 ? 1 : 0

  name               = "${var.name}-add-checkpoint"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.add_checkpoint_allowed_cidrs

  tags = local.tags
}

resource "aws_wafv2_ip_set" "read" {
  count = length(var.read_allowed_cidrs) > 0 ? 1 : 0

  name               = "${var.name}-read"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.read_allowed_cidrs

  tags = local.tags
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "C2SP witness ingress limits"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # A checkpoint, its consistency proof and the old size fit in a few KiB. The witness
  # caps bodies at 16 KiB; a WAF on an ALB inspects only the first 8 KiB, so anything
  # larger is treated as a match and blocked.
  rule {
    name     = "body-size-limit"
    priority = 0

    action {
      block {}
    }

    statement {
      size_constraint_statement {
        comparison_operator = "GT"
        size                = 8192

        field_to_match {
          body {
            oversize_handling = "MATCH"
          }
        }

        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-body-size-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = aws_wafv2_ip_set.add_checkpoint
    content {
      name     = "add-checkpoint-allowlist"
      priority = 10

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            byte_match_statement {
              positional_constraint = "EXACTLY"
              search_string         = "/add-checkpoint"

              field_to_match {
                uri_path {}
              }

              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = rule.value.arn
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-add-checkpoint-allowlist"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = aws_wafv2_ip_set.read
    content {
      name     = "read-allowlist"
      priority = 20

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            not_statement {
              statement {
                byte_match_statement {
                  positional_constraint = "EXACTLY"
                  search_string         = "/add-checkpoint"

                  field_to_match {
                    uri_path {}
                  }

                  text_transformation {
                    priority = 0
                    type     = "NONE"
                  }
                }
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = rule.value.arn
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-read-allowlist"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 30

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_per_5_minutes
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-per-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

# WAF log groups must be named aws-waf-logs-*.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = local.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}
