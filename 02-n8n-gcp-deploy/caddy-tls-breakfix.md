# Break-fix drill: Caddy TLS misconfiguration → HTTPS down → diagnose from logs → roll back

**Exercise 02 · drill 3 of 3** — the ladder entry reads: *"Caddy 证书配置改错 → https 挂 → 看日志回滚"*.

## Goal

Break TLS on purpose, read the symptoms at every layer (client, certificate, Caddy, Cloudflare), pinpoint the exact configuration fault, and roll back cleanly — without losing the working Let's Encrypt certificate already stored on the data disk.

The core idea: Caddy normally asks Let's Encrypt for a publicly-trusted certificate. One misconfigured line (`tls internal`) makes it act as its own CA and self-sign instead. The network, the backend, and Caddy itself keep working — the **only** thing that breaks is *trust*, and that shows up differently at each layer.

## Baseline (record before you break)

```bash
# Healthy state: issuer should be Let's Encrypt
echo | openssl s_client -connect <VM_IP>:443 \
  -servername n8n-gcp.cloudworkflowdone.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# issuer=CN=E5, O=Let's Encrypt  (E5/E6/R11 depending on the chain)

# Bypassing Cloudflare and hitting the origin directly → HTTP 200
curl -skI --resolve n8n-gcp.cloudworkflowdone.com:443:<VM_IP> \
  https://n8n-gcp.cloudworkflowdone.com
```

## The break

```bash
cp Caddyfile Caddyfile.bak
```

Add one line to the site block. Before:

```
n8n-gcp.cloudworkflowdone.com {
	reverse_proxy n8n:5678
}
```

After (broken):

```
n8n-gcp.cloudworkflowdone.com {
	tls internal
	reverse_proxy n8n:5678
}
```

Reload without dropping connections:

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

`tls internal` tells Caddy: *don't go to Let's Encrypt — be your own CA and self-sign.* That certificate is trusted by no client on the internet.

## What broke — symptoms at each layer

### 1. Client (curl bypassing Cloudflare)

```bash
curl -v --resolve n8n-gcp.cloudworkflowdone.com:443:<VM_IP> \
  https://n8n-gcp.cloudworkflowdone.com 2>&1 | grep -iE 'ssl|verify|certificate'
# → curl: (60) SSL certificate problem: self-signed certificate
```

### 2. Certificate identity (the single most diagnostic line)

```bash
echo | openssl s_client -connect <VM_IP>:443 \
  -servername n8n-gcp.cloudworkflowdone.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# issuer=CN=Caddy Local Authority   (was: O=Let's Encrypt)
```

The issuer flipped. The certificate is no longer publicly trusted — that alone localizes the fault to TLS, ruling out DNS, network, and the n8n backend.

### 3. Caddy logs

```bash
docker compose logs caddy --tail=40
```

Watch for the issuance source changing from the public ACME CA to the local/internal CA — the log line that confirms Caddy is now self-signing rather than renewing with Let's Encrypt.

### 4. Through Cloudflare (the tell-tale 526)

With Cloudflare's TLS mode set to **Full (strict)**, the edge re-validates the origin certificate before proxying. A self-signed origin cert is rejected:

```bash
curl -sI https://n8n-gcp.cloudworkflowdone.com
# → HTTP/2 526  (Cloudflare error: Invalid SSL certificate)
```

The nuance worth knowing: in **Full (non-strict)** mode Cloudflare would *not* validate the origin cert and would silently mask the problem — the site would look fine through the CDN while the origin is actually serving a self-signed cert. That is exactly why the origin must be tested directly with `--resolve`, not through the proxy.

## Diagnosis

The fault is unambiguous and traceable to a single line:

- client reports `self-signed certificate`;
- the issuer flipped from `Let's Encrypt` to `Caddy Local Authority`;
- Caddy served the cert from its own internal CA;
- Cloudflare (Full strict) returned `526`.

Everything narrows to `tls internal`. Not DNS, not the network, not the backend — the certificate simply became one nobody trusts.

## Rollback

```bash
cp Caddyfile.bak Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Verify the issuer is back to Let's Encrypt and the endpoint returns 200 again (repeat the two baseline commands).

Why this is instant and lossless: the Let's Encrypt certificate was never deleted — it lived on `/mnt/n8n-data/caddy-data` the whole time. Editing the Caddyfile only changed **which** certificate Caddy serves, not **what it has stored**. Config and state are separate, and that separation is what makes rollback safe.

## Optional deepening: make ACME issuance fail outright

A second, harder variant: keep the Let's Encrypt flow but point it at a bad CA endpoint so issuance fails instead of self-signing. In the site block, override the ACME CA:

```
n8n-gcp.cloudworkflowdone.com {
	tls {
		issuer acme {
			ca https://acme-staging-v02.api.letsencrypt.org/directory
		}
	}
	reverse_proxy n8n:5678
}
```

Reload and watch `docker compose logs caddy`: issuance now fails (or obtains a **staging** cert that browsers do not trust), a different failure mode from `tls internal` — here Caddy *cannot* get a public cert at all, versus the first variant where it *chooses* not to. Roll back the same way.

## Lessons

1. **"HTTPS is down" is never one thing.** Read the client error, the cert issuer, the proxy logs, and (with Cloudflare) the HTTP status — each points to a different layer.
2. **A CDN can both hide and expose a TLS fault.** Full (strict) surfaces a bad origin cert as `526`; Full (non-strict) hides it. Always test the origin directly with `--resolve`.
3. **Config vs state.** Caddy's certificates are *state* (on the data disk); the Caddyfile is *config*. Breaking config never destroys state — which is why rollback is safe and fast.
4. **`tls internal` is a footgun with a purpose.** Fine for local/offline HTTPS; pointed at a public endpoint it silently downgrades trust.
