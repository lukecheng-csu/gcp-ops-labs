#!/usr/bin/env python3
"""Hybrid host metrics -> Google Cloud Monitoring (generic_node).

Why this exists
---------------
The Ops Agent's built-in `agent.googleapis.com/*` metrics are tied to the
`gce_instance` monitored resource. On a non-GCE host (here: Tencent Cloud
Lighthouse), the agent falls back to `generic_node` and Cloud Monitoring
rejects those writes with "unknown metric type". Logs still land in Cloud
Logging via Fluent Bit, so we keep Ops Agent for logs only and write host
metrics ourselves as user-defined metrics on `generic_node`.

Credentials: /etc/google/auth/application_default_credentials.json (0400 root).
Only roles/monitoring.metricWriter is needed.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import psutil
from google.auth.transport.requests import Request
from google.oauth2 import service_account

PROJECT_ID = os.environ.get("HYBRID_PROJECT_ID", "lukechengtest")
NODE_ID = os.environ.get("HYBRID_NODE_ID", "jump-us")
# `generic_node.location` only accepts a Google Cloud region or "global".
# A Tencent Cloud region here gets rejected with "Unrecognized region or location",
# so the provider/region lives in `namespace` instead.
LOCATION = os.environ.get("HYBRID_LOCATION", "global")
NAMESPACE = os.environ.get("HYBRID_NAMESPACE", "tencentcloud-na-ashburn")
CREDENTIALS = os.environ.get(
    "GOOGLE_APPLICATION_CREDENTIALS",
    "/etc/google/auth/application_default_credentials.json",
)
SCOPES = ["https://www.googleapis.com/auth/monitoring.write"]
API = f"https://monitoring.googleapis.com/v3/projects/{PROJECT_ID}/timeSeries"

METRICS = {
    "cpu_utilization": "CPU 使用率（%）",
    "memory_utilization": "内存使用率（%）",
    "disk_used_percent": "根盘使用率（%）",
    "load1": "1 分钟负载",
    "n8n_containers_up": "运行中的 n8n 容器数（期望 3）",
}


def n8n_container_count():
    """Count running n8n-* containers; -1 means docker query failed."""
    try:
        out = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
        return sum(1 for line in out.splitlines() if line.strip().startswith("n8n-"))
    except Exception as exc:  # noqa: BLE001 - report, don't crash the whole run
        print(f"WARN docker ps failed: {exc}", file=sys.stderr)
        return -1


def sample():
    disk = shutil.disk_usage("/")
    return {
        "cpu_utilization": psutil.cpu_percent(interval=1),
        "memory_utilization": psutil.virtual_memory().percent,
        "disk_used_percent": round(disk.used / disk.total * 100, 2),
        "load1": round(os.getloadavg()[0], 3),
        "n8n_containers_up": n8n_container_count(),
    }


def access_token():
    creds = service_account.Credentials.from_service_account_file(
        CREDENTIALS, scopes=SCOPES
    )
    creds.refresh(Request())
    return creds.token


def build_payload(values, now):
    resource = {
        "type": "generic_node",
        "labels": {
            "project_id": PROJECT_ID,
            "location": LOCATION,
            "namespace": NAMESPACE,
            "node_id": NODE_ID,
        },
    }
    series = []
    for name, value in values.items():
        series.append({
            "metric": {
                "type": f"custom.googleapis.com/host/{name}",
                "labels": {"host": NODE_ID},
            },
            "resource": resource,
            "metricKind": "GAUGE",
            "valueType": "DOUBLE",
            "points": [{
                "interval": {"endTime": now},
                "value": {"doubleValue": float(value)},
            }],
        })
    return {"timeSeries": series}


def main():
    now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    payload = build_payload(sample(), now)
    req = urllib.request.Request(
        API,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {access_token()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            if resp.status != 200:
                raise RuntimeError(f"HTTP {resp.status}: {resp.read().decode()[:300]}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        # A manual run right next to a timer tick trips the metric's minimum
        # sampling period. That's harmless and self-healing: skip, don't fail
        # the unit (otherwise systemd shows a false-alarm failed service).
        if exc.code == 400 and "sampling period" in body:
            print(f"{now} WARN sample too close to previous one, skipped")
            return 0
        print(f"ERROR {exc.code}: {body[:600]}", file=sys.stderr)
        return 1
    print(f"{now} wrote {len(payload['timeSeries'])} series -> {NODE_ID}/{LOCATION}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
