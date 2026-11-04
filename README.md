# GCP Ops Labs

Hands-on labs on Google Cloud — each one is something I actually broke, debugged, and fixed on a real VM.

| # | Lab | Skills |
|---|-----|--------|
| 01 | [SSH Lockout Rescue via Serial Console](01-ssh-lockout-rescue/) | Compute Engine, sshd config precedence, ufw vs VPC firewall, serial console recovery |
| 02 | [Self-Hosted n8n on GCP](02-n8n-gcp-deploy/) | Docker Compose, PostgreSQL, Caddy + Let's Encrypt, persistent disks, Cloudflare, container DNS & bind-mount debugging |
| 03 | [Static Site: GCS + HTTPS LB + Cloud DNS](03-static-site-gcs-cdn/) | Cloud Storage, global LB, managed certs, Cloud DNS subdomain delegation, Cloud CDN vs GCS edge cache, DNS blackhole break-fix |

## Roadmap

Planned labs 04–13 (Terraform, Cloud SQL, monitoring, Cloud Run, CI/CD, IAM, HA, GKE, VMware migration): see **[ROADMAP.md](ROADMAP.md)**. Rule of thumb for every lab: build it first, then break it on purpose — teardown after each drill.
