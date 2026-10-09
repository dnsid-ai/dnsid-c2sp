# dnsid-c2sp

Terraform for running an independent [C2SP transparency-log witness](https://github.com/C2SP/C2SP/blob/main/tlog-witness.md) on AWS.

A witness receives signed checkpoints from a transparency log, checks the log's signature and append-only consistency against the last checkpoint it accepted, stores the new checkpoint, and returns a [cosignature](https://github.com/C2SP/C2SP/blob/main/tlog-cosignature.md). It is useful only if it is operated independently of the log, so this repository is meant for the witness operator, not the log operator.

The operating procedures are in the **[runbook](docs/RUNBOOK.md)**. Read it before deploying.

## What gets deployed

```text
log submitter ──HTTPS──► ALB (TLS 1.2+, WAF) ──HTTP :7667──► EC2 instance (private subnet)
                         │                                    └─ witness container (read-only, non-root)
monitors / auditors ─────┘                                         └─ /data on a dedicated EBS volume
```

| Concern | How the module handles it |
|---|---|
| One writer | One EC2 instance; the SQLite database lives on its own encrypted EBS volume, which attaches to one instance at a time. The instance is stopped before the volume is detached. |
| State durability | The data volume has `prevent_destroy`, is replaced only on purpose, and is backed up by AWS Backup (every six hours by default, optional cross-Region or cross-account copy, optional Vault Lock). |
| Rollback detection | An S3 bucket with Object Lock for an independent checkpoint archive, plus an IAM policy for the monitor that fills it. The witness instance is explicitly denied access to it. |
| Signing key | Stored as `SecretBinary` in Secrets Manager under a customer managed KMS key. Terraform creates only the empty secret, so the key never enters Terraform state. The instance fetches it to tmpfs and mounts it read-only. |
| Ingress | Only `POST /add-checkpoint`, `GET /vkey` and `GET /<origin-hash>/checkpoint` are routed; everything else (including `/healthz`) gets a 404 at the load balancer. The WAF enforces a body-size limit, a per-IP rate limit and optional source allowlists for submissions and reads. |
| Runtime hardening | IMDSv2 with hop limit 1, no public IP, no SSH (Session Manager only), container runs read-only as UID 65532 with all capabilities dropped and `no-new-privileges`. |
| Monitoring | Alarms to an SNS topic: target unhealthy, 5xx, unusual 4xx, slow responses, EC2 status, data volume usage, certificate expiry, witness restarts. Events for backup failures, instance stop/terminate, config changes, signing-key writes and reads, and data volume detach/delete. |

Not included, and still required by a production witness: the checkpoint-archive monitor itself, a CloudTrail trail, and log retention outside the account. The runbook covers each.

## Witness image contract

The module runs any container image that behaves like a [transparency-dev/witness](https://github.com/transparency-dev/witness)-based C2SP witness with these properties:

- accepts `--listen`, `--private_key`, `--config`, `--db` and `--db_max_conns`;
- serves `GET /healthz`, `GET /vkey`, `POST /add-checkpoint` and `GET /<sha256(origin)>/checkpoint`;
- runs as UID/GID 65532 and writes only to `/data`;
- logs `Witness cosignature/v1 vkey: <vkey>` at startup.

The image must be pinned by digest. Review and scan it under your own supply-chain process first.

## Usage

```hcl
module "witness" {
  source = "github.com/dnsid-ai/dnsid-c2sp//modules/witness?ref=<commit-sha>"

  vpc_id             = "vpc-..."
  alb_subnet_ids     = ["subnet-...", "subnet-..."]
  instance_subnet_id = "subnet-..."

  domain_name     = "witness.example.org"
  route53_zone_id = "Z..."

  witness_image       = "registry.example.org/witness@sha256:<digest>"
  witness_config_yaml = file("${path.module}/config.yaml")

  add_checkpoint_allowed_cidrs = ["192.0.2.0/24"]
  alarm_email                  = "oncall@example.org"
}
```

[`examples/basic`](examples/basic) is a complete root module. Every input is documented in [`modules/witness/variables.tf`](modules/witness/variables.tf).

### Requirements

- Terraform 1.7 or later (the tests need 1.11 or later) and the AWS provider 6.x.
- A VPC with at least two public subnets for the load balancer and a private subnet with outbound HTTPS (NAT gateway or VPC endpoints) for the instance.
- A public Route 53 hosted zone for the witness hostname.

## Development

```sh
terraform fmt -check -recursive
(cd modules/witness && terraform init -backend=false && terraform validate && terraform test)
tflint --init --config "$PWD/.tflint.hcl" && tflint --config "$PWD/.tflint.hcl" --chdir modules/witness
```

The tests run against a mocked AWS provider and need no credentials.

## License

[Apache-2.0](LICENSE).
