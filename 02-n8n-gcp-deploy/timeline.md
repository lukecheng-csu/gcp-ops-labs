# Deployment timeline — 2026-10-31 (UTC)

Sanitized log. Public IPs, passwords, keys and project IDs removed. Times marked `≈` are approximate; the rest are from command output.

| Time (UTC) | Event |
|---|---|
| ≈06:30 | Started `docker compose up -d` on the `e2-micro` VM. `postgres:16` and `caddy:2` pulled quickly; `docker.n8n.io/n8nio/n8n` took **634 s** to pull (registry has no CDN). |
| ≈06:50 | First failure: Caddy could not bind port 80 — `address already in use`. A leftover nginx from an earlier exercise owned :80. |
| ≈06:52 | `ss -tlnp` identified nginx; `systemctl stop nginx && systemctl disable nginx`; Caddy started. |
| ≈06:55 | Caddy began ACME certificate issuance and failed: `lookup ... on 169.254.169.254:53: connect: network is unreachable`. Host DNS worked (`docker pull` had succeeded) — the failure was container-scoped. |
| ≈07:00 | Root cause: GCP metadata/DNS address `169.254.169.254` is not routable from the Docker bridge namespace. Added `"dns": ["8.8.8.8","8.8.4.4"]` to `/etc/docker/daemon.json`, restarted Docker, then `docker compose down && up -d` (containers pick up DNS at creation). |
| ≈07:05 | ACME succeeded: **certificate obtained successfully** (HTTP-01 via Cloudflare). New failure: Caddy returned **502 — `dial tcp <container>:5678: connection refused`**. |
| ≈07:10 | `docker compose logs n8n`: **`EACCES: permission denied, open '/home/node/.n8n/config'`** — crash loop. Docker auto-created the bind-mount directory as `root:root`; the n8n image runs as UID 1000 and does not chown it. |
| ≈07:12 | Fix: `chown -R 1000:1000 /mnt/n8n-data/n8n`, restart n8n. Editor came up on HTTPS; owner account created. |
| 08:49 | DNS/edge verified from the local machine: `dig` returns Cloudflare edge IPs; `curl --resolve` against the VM origin returns `HTTP/2 200` from Caddy. |
| ≈09:00 | Built verification workflow (Webhook POST `/demo` → Code → Respond to Webhook), activated it, and confirmed with `curl` over public HTTPS — returned expected JSON. |
| 09:08:52 | `sudo reboot` for the persistence test. |
| ≈09:11 | All three containers back `Up` (~2 min), `postgres healthy`, data disk auto-mounted via fstab UUID. Webhook `curl` returned the identical payload — workflow, DB, credentials and certificates survived a cold boot. |
| 12:12:30 | Break-fix drill: `POSTGRES_PASSWORD` changed to a wrong value in `.env`. n8n: `password authentication failed for user "n8n"`; postgres: `FATAL: ... DETAIL: ... pg_hba.conf ... scram-sha-256`. DB healthy, connection reached, credential wrong — two-sided evidence. |
| ≈12:20 | Restored the correct password in `.env`, `docker compose up -d`. Recovery surfaced `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` (express-rate-limit, two proxies, `N8N_PROXY_HOPS=0`). |
| ≈12:25 | Set `N8N_PROXY_HOPS=2`; logs clean, editor and webhook both healthy. |
| ≈12:45 | Second break-fix drill (storage layer): replaced the PostgreSQL bind mount with `volumes: []`, `down` + `up` → new anonymous volume, empty DB, n8n asked for owner setup again. Repeated down/up → a second empty DB. `docker volume ls -f dangling=true` showed the orphans. Restored the bind mount, recreated containers — original account and workflows back. Data on `/mnt/n8n-data/pgdata` was untouched throughout. |

## Lessons

1. **Layer the diagnosis.** Every incident narrowed to a specific layer: port ownership (host) → DNS (network namespace) → permissions (filesystem) → credentials (database auth) → proxy trust (application). "It doesn't work" is never one layer.
2. **Evidence from both sides.** The DB password incident was diagnosed by matching the client error with the server's `pg_hba.conf` log line — not by guessing.
3. **GCP + containers have two well-known traps:** the metadata DNS address is unreachable from container networks, and it is worth checking firewall/VPC rules separately from host firewalls.
4. **A reboot test turns "it works" into "it persists."** The webhook answered identically after a cold boot, which is the claim that actually matters.
