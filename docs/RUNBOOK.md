# C2SP witness runbook

Procedures for deploying and operating the witness defined in [`modules/witness`](../modules/witness). Replace `<placeholders>` with your values. The commands assume the AWS CLI v2 with credentials for the witness account, and Terraform run from your copy of [`examples/basic`](../examples/basic).

Two rules come before everything else:

1. **Never reset, replace or roll back witness state to clear an error.** The database is the witness's memory of what it already signed. A rejected checkpoint is a signal to investigate, not something to make go away.
2. **The private key never leaves your trust boundary**, never enters Terraform, and is never pasted into a terminal, ticket or chat.

## Contents

1. [Before you deploy](#1-before-you-deploy)
2. [Generate the witness key](#2-generate-the-witness-key)
3. [First deployment](#3-first-deployment)
4. [Verify and hand off](#4-verify-and-hand-off)
5. [Monitoring and alerts](#5-monitoring-and-alerts)
6. [Checkpoint archive monitor](#6-checkpoint-archive-monitor)
7. [Routine operations](#7-routine-operations)
8. [Backup and restore](#8-backup-and-restore)
9. [Key rotation and compromise](#9-key-rotation-and-compromise)
10. [Incident response](#10-incident-response)
11. [Decommissioning](#11-decommissioning)

## 1. Before you deploy

Collect and authenticate these values. Get the trust anchors through a channel separate from the log URL, for example a signed message or a call with a known contact.

| Item | From | Used in |
|---|---|---|
| Log origin (first line of its checkpoints) | Log operator | `config.yaml` |
| Log public key (note-compatible vkey) | Log operator | `config.yaml` |
| Public log URL | Log operator | `config.yaml` (informational) |
| Submitter source CIDRs | Log operator | `add_checkpoint_allowed_cidrs` |
| Expected checkpoint cadence and submit timeout | Log operator | Archive monitor freshness alert |
| Witness hostname | You | `domain_name` |
| Witness image digest | You, after review | `witness_image` |

Account prerequisites:

- **VPC.** Two public subnets in different Availability Zones for the load balancer; one private subnet with outbound HTTPS for the instance. The instance reaches the image registry, Amazon Linux package repositories, Secrets Manager, SSM, CloudWatch Logs and, for a private ECR image, ECR.
- **Route 53.** A public hosted zone containing the witness hostname.
- **CloudTrail.** A trail that records management events, including read events. The signing-key read alert, and the API-call alerts, depend on it. Send the trail to a bucket in a separate log-archive account so the workload cannot alter its own audit trail.
- **State backend.** Remote state with versioning, encryption and locking, writable only by the people who deploy the witness.

Image:

1. Review the witness source at the revision you will run and build or obtain its image.
2. Scan it under your normal supply-chain process.
3. Optionally copy it into a private ECR repository in your account and set `ecr_repository_arns`.
4. Record the digest (`<repository>@sha256:<64 hex>`). The module refuses tag-only references.

## 2. Generate the witness key

Generate the key on a trusted machine inside your boundary with a reviewed, pinned build of the witness's key generator. Do not use an unpinned `go run` that downloads code at key-generation time. With a transparency-dev-based generator this looks like:

```sh
umask 077
./generate-keys \
  --name=<witness-hostname>/<key-name> \
  --out_priv=witness.key \
  --out_pub=witness.pub
```

Choose a key name under a domain you control, for example `witness.example.org/w1`. Ed25519 (the default) is what C2SP cosignature/v1 expects. Keep `witness.pub`: it is the out-of-band copy you compare the deployed key against.

Decide now whether you keep an encrypted, access-controlled backup of `witness.key` or run a no-backup policy with an emergency-rotation plan. Record the decision. Never put the key in a volume or database backup.

## 3. First deployment

1. Copy `examples/basic` into your infrastructure repository, configure the backend in `versions.tf`, and create `terraform.tfvars` from `terraform.tfvars.example`.
2. Create `config.yaml` from `config.yaml.example` with the authenticated trust anchors. Have a second person check the origin and key byte for byte.
3. Plan and review:

   ```sh
   terraform init
   terraform plan -out=witness.tfplan
   ```

   Everything in the plan should belong to `module.witness`; nothing outside it should change.
4. Apply the reviewed plan:

   ```sh
   terraform apply witness.tfplan
   ```

   The instance boots, attaches and formats the new data volume, and then waits for the signing key; it retries every 10 seconds until the key exists. The `witness-unavailable` alarm fires until then. That is expected.
5. Upload the key as binary, from the machine where you generated it:

   ```sh
   aws secretsmanager put-secret-value \
     --secret-id "$(terraform output -raw signing_key_secret_arn)" \
     --secret-binary fileb://witness.key
   ```

   Use `--secret-binary fileb://`, never `--secret-string`: the witness reads the key byte for byte. The `signing-key-changed` alert fires; that is expected too.
6. Apply your key-custody decision to the local `witness.key`: move it into the approved backup, or destroy it.

## 4. Verify and hand off

1. Watch the witness start:

   ```sh
   aws logs tail "$(terraform output -raw log_group_name)" --follow
   ```

   Look for `Witness cosignature/v1 vkey: ...`. The witness refuses to start if its key does not produce a verifiable cosignature.
2. Compare the served key with your out-of-band copy. They must be identical:

   ```sh
   curl -fsS https://<witness-hostname>/vkey
   cat witness.pub
   ```

3. Confirm that only the intended routes are public:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' https://<witness-hostname>/healthz   # 404
   curl -s -o /dev/null -w '%{http_code}\n' https://<witness-hostname>/vkey      # 200
   ```

4. Send the log operator the base URL (`terraform output -raw witness_url`) and `witness.pub` through an authenticated channel. Submitters append `/add-checkpoint`. Never send `witness.key`.
5. Once the log submits its first checkpoint, read it back (it is a 404 until then):

   ```sh
   hash=$(printf %s '<log origin>' | shasum -a 256 | cut -d' ' -f1)
   curl -fsS "https://<witness-hostname>/$hash/checkpoint"
   ```

6. Run the acceptance tests you agreed with the log operator. Run any adversarial tests (bad signature, wrong origin, stale size, invalid proof, conflicting root) against a separate deployment with a disposable test log and key. Never feed test state to the production database.

## 5. Monitoring and alerts

Subscribe your on-call channel to `terraform output -raw alarm_topic_arn`. Email subscriptions must be confirmed from the email AWS sends.

| Alert | Meaning | First response |
|---|---|---|
| `witness-unavailable` | No healthy target for 2 of 3 minutes | [Check the service](#check-the-service). The log cannot collect this witness's cosignature. |
| `witness-5xx` | 5xx responses in three consecutive 5-minute periods | Read the logs. A database or disk error is a state incident: do not delete files. |
| `witness-4xx` | More rejections than `target_4xx_threshold` in 15 minutes | Read the logs. A few 409s are normal. Repeated consistency or signature failures from the log's own submitter are a possible fork: follow [incident response](#10-incident-response). |
| `witness-slow` | p99 response time above 5 seconds | Check instance CPU, memory and disk. |
| `instance-status` | EC2 status check failed | AWS auto-recovers system failures. For instance failures, see [Patching](#patch-the-operating-system). |
| `data-volume-usage` | Volume more than 80% full, or no usage reported | [Grow the volume](#grow-the-data-volume). Briefly expected while a new instance boots. |
| `certificate-expiry` | Certificate expires in under 30 days | ACM renews automatically while the validation CNAME exists. Check the record and the ACM console. |
| `witness-restarted` | The witness process started | Expected after a planned change. Otherwise read the logs and confirm `/vkey` still matches `witness.pub`. |
| `backup-failed` | A backup or copy job failed, aborted or expired | Check AWS Backup job details; take the next scheduled backup seriously. |
| `instance-state` | Instance stopping, stopped or terminated | Expected during planned replacement. Otherwise investigate who and why in CloudTrail. |
| `config-changed` | The trust-anchor configuration changed | Must match a reviewed change. Otherwise treat it as an incident. |
| `signing-key-changed` | The key secret was written, changed or scheduled for deletion | Must match a reviewed change. Otherwise treat it as key compromise. |
| `signing-key-read` | Someone other than the witness instance read the key | Treat it as a possible key compromise unless it matches an approved break-glass action. |
| `data-volume-changed` | The data volume was detached or deleted | Expected during planned replacement. Otherwise treat it as a rollback attempt. |

`GET /healthz` only shows that the process answers. It does not show that the witness accepts checkpoints or that its state is intact. The archive monitor (next section) covers freshness and consistency.

## 6. Checkpoint archive monitor

The hosting requirements call for an independent monitor that keeps an append-only record of what the witness accepted. If the database is ever rolled back or lost, this record is the recovery anchor. The module creates the storage (`archive_bucket_name`, S3 Object Lock) and an IAM policy (`archive_writer_policy_arn`). You run the monitor, preferably under a separate identity and, ideally, in a separate account.

The monitor must, at least as often as your recovery-point objective:

1. Fetch `GET /<origin-hash>/checkpoint` from the witness.
2. Verify the log's signature and the witness cosignature against the pinned keys.
3. Fetch a consistency proof from the public log and verify consistency from the last archived checkpoint.
4. Write each new highest checkpoint to the archive bucket. Never overwrite or delete an object; Object Lock enforces this.
5. Alert and fail closed on a smaller tree size, a different root at the same size, an invalid or unavailable proof, or no new checkpoint within the agreed publication window.

Attach `archive_writer_policy_arn` to the monitor's role. Under the default GOVERNANCE mode, deleting locked objects requires `s3:BypassGovernanceRetention`, which nobody should hold day to day. Use COMPLIANCE for production once you are confident in the retention period: it cannot be shortened by anyone, including the account root.

## 7. Routine operations

### Check the service

Start a shell on the instance through Session Manager (there is no SSH; the AWS CLI needs the Session Manager plugin):

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

Then:

```sh
sudo systemctl status c2sp-witness
sudo journalctl -u c2sp-witness -n 100     # prepare-step errors (volume, key, config, image pull)
sudo docker ps
findmnt /var/lib/witness
```

Witness logs go to CloudWatch, not journald: `aws logs tail <log group>`.

### Restart the witness

```sh
sudo systemctl restart c2sp-witness
```

Each start re-reads the key and config, re-pulls the pinned image and remounts the volume if needed. If any step fails, the witness does not start.

### Change the log configuration

1. Edit `config.yaml` through peer-reviewed change control. Do not apply trust-anchor updates you received only through the log URL or an unauthenticated request.
2. `terraform plan`. Only the SSM parameter should change.
3. `terraform apply`, then [restart the witness](#restart-the-witness) and read the logs.

The witness pins each origin's public key in its database on first start and refuses to start if the configured key for an existing origin changes. A new log key therefore means a new origin, coordinated with the log operator. Do not edit the database to get around this.

### Upgrade the witness image

1. Review and scan the new revision, and test it against a non-production deployment with a test log.
2. Record the current checkpoint (step 5 of [Verify](#4-verify-and-hand-off)).
3. Set the new digest in `witness_image` and run `terraform plan`. The plan replaces the instance; the data volume stays. Read the plan and confirm that `aws_ebs_volume.data` is not in it.
4. Apply. Terraform stops the old instance, detaches the volume, starts a new instance and attaches the volume to it. Expect a few minutes without a healthy target.
5. Confirm `/vkey` is unchanged and the checkpoint is the same or newer than in step 2.

To roll back, set the previous digest and apply again. State moves forward only, so a rollback must not restore an older volume.

### Patch the operating system

New Amazon Linux releases never replace the instance by themselves (the AMI is ignored after creation). Either:

- **Replace the instance (preferred).** Same flow and checks as an image upgrade:

  ```sh
  terraform apply -replace=module.witness.aws_instance.witness
  ```

  This picks up the latest Amazon Linux 2023 AMI unless `ami_id` is set.
- **Patch in place** for urgent fixes: in a Session Manager shell run `sudo dnf upgrade --releasever=latest -y && sudo reboot`.

### Grow the data volume

1. Increase `data_volume_size_gib` and apply. EBS resizes the volume online; no instance replacement.
2. In a Session Manager shell, grow the filesystem: `sudo xfs_growfs /var/lib/witness`.

EBS volumes cannot shrink.

## 8. Backup and restore

AWS Backup snapshots the data volume on `backup_schedule` (default every six hours) and keeps each recovery point for `backup_retention_days`. Snapshots are crash-consistent; SQLite's journal makes such a copy recoverable, which is why a restore always includes an integrity check. Set `backup_copy_vault_arn` to copy recovery points to another Region or account, and `backup_vault_lock_min_retention_days` to stop recovery points being deleted early.

Check that backups are running:

```sh
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$(terraform output -raw backup_vault_name)" \
  --query 'reverse(sort_by(RecoveryPoints,&CreationDate))[:5].[CreationDate,Status]'
```

In some AWS Organizations, an on-demand `start-backup-job` is denied by policy even though scheduled jobs succeed. Judge backup health by `list-backup-jobs` and recovery points, not by a manual job.

### Restore drill (at least yearly)

The drill never touches the production instance and never uses the production key.

1. Restore the latest recovery point to a new volume (AWS Backup console, or `aws backup start-restore-job`) in any Availability Zone.
2. Attach it to a temporary instance that has no access to the signing key, mount it read-only, and run:

   ```sh
   sqlite3 -readonly /mnt/db/witness.db 'PRAGMA integrity_check;'
   ```

3. Compare the stored checkpoint with the latest archived checkpoint. Record the measured restore time and data age.
4. Delete the temporary instance and volume.

### Restore production state

Use this only when the live volume is lost or corrupt. **Loss or rollback of witness state is a security incident:** tell the log operator before you start, and follow [incident response](#10-incident-response).

1. **Fence the witness.** In a Session Manager shell, `sudo systemctl stop c2sp-witness`. Submissions now fail with 5xx errors.
2. **Preserve evidence.** Snapshot the current volume and keep it (`aws ec2 create-snapshot --volume-id <current volume>`). Do not delete the old volume.
3. **Restore** the chosen recovery point to a new volume **in the instance's Availability Zone**, encrypted with the module's KMS key.
4. **Inspect it offline** as in the drill: integrity check, and compare its checkpoint with the archive.
   - If it matches the latest archived checkpoint, continue.
   - If it is **behind** the archive, stop. Serving it would let the witness sign a fork from an older checkpoint. Bring it forward only by replaying the archived checkpoint with a verified consistency proof, in coordination with the log operator. If no trustworthy anchor exists, do not resume signing: retire this witness key through the [rotation](#9-key-rotation-and-compromise) process instead.
5. **Swap the volume in Terraform:**

   ```sh
   terraform state rm module.witness.aws_ebs_volume.data
   terraform import module.witness.aws_ebs_volume.data <restored volume id>
   terraform plan -out=restore.tfplan
   ```

   The plan replaces the volume attachment and the instance (the boot script names the volume). The old volume leaves state but is not deleted. Review the plan, then apply it.
6. Verify as in [section 4](#4-verify-and-hand-off) and tell the log operator the witness is back.

## 9. Key rotation and compromise

### Planned rotation

1. Generate a new key ([section 2](#2-generate-the-witness-key)) with a new key name, for example `.../w2`.
2. Authenticate the new public key with the log operator, who publishes a policy that accepts both keys for an agreed overlap.
3. Upload the new key and restart:

   ```sh
   aws secretsmanager put-secret-value --secret-id <secret arn> --secret-binary fileb://witness.key
   ```

   Then [restart the witness](#restart-the-witness). The database is kept; rotation never resets state.
4. Confirm `/vkey` now matches the new `witness.pub` and that the next checkpoint is cosigned with it.
5. After the log operator removes the old key from its policy, destroy retired private-key copies according to your policy. Secrets Manager keeps the previous version under the `AWSPREVIOUS` label until the next rotation replaces it.

### Suspected compromise

Do not use the overlap procedure. Availability is secondary.

1. Stop signing: `sudo systemctl stop c2sp-witness`.
2. Notify the log operator through the agreed security channel within one hour, so it can remove the key from its policy.
3. Preserve evidence: CloudTrail events for the secret and KMS key, instance and WAF logs, the data volume (snapshot it).
4. Investigate how the key was exposed before deploying a new one. Then generate and upload a new key as above, and coordinate re-enabling with the log operator.

## 10. Incident response

Notify the log operator within one hour of confirming or strongly suspecting:

- key compromise, unauthorized signing or unexpected key access;
- checkpoint inconsistency, equivocation or a fork;
- database rollback, corruption or loss of the recovery anchor;
- total loss of witness state.

For consistency or signature rejections of the log's own checkpoints:

1. **Fail closed.** Do not delete or reset the database, change trust anchors or ask anyone to weaken a policy to clear the error.
2. Stop the witness if there is any doubt about its state.
3. Preserve the database (snapshot), the witness and WAF logs, the configuration, and the rejected submissions as logged.
4. Investigate jointly with the log operator.

Tell the operational contact in advance about endpoint, key, trust-anchor or capacity changes, and promptly about any outage expected to last more than four hours.

## 11. Decommissioning

1. Agree a date with the log operator. Verifiers must stop requiring this witness **before** it stops.
2. Stop the witness, take a final backup, and export the final checkpoint and the archive for retention.
3. Keep public keys, witnessed checkpoints, audit logs and incident records for the agreed retention period.
4. Remove protections deliberately: set `alb_deletion_protection = false` and apply. The data volume has `prevent_destroy`; take it out of Terraform state with `terraform state rm module.witness.aws_ebs_volume.data` and delete it separately once retention allows.
5. `terraform destroy`. This removes the DNS records with the load balancer, which prevents a dangling record from being taken over. Archive objects stay until their Object Lock retention ends, so the bucket cannot be deleted before then.
6. Destroy remaining copies of the private key once legal and incident-retention requirements allow. Deleting the Secrets Manager secret starts a 30-day recovery window.
