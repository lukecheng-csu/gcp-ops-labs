# GCP Ops Labs

Hands-on labs on Google Cloud — each one is something I actually broke, debugged, and fixed on a real VM.

| # | Lab | Skills |
|---|-----|--------|
| 01 | [SSH Lockout Rescue via Serial Console](01-ssh-lockout-rescue/) | Compute Engine, sshd config precedence, ufw vs VPC firewall, serial console recovery |
| 02 | [Self-Hosted n8n on GCP](02-n8n-gcp-deploy/) | Docker Compose, PostgreSQL, Caddy + Let's Encrypt, persistent disks, Cloudflare, container DNS & bind-mount debugging |
| 03 | [Static Site: GCS + HTTPS LB + Cloud DNS](03-static-site-gcs-cdn/) | Cloud Storage, global LB, managed certs, Cloud DNS subdomain delegation, Cloud CDN vs GCS edge cache, DNS blackhole break-fix |
| 04 | [Terraform Basics](04-terraform-basics/) | IaC rebuild of the lab 01 VM, `plan` diff, drift detection, state import |
| 05 | [Terraform Advanced](05-terraform-advanced/) | GCS remote state + locking, modules, dev/prod workspaces |
| 06 | [Cloud SQL PITR](06-cloudsql-pitr/) | Automated backups + WAL, measured RPO/RTO, pgAudit forensics → point-in-time clone |
| 07 | [Monitoring, Alerting & Logging](07-monitoring-alerting/) | Ops Agent, dashboard, email notification channel, uptime check, real triggered alerts |

## Roadmap

Labs 08–13 (Cloud Run, CI/CD, IAM, cross-region HA, GKE, VMware migration): see **[ROADMAP.md](ROADMAP.md)**. Rule of thumb for every lab: build it first, then break it on purpose — teardown after each drill.
